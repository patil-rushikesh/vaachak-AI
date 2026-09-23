-- Additive Phase 3 application RPCs. All data remains schema-isolated.
CREATE TABLE dev.join_attempts(user_id uuid PRIMARY KEY REFERENCES auth.users(id),window_start timestamptz NOT NULL,attempts integer NOT NULL);
CREATE TABLE dev.pairings(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),class_id uuid NOT NULL REFERENCES dev.classes(id) ON DELETE CASCADE,learner_id text NOT NULL REFERENCES dev.learners(id) ON DELETE CASCADE,device_id text NOT NULL REFERENCES dev.devices(id),secret text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32),'hex'),revoked_at timestamptz,UNIQUE(class_id,learner_id,device_id));
CREATE TABLE dev.teacher_keys(teacher_id uuid PRIMARY KEY REFERENCES dev.teachers(id),public_key text NOT NULL CHECK(length(public_key)=44));
ALTER TABLE dev.interventions ADD COLUMN delivery_seq bigint GENERATED ALWAYS AS IDENTITY;
CREATE UNIQUE INDEX ON dev.interventions(delivery_seq);
ALTER TABLE dev.join_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE dev.pairings ENABLE ROW LEVEL SECURITY;
ALTER TABLE dev.teacher_keys ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION dev.register_device(device text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR device IS NULL OR device !~ '^[A-Za-z0-9_-]{1,80}$' OR EXISTS(SELECT 1 FROM dev.teachers WHERE id=auth.uid()) THEN RAISE EXCEPTION 'Invalid device account';END IF;
 INSERT INTO dev.devices(id,user_id) VALUES(device,auth.uid()) ON CONFLICT DO NOTHING;
 IF NOT EXISTS(SELECT 1 FROM dev.devices WHERE id=device AND user_id=auth.uid() AND revoked_at IS NULL) THEN RAISE EXCEPTION 'Device identity already bound';END IF;
END $$;

CREATE FUNCTION dev.create_join_code(target_class uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE code text:=upper(encode(extensions.gen_random_bytes(8),'hex'));
BEGIN
 IF NOT dev.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 UPDATE dev.classes SET code_hash=encode(extensions.digest(code,'sha256'),'hex'),code_expires_at=now()+interval '20 minutes' WHERE id=target_class;
 RETURN code;
END $$;

CREATE FUNCTION dev.join_class(code text,learner text,display_name text,age_band text,is_minor boolean,sync_consent boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c dev.classes;d text;attempt_count integer;
BEGIN
 SELECT id INTO d FROM dev.devices WHERE user_id=auth.uid() AND revoked_at IS NULL;
 IF d IS NULL THEN RAISE EXCEPTION 'Register this device first';END IF;
 INSERT INTO dev.join_attempts VALUES(auth.uid(),now(),1) ON CONFLICT(user_id) DO UPDATE SET attempts=CASE WHEN dev.join_attempts.window_start<now()-interval '1 hour' THEN 1 ELSE dev.join_attempts.attempts+1 END,window_start=CASE WHEN dev.join_attempts.window_start<now()-interval '1 hour' THEN now() ELSE dev.join_attempts.window_start END RETURNING attempts INTO attempt_count;
 IF attempt_count>10 THEN RETURN jsonb_build_object('error','Too many join attempts. Try again in an hour.');END IF;
 SELECT * INTO c FROM dev.classes WHERE code_hash=encode(extensions.digest(upper(trim(code)),'sha256'),'hex') AND code_expires_at>now();
 IF NOT FOUND THEN RETURN jsonb_build_object('error','Class code is invalid or expired.');END IF;
 IF sync_consent IS DISTINCT FROM true OR is_minor IS NULL OR age_band NOT IN ('child','student','adult') OR (age_band='child' AND NOT is_minor) THEN RAISE EXCEPTION 'Consent and valid profile required';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(learner,0));
 IF EXISTS(SELECT 1 FROM dev.learners WHERE id=learner) AND NOT dev.owns_learner(learner) THEN RAISE EXCEPTION 'Learner identity belongs to another device';END IF;
 IF EXISTS(SELECT 1 FROM dev.learners WHERE id=learner AND (org_id<>c.org_id OR minor<>is_minor)) THEN RAISE EXCEPTION 'Profile organization or age classification mismatch';END IF;
 INSERT INTO dev.learners(id,org_id,display_name,age_band,minor) VALUES(learner,c.org_id,display_name,age_band,is_minor) ON CONFLICT(id) DO NOTHING;
 INSERT INTO dev.device_learners VALUES(d,learner) ON CONFLICT DO NOTHING;
 INSERT INTO dev.enrollments(class_id,learner_id,status) VALUES(c.id,learner,'pending') ON CONFLICT(class_id,learner_id) DO NOTHING;
 IF NOT is_minor THEN
  INSERT INTO dev.consents(learner_id,purpose,verified_via,version) SELECT learner,p,'self',1 FROM unnest(ARRAY['core','serverSync']) p WHERE NOT dev.has_consent(learner,p);
 END IF;
 INSERT INTO dev.pairings(class_id,learner_id,device_id) VALUES(c.id,learner,d) ON CONFLICT DO NOTHING;
 RETURN jsonb_build_object('classId',c.id,'className',c.name,'status',(SELECT status FROM dev.enrollments WHERE class_id=c.id AND learner_id=learner));
END $$;

CREATE FUNCTION dev.review_enrollment(target_class uuid,target_learner text,approve boolean,witness_reference text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g uuid;minor_learner boolean;
BEGIN
 IF NOT dev.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 SELECT l.minor INTO minor_learner FROM dev.learners l JOIN dev.enrollments e ON e.learner_id=l.id WHERE l.id=target_learner AND e.class_id=target_class AND e.status='pending' FOR UPDATE OF e;
 IF NOT FOUND THEN RAISE EXCEPTION 'No pending enrollment';END IF;
 IF approve AND minor_learner THEN
  IF witness_reference IS NULL OR length(trim(witness_reference)) NOT BETWEEN 6 AND 120 THEN RAISE EXCEPTION 'Witnessed guardian consent reference required';END IF;
  INSERT INTO dev.guardians(learner_id,contact_hash,verified_via,verification_reference) VALUES(target_learner,encode(extensions.digest(witness_reference,'sha256'),'hex'),'teacherWitnessedPaper',witness_reference) RETURNING id INTO g;
  INSERT INTO dev.consents(learner_id,purpose,guardian_id,verified_via,version) SELECT target_learner,p,g,'teacherWitnessedPaper',1 FROM unnest(ARRAY['core','serverSync']) p WHERE NOT dev.has_consent(target_learner,p);
 END IF;
 UPDATE dev.enrollments SET status=CASE WHEN approve THEN 'active' ELSE 'left' END,to_at=CASE WHEN approve THEN NULL ELSE now() END WHERE class_id=target_class AND learner_id=target_learner;
 IF NOT approve THEN UPDATE dev.pairings SET revoked_at=now() WHERE class_id=target_class AND learner_id=target_learner;END IF;
END $$;
-- Pending identities are visible only to the teacher who must approve them.
CREATE POLICY pending_roster ON dev.learners FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM dev.enrollments e WHERE e.learner_id=id AND e.status='pending' AND dev.teacher_has_class(e.class_id)));

CREATE FUNCTION dev.register_teacher_key(public_key text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM dev.teachers WHERE id=auth.uid()) THEN RAISE EXCEPTION 'Teacher required';END IF;
 INSERT INTO dev.teacher_keys VALUES(auth.uid(),public_key) ON CONFLICT(teacher_id) DO UPDATE SET public_key=excluded.public_key;
END $$;
CREATE FUNCTION dev.sync_pairings() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'classId',p.class_id,'learnerId',p.learner_id,'deviceId',p.device_id,'secret',p.secret,'name',l.display_name,'teacherKeys',coalesce((SELECT jsonb_object_agg(k.teacher_id,k.public_key) FROM dev.teacher_keys k JOIN dev.teacher_assignments a ON a.teacher_id=k.teacher_id WHERE a.class_id=p.class_id AND a.from_at<=now() AND (a.to_at IS NULL OR a.to_at>now())),'{}'::jsonb))),'[]'::jsonb)
 FROM dev.pairings p JOIN dev.learners l ON l.id=p.learner_id JOIN dev.enrollments e ON e.class_id=p.class_id AND e.learner_id=p.learner_id JOIN dev.devices d ON d.id=p.device_id
 WHERE p.revoked_at IS NULL AND d.revoked_at IS NULL AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now()) AND (dev.teacher_has_class(p.class_id) OR d.user_id=auth.uid()) AND dev.has_consent(p.learner_id,'core') AND dev.has_consent(p.learner_id,'serverSync')
$$;
CREATE FUNCTION dev.pull_changes(after_seq bigint DEFAULT 0) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('interventions',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.delivery_seq) FROM (SELECT i.* FROM dev.interventions i WHERE i.delivery_seq>after_seq AND dev.can_read_learner(i.learner_id) ORDER BY i.delivery_seq LIMIT 500)i),'[]'::jsonb),'erasures',coalesce((SELECT jsonb_agg(learner_id) FROM dev.erasure_targets WHERE user_id=auth.uid() AND acknowledged_at IS NULL),'[]'::jsonb))
$$;
CREATE FUNCTION dev.ack_erasure(learner text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 UPDATE dev.erasure_targets SET acknowledged_at=now() WHERE learner_id=learner AND user_id=auth.uid()
$$;

-- A paired, assigned teacher may relay only this learner's authenticated bundle.
-- Restore request identity even on failure; callers cannot choose a device user.
CREATE FUNCTION dev.relay_events(pair_id uuid,batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p dev.pairings; device_user uuid; original_sub text:=current_setting('request.jwt.claim.sub',true);original_claims text:=current_setting('request.jwt.claims',true);result jsonb;
BEGIN
 SELECT * INTO p FROM dev.pairings WHERE id=pair_id AND revoked_at IS NULL;
 IF p.id IS NULL OR NOT dev.teacher_has_class(p.class_id) OR NOT EXISTS(SELECT 1 FROM dev.enrollments WHERE class_id=p.class_id AND learner_id=p.learner_id AND status='active' AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Pairing not authorized';END IF;
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR EXISTS(SELECT 1 FROM jsonb_array_elements(batch)e WHERE e->>'learnerId' IS DISTINCT FROM p.learner_id OR e->>'deviceId' IS DISTINCT FROM p.device_id) THEN RAISE EXCEPTION 'Events outside pairing';END IF;
 SELECT user_id INTO device_user FROM dev.devices WHERE id=p.device_id AND revoked_at IS NULL;
 IF device_user IS NULL THEN RAISE EXCEPTION 'Device revoked';END IF;
 PERFORM set_config('request.jwt.claim.sub',device_user::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',device_user,'role','authenticated')::text,true);
 BEGIN result:=dev.ingest_events(batch);
 EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claim.sub',coalesce(original_sub,''),true);PERFORM set_config('request.jwt.claims',coalesce(original_claims,''),true);RAISE;
 END;
 PERFORM set_config('request.jwt.claim.sub',coalesce(original_sub,''),true);PERFORM set_config('request.jwt.claims',coalesce(original_claims,''),true);
 RETURN result;
END $$;
REVOKE ALL ON dev.join_attempts,dev.pairings,dev.teacher_keys FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION dev.register_device(text),dev.create_join_code(uuid),dev.join_class(text,text,text,text,boolean,boolean),dev.review_enrollment(uuid,text,boolean,text),dev.register_teacher_key(text),dev.sync_pairings(),dev.pull_changes(bigint),dev.ack_erasure(text),dev.relay_events(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION dev.register_device(text),dev.create_join_code(uuid),dev.join_class(text,text,text,text,boolean,boolean),dev.review_enrollment(uuid,text,boolean,text),dev.register_teacher_key(text),dev.sync_pairings(),dev.pull_changes(bigint),dev.ack_erasure(text),dev.relay_events(uuid,jsonb) TO authenticated;
GRANT ALL ON dev.join_attempts,dev.pairings,dev.teacher_keys TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA dev TO service_role;
ALTER FUNCTION dev.ingest_events(jsonb) RENAME TO ingest_events_base;
REVOKE EXECUTE ON FUNCTION dev.ingest_events_base(jsonb) FROM authenticated;
CREATE FUNCTION dev.ingest_events(batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb;
BEGIN
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR octet_length(batch::text)>4194304 THEN RAISE EXCEPTION 'Invalid batch';END IF;
 FOR e IN SELECT value FROM jsonb_array_elements(batch) LOOP
  IF e->>'type' NOT IN ('LearnerErased','ConsentRevoked') AND NOT EXISTS(SELECT 1 FROM dev.enrollments WHERE learner_id=e->>'learnerId' AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) AND NOT EXISTS(SELECT 1 FROM dev.erasure_targets WHERE learner_id=e->>'learnerId' AND user_id=auth.uid()) THEN RAISE EXCEPTION 'Teacher approval required';END IF;
 END LOOP;
 RETURN dev.ingest_events_base(batch);
END $$;
REVOKE ALL ON FUNCTION dev.ingest_events(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION dev.ingest_events(jsonb) TO authenticated,service_role;
CREATE FUNCTION dev.refresh_class_insights(target_class uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT dev.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned';END IF;
 INSERT INTO dev.insights(learner_id,node_id,claim,evidence_ids)
 SELECT learner_id,node_id,format('%s of the last %s attempts on %s scored below 50%%.',count(*) FILTER(WHERE score<.5),count(*),node_id),array_agg(id ORDER BY hlc,id)
 FROM(SELECT e.learner_id,e.payload->>'nodeId' node_id,e.id,e.hlc,(e.payload->>'score')::double precision score,row_number() OVER(PARTITION BY e.learner_id,e.payload->>'nodeId' ORDER BY e.hlc DESC,e.id DESC)rn FROM dev.events e JOIN dev.enrollments r ON r.learner_id=e.learner_id WHERE r.class_id=target_class AND r.status='active' AND e.type IN('PracticeAttempt','AssessmentItemAnswered')) recent
 WHERE rn<=14 GROUP BY learner_id,node_id HAVING count(*)>=6 AND count(*) FILTER(WHERE score<.5)::double precision/count(*)>=.6
 ON CONFLICT(learner_id,node_id) WHERE status='open' DO UPDATE SET claim=excluded.claim,evidence_ids=excluded.evidence_ids;
END $$;
REVOKE ALL ON FUNCTION dev.refresh_class_insights(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION dev.refresh_class_insights(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION dev.teacher_intervene(target_learner text,target_class uuid,target_node text,action_kind text,insight_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT dev.teacher_has_class(target_class) OR NOT EXISTS(SELECT 1 FROM dev.enrollments WHERE learner_id=target_learner AND class_id=target_class AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF action_kind NOT IN ('approve','reject','assign','pin','unpin','replace') THEN RAISE EXCEPTION 'Invalid intervention';END IF;
 INSERT INTO dev.interventions(learner_id,class_id,teacher_id,node_id,kind) VALUES(target_learner,target_class,auth.uid(),target_node,action_kind) RETURNING id INTO result;
 IF insight_id IS NOT NULL THEN
  UPDATE dev.insights SET status=CASE WHEN action_kind='reject' THEN 'rejected' ELSE 'approved' END,reviewed_by=auth.uid() WHERE id=insight_id AND learner_id=target_learner AND node_id=target_node AND status='open';
  IF NOT FOUND THEN RAISE EXCEPTION 'Insight does not match learner';END IF;
 END IF;
 INSERT INTO dev.audit_log(actor,action,target_hash) VALUES(auth.uid(),'intervention:'||action_kind,encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN result;
END $$;

-- Additive Phase 3 application RPCs. All data remains schema-isolated.
CREATE TABLE qa.join_attempts(user_id uuid PRIMARY KEY REFERENCES auth.users(id),window_start timestamptz NOT NULL,attempts integer NOT NULL);
CREATE TABLE qa.pairings(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),class_id uuid NOT NULL REFERENCES qa.classes(id) ON DELETE CASCADE,learner_id text NOT NULL REFERENCES qa.learners(id) ON DELETE CASCADE,device_id text NOT NULL REFERENCES qa.devices(id),secret text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32),'hex'),revoked_at timestamptz,UNIQUE(class_id,learner_id,device_id));
CREATE TABLE qa.teacher_keys(teacher_id uuid PRIMARY KEY REFERENCES qa.teachers(id),public_key text NOT NULL CHECK(length(public_key)=44));
ALTER TABLE qa.interventions ADD COLUMN delivery_seq bigint GENERATED ALWAYS AS IDENTITY;
CREATE UNIQUE INDEX ON qa.interventions(delivery_seq);
ALTER TABLE qa.join_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE qa.pairings ENABLE ROW LEVEL SECURITY;
ALTER TABLE qa.teacher_keys ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION qa.register_device(device text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR device IS NULL OR device !~ '^[A-Za-z0-9_-]{1,80}$' OR EXISTS(SELECT 1 FROM qa.teachers WHERE id=auth.uid()) THEN RAISE EXCEPTION 'Invalid device account';END IF;
 INSERT INTO qa.devices(id,user_id) VALUES(device,auth.uid()) ON CONFLICT DO NOTHING;
 IF NOT EXISTS(SELECT 1 FROM qa.devices WHERE id=device AND user_id=auth.uid() AND revoked_at IS NULL) THEN RAISE EXCEPTION 'Device identity already bound';END IF;
END $$;

CREATE FUNCTION qa.create_join_code(target_class uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE code text:=upper(encode(extensions.gen_random_bytes(8),'hex'));
BEGIN
 IF NOT qa.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 UPDATE qa.classes SET code_hash=encode(extensions.digest(code,'sha256'),'hex'),code_expires_at=now()+interval '20 minutes' WHERE id=target_class;
 RETURN code;
END $$;

CREATE FUNCTION qa.join_class(code text,learner text,display_name text,age_band text,is_minor boolean,sync_consent boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c qa.classes;d text;attempt_count integer;
BEGIN
 SELECT id INTO d FROM qa.devices WHERE user_id=auth.uid() AND revoked_at IS NULL;
 IF d IS NULL THEN RAISE EXCEPTION 'Register this device first';END IF;
 INSERT INTO qa.join_attempts VALUES(auth.uid(),now(),1) ON CONFLICT(user_id) DO UPDATE SET attempts=CASE WHEN qa.join_attempts.window_start<now()-interval '1 hour' THEN 1 ELSE qa.join_attempts.attempts+1 END,window_start=CASE WHEN qa.join_attempts.window_start<now()-interval '1 hour' THEN now() ELSE qa.join_attempts.window_start END RETURNING attempts INTO attempt_count;
 IF attempt_count>10 THEN RETURN jsonb_build_object('error','Too many join attempts. Try again in an hour.');END IF;
 SELECT * INTO c FROM qa.classes WHERE code_hash=encode(extensions.digest(upper(trim(code)),'sha256'),'hex') AND code_expires_at>now();
 IF NOT FOUND THEN RETURN jsonb_build_object('error','Class code is invalid or expired.');END IF;
 IF sync_consent IS DISTINCT FROM true OR is_minor IS NULL OR age_band NOT IN ('child','student','adult') OR (age_band='child' AND NOT is_minor) THEN RAISE EXCEPTION 'Consent and valid profile required';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(learner,0));
 IF EXISTS(SELECT 1 FROM qa.learners WHERE id=learner) AND NOT qa.owns_learner(learner) THEN RAISE EXCEPTION 'Learner identity belongs to another device';END IF;
 IF EXISTS(SELECT 1 FROM qa.learners WHERE id=learner AND (org_id<>c.org_id OR minor<>is_minor)) THEN RAISE EXCEPTION 'Profile organization or age classification mismatch';END IF;
 INSERT INTO qa.learners(id,org_id,display_name,age_band,minor) VALUES(learner,c.org_id,display_name,age_band,is_minor) ON CONFLICT(id) DO NOTHING;
 INSERT INTO qa.device_learners VALUES(d,learner) ON CONFLICT DO NOTHING;
 INSERT INTO qa.enrollments(class_id,learner_id,status) VALUES(c.id,learner,'pending') ON CONFLICT(class_id,learner_id) DO NOTHING;
 IF NOT is_minor THEN
  INSERT INTO qa.consents(learner_id,purpose,verified_via,version) SELECT learner,p,'self',1 FROM unnest(ARRAY['core','serverSync']) p WHERE NOT qa.has_consent(learner,p);
 END IF;
 INSERT INTO qa.pairings(class_id,learner_id,device_id) VALUES(c.id,learner,d) ON CONFLICT DO NOTHING;
 RETURN jsonb_build_object('classId',c.id,'className',c.name,'status',(SELECT status FROM qa.enrollments WHERE class_id=c.id AND learner_id=learner));
END $$;

CREATE FUNCTION qa.review_enrollment(target_class uuid,target_learner text,approve boolean,witness_reference text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g uuid;minor_learner boolean;
BEGIN
 IF NOT qa.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 SELECT l.minor INTO minor_learner FROM qa.learners l JOIN qa.enrollments e ON e.learner_id=l.id WHERE l.id=target_learner AND e.class_id=target_class AND e.status='pending' FOR UPDATE OF e;
 IF NOT FOUND THEN RAISE EXCEPTION 'No pending enrollment';END IF;
 IF approve AND minor_learner THEN
  IF witness_reference IS NULL OR length(trim(witness_reference)) NOT BETWEEN 6 AND 120 THEN RAISE EXCEPTION 'Witnessed guardian consent reference required';END IF;
  INSERT INTO qa.guardians(learner_id,contact_hash,verified_via,verification_reference) VALUES(target_learner,encode(extensions.digest(witness_reference,'sha256'),'hex'),'teacherWitnessedPaper',witness_reference) RETURNING id INTO g;
  INSERT INTO qa.consents(learner_id,purpose,guardian_id,verified_via,version) SELECT target_learner,p,g,'teacherWitnessedPaper',1 FROM unnest(ARRAY['core','serverSync']) p WHERE NOT qa.has_consent(target_learner,p);
 END IF;
 UPDATE qa.enrollments SET status=CASE WHEN approve THEN 'active' ELSE 'left' END,to_at=CASE WHEN approve THEN NULL ELSE now() END WHERE class_id=target_class AND learner_id=target_learner;
 IF NOT approve THEN UPDATE qa.pairings SET revoked_at=now() WHERE class_id=target_class AND learner_id=target_learner;END IF;
END $$;
-- Pending identities are visible only to the teacher who must approve them.
CREATE POLICY pending_roster ON qa.learners FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM qa.enrollments e WHERE e.learner_id=id AND e.status='pending' AND qa.teacher_has_class(e.class_id)));

CREATE FUNCTION qa.register_teacher_key(public_key text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM qa.teachers WHERE id=auth.uid()) THEN RAISE EXCEPTION 'Teacher required';END IF;
 INSERT INTO qa.teacher_keys VALUES(auth.uid(),public_key) ON CONFLICT(teacher_id) DO UPDATE SET public_key=excluded.public_key;
END $$;
CREATE FUNCTION qa.sync_pairings() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'classId',p.class_id,'learnerId',p.learner_id,'deviceId',p.device_id,'secret',p.secret,'name',l.display_name,'teacherKeys',coalesce((SELECT jsonb_object_agg(k.teacher_id,k.public_key) FROM qa.teacher_keys k JOIN qa.teacher_assignments a ON a.teacher_id=k.teacher_id WHERE a.class_id=p.class_id AND a.from_at<=now() AND (a.to_at IS NULL OR a.to_at>now())),'{}'::jsonb))),'[]'::jsonb)
 FROM qa.pairings p JOIN qa.learners l ON l.id=p.learner_id JOIN qa.enrollments e ON e.class_id=p.class_id AND e.learner_id=p.learner_id JOIN qa.devices d ON d.id=p.device_id
 WHERE p.revoked_at IS NULL AND d.revoked_at IS NULL AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now()) AND (qa.teacher_has_class(p.class_id) OR d.user_id=auth.uid()) AND qa.has_consent(p.learner_id,'core') AND qa.has_consent(p.learner_id,'serverSync')
$$;
CREATE FUNCTION qa.pull_changes(after_seq bigint DEFAULT 0) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('interventions',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.delivery_seq) FROM (SELECT i.* FROM qa.interventions i WHERE i.delivery_seq>after_seq AND qa.can_read_learner(i.learner_id) ORDER BY i.delivery_seq LIMIT 500)i),'[]'::jsonb),'erasures',coalesce((SELECT jsonb_agg(learner_id) FROM qa.erasure_targets WHERE user_id=auth.uid() AND acknowledged_at IS NULL),'[]'::jsonb))
$$;
CREATE FUNCTION qa.ack_erasure(learner text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 UPDATE qa.erasure_targets SET acknowledged_at=now() WHERE learner_id=learner AND user_id=auth.uid()
$$;

-- A paired, assigned teacher may relay only this learner's authenticated bundle.
-- Restore request identity even on failure; callers cannot choose a device user.
CREATE FUNCTION qa.relay_events(pair_id uuid,batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p qa.pairings; device_user uuid; original_sub text:=current_setting('request.jwt.claim.sub',true);original_claims text:=current_setting('request.jwt.claims',true);result jsonb;
BEGIN
 SELECT * INTO p FROM qa.pairings WHERE id=pair_id AND revoked_at IS NULL;
 IF p.id IS NULL OR NOT qa.teacher_has_class(p.class_id) OR NOT EXISTS(SELECT 1 FROM qa.enrollments WHERE class_id=p.class_id AND learner_id=p.learner_id AND status='active' AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Pairing not authorized';END IF;
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR EXISTS(SELECT 1 FROM jsonb_array_elements(batch)e WHERE e->>'learnerId' IS DISTINCT FROM p.learner_id OR e->>'deviceId' IS DISTINCT FROM p.device_id) THEN RAISE EXCEPTION 'Events outside pairing';END IF;
 SELECT user_id INTO device_user FROM qa.devices WHERE id=p.device_id AND revoked_at IS NULL;
 IF device_user IS NULL THEN RAISE EXCEPTION 'Device revoked';END IF;
 PERFORM set_config('request.jwt.claim.sub',device_user::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',device_user,'role','authenticated')::text,true);
 BEGIN result:=qa.ingest_events(batch);
 EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claim.sub',coalesce(original_sub,''),true);PERFORM set_config('request.jwt.claims',coalesce(original_claims,''),true);RAISE;
 END;
 PERFORM set_config('request.jwt.claim.sub',coalesce(original_sub,''),true);PERFORM set_config('request.jwt.claims',coalesce(original_claims,''),true);
 RETURN result;
END $$;
REVOKE ALL ON qa.join_attempts,qa.pairings,qa.teacher_keys FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION qa.register_device(text),qa.create_join_code(uuid),qa.join_class(text,text,text,text,boolean,boolean),qa.review_enrollment(uuid,text,boolean,text),qa.register_teacher_key(text),qa.sync_pairings(),qa.pull_changes(bigint),qa.ack_erasure(text),qa.relay_events(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION qa.register_device(text),qa.create_join_code(uuid),qa.join_class(text,text,text,text,boolean,boolean),qa.review_enrollment(uuid,text,boolean,text),qa.register_teacher_key(text),qa.sync_pairings(),qa.pull_changes(bigint),qa.ack_erasure(text),qa.relay_events(uuid,jsonb) TO authenticated;
GRANT ALL ON qa.join_attempts,qa.pairings,qa.teacher_keys TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA qa TO service_role;
ALTER FUNCTION qa.ingest_events(jsonb) RENAME TO ingest_events_base;
REVOKE EXECUTE ON FUNCTION qa.ingest_events_base(jsonb) FROM authenticated;
CREATE FUNCTION qa.ingest_events(batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb;
BEGIN
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR octet_length(batch::text)>4194304 THEN RAISE EXCEPTION 'Invalid batch';END IF;
 FOR e IN SELECT value FROM jsonb_array_elements(batch) LOOP
  IF e->>'type' NOT IN ('LearnerErased','ConsentRevoked') AND NOT EXISTS(SELECT 1 FROM qa.enrollments WHERE learner_id=e->>'learnerId' AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) AND NOT EXISTS(SELECT 1 FROM qa.erasure_targets WHERE learner_id=e->>'learnerId' AND user_id=auth.uid()) THEN RAISE EXCEPTION 'Teacher approval required';END IF;
 END LOOP;
 RETURN qa.ingest_events_base(batch);
END $$;
REVOKE ALL ON FUNCTION qa.ingest_events(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION qa.ingest_events(jsonb) TO authenticated,service_role;
CREATE FUNCTION qa.refresh_class_insights(target_class uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT qa.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned';END IF;
 INSERT INTO qa.insights(learner_id,node_id,claim,evidence_ids)
 SELECT learner_id,node_id,format('%s of the last %s attempts on %s scored below 50%%.',count(*) FILTER(WHERE score<.5),count(*),node_id),array_agg(id ORDER BY hlc,id)
 FROM(SELECT e.learner_id,e.payload->>'nodeId' node_id,e.id,e.hlc,(e.payload->>'score')::double precision score,row_number() OVER(PARTITION BY e.learner_id,e.payload->>'nodeId' ORDER BY e.hlc DESC,e.id DESC)rn FROM qa.events e JOIN qa.enrollments r ON r.learner_id=e.learner_id WHERE r.class_id=target_class AND r.status='active' AND e.type IN('PracticeAttempt','AssessmentItemAnswered')) recent
 WHERE rn<=14 GROUP BY learner_id,node_id HAVING count(*)>=6 AND count(*) FILTER(WHERE score<.5)::double precision/count(*)>=.6
 ON CONFLICT(learner_id,node_id) WHERE status='open' DO UPDATE SET claim=excluded.claim,evidence_ids=excluded.evidence_ids;
END $$;
REVOKE ALL ON FUNCTION qa.refresh_class_insights(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION qa.refresh_class_insights(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION qa.teacher_intervene(target_learner text,target_class uuid,target_node text,action_kind text,insight_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT qa.teacher_has_class(target_class) OR NOT EXISTS(SELECT 1 FROM qa.enrollments WHERE learner_id=target_learner AND class_id=target_class AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF action_kind NOT IN ('approve','reject','assign','pin','unpin','replace') THEN RAISE EXCEPTION 'Invalid intervention';END IF;
 INSERT INTO qa.interventions(learner_id,class_id,teacher_id,node_id,kind) VALUES(target_learner,target_class,auth.uid(),target_node,action_kind) RETURNING id INTO result;
 IF insight_id IS NOT NULL THEN
  UPDATE qa.insights SET status=CASE WHEN action_kind='reject' THEN 'rejected' ELSE 'approved' END,reviewed_by=auth.uid() WHERE id=insight_id AND learner_id=target_learner AND node_id=target_node AND status='open';
  IF NOT FOUND THEN RAISE EXCEPTION 'Insight does not match learner';END IF;
 END IF;
 INSERT INTO qa.audit_log(actor,action,target_hash) VALUES(auth.uid(),'intervention:'||action_kind,encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN result;
END $$;

-- Additive Phase 3 application RPCs. All data remains schema-isolated.
CREATE TABLE prod.join_attempts(user_id uuid PRIMARY KEY REFERENCES auth.users(id),window_start timestamptz NOT NULL,attempts integer NOT NULL);
CREATE TABLE prod.pairings(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),class_id uuid NOT NULL REFERENCES prod.classes(id) ON DELETE CASCADE,learner_id text NOT NULL REFERENCES prod.learners(id) ON DELETE CASCADE,device_id text NOT NULL REFERENCES prod.devices(id),secret text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32),'hex'),revoked_at timestamptz,UNIQUE(class_id,learner_id,device_id));
CREATE TABLE prod.teacher_keys(teacher_id uuid PRIMARY KEY REFERENCES prod.teachers(id),public_key text NOT NULL CHECK(length(public_key)=44));
ALTER TABLE prod.interventions ADD COLUMN delivery_seq bigint GENERATED ALWAYS AS IDENTITY;
CREATE UNIQUE INDEX ON prod.interventions(delivery_seq);
ALTER TABLE prod.join_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE prod.pairings ENABLE ROW LEVEL SECURITY;
ALTER TABLE prod.teacher_keys ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION prod.register_device(device text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR device IS NULL OR device !~ '^[A-Za-z0-9_-]{1,80}$' OR EXISTS(SELECT 1 FROM prod.teachers WHERE id=auth.uid()) THEN RAISE EXCEPTION 'Invalid device account';END IF;
 INSERT INTO prod.devices(id,user_id) VALUES(device,auth.uid()) ON CONFLICT DO NOTHING;
 IF NOT EXISTS(SELECT 1 FROM prod.devices WHERE id=device AND user_id=auth.uid() AND revoked_at IS NULL) THEN RAISE EXCEPTION 'Device identity already bound';END IF;
END $$;

CREATE FUNCTION prod.create_join_code(target_class uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE code text:=upper(encode(extensions.gen_random_bytes(8),'hex'));
BEGIN
 IF NOT prod.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 UPDATE prod.classes SET code_hash=encode(extensions.digest(code,'sha256'),'hex'),code_expires_at=now()+interval '20 minutes' WHERE id=target_class;
 RETURN code;
END $$;

CREATE FUNCTION prod.join_class(code text,learner text,display_name text,age_band text,is_minor boolean,sync_consent boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c prod.classes;d text;attempt_count integer;
BEGIN
 SELECT id INTO d FROM prod.devices WHERE user_id=auth.uid() AND revoked_at IS NULL;
 IF d IS NULL THEN RAISE EXCEPTION 'Register this device first';END IF;
 INSERT INTO prod.join_attempts VALUES(auth.uid(),now(),1) ON CONFLICT(user_id) DO UPDATE SET attempts=CASE WHEN prod.join_attempts.window_start<now()-interval '1 hour' THEN 1 ELSE prod.join_attempts.attempts+1 END,window_start=CASE WHEN prod.join_attempts.window_start<now()-interval '1 hour' THEN now() ELSE prod.join_attempts.window_start END RETURNING attempts INTO attempt_count;
 IF attempt_count>10 THEN RETURN jsonb_build_object('error','Too many join attempts. Try again in an hour.');END IF;
 SELECT * INTO c FROM prod.classes WHERE code_hash=encode(extensions.digest(upper(trim(code)),'sha256'),'hex') AND code_expires_at>now();
 IF NOT FOUND THEN RETURN jsonb_build_object('error','Class code is invalid or expired.');END IF;
 IF sync_consent IS DISTINCT FROM true OR is_minor IS NULL OR age_band NOT IN ('child','student','adult') OR (age_band='child' AND NOT is_minor) THEN RAISE EXCEPTION 'Consent and valid profile required';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(learner,0));
 IF EXISTS(SELECT 1 FROM prod.learners WHERE id=learner) AND NOT prod.owns_learner(learner) THEN RAISE EXCEPTION 'Learner identity belongs to another device';END IF;
 IF EXISTS(SELECT 1 FROM prod.learners WHERE id=learner AND (org_id<>c.org_id OR minor<>is_minor)) THEN RAISE EXCEPTION 'Profile organization or age classification mismatch';END IF;
 INSERT INTO prod.learners(id,org_id,display_name,age_band,minor) VALUES(learner,c.org_id,display_name,age_band,is_minor) ON CONFLICT(id) DO NOTHING;
 INSERT INTO prod.device_learners VALUES(d,learner) ON CONFLICT DO NOTHING;
 INSERT INTO prod.enrollments(class_id,learner_id,status) VALUES(c.id,learner,'pending') ON CONFLICT(class_id,learner_id) DO NOTHING;
 IF NOT is_minor THEN
  INSERT INTO prod.consents(learner_id,purpose,verified_via,version) SELECT learner,p,'self',1 FROM unnest(ARRAY['core','serverSync']) p WHERE NOT prod.has_consent(learner,p);
 END IF;
 INSERT INTO prod.pairings(class_id,learner_id,device_id) VALUES(c.id,learner,d) ON CONFLICT DO NOTHING;
 RETURN jsonb_build_object('classId',c.id,'className',c.name,'status',(SELECT status FROM prod.enrollments WHERE class_id=c.id AND learner_id=learner));
END $$;

CREATE FUNCTION prod.review_enrollment(target_class uuid,target_learner text,approve boolean,witness_reference text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g uuid;minor_learner boolean;
BEGIN
 IF NOT prod.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 SELECT l.minor INTO minor_learner FROM prod.learners l JOIN prod.enrollments e ON e.learner_id=l.id WHERE l.id=target_learner AND e.class_id=target_class AND e.status='pending' FOR UPDATE OF e;
 IF NOT FOUND THEN RAISE EXCEPTION 'No pending enrollment';END IF;
 IF approve AND minor_learner THEN
  IF witness_reference IS NULL OR length(trim(witness_reference)) NOT BETWEEN 6 AND 120 THEN RAISE EXCEPTION 'Witnessed guardian consent reference required';END IF;
  INSERT INTO prod.guardians(learner_id,contact_hash,verified_via,verification_reference) VALUES(target_learner,encode(extensions.digest(witness_reference,'sha256'),'hex'),'teacherWitnessedPaper',witness_reference) RETURNING id INTO g;
  INSERT INTO prod.consents(learner_id,purpose,guardian_id,verified_via,version) SELECT target_learner,p,g,'teacherWitnessedPaper',1 FROM unnest(ARRAY['core','serverSync']) p WHERE NOT prod.has_consent(target_learner,p);
 END IF;
 UPDATE prod.enrollments SET status=CASE WHEN approve THEN 'active' ELSE 'left' END,to_at=CASE WHEN approve THEN NULL ELSE now() END WHERE class_id=target_class AND learner_id=target_learner;
 IF NOT approve THEN UPDATE prod.pairings SET revoked_at=now() WHERE class_id=target_class AND learner_id=target_learner;END IF;
END $$;
-- Pending identities are visible only to the teacher who must approve them.
CREATE POLICY pending_roster ON prod.learners FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM prod.enrollments e WHERE e.learner_id=id AND e.status='pending' AND prod.teacher_has_class(e.class_id)));

CREATE FUNCTION prod.register_teacher_key(public_key text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM prod.teachers WHERE id=auth.uid()) THEN RAISE EXCEPTION 'Teacher required';END IF;
 INSERT INTO prod.teacher_keys VALUES(auth.uid(),public_key) ON CONFLICT(teacher_id) DO UPDATE SET public_key=excluded.public_key;
END $$;
CREATE FUNCTION prod.sync_pairings() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'classId',p.class_id,'learnerId',p.learner_id,'deviceId',p.device_id,'secret',p.secret,'name',l.display_name,'teacherKeys',coalesce((SELECT jsonb_object_agg(k.teacher_id,k.public_key) FROM prod.teacher_keys k JOIN prod.teacher_assignments a ON a.teacher_id=k.teacher_id WHERE a.class_id=p.class_id AND a.from_at<=now() AND (a.to_at IS NULL OR a.to_at>now())),'{}'::jsonb))),'[]'::jsonb)
 FROM prod.pairings p JOIN prod.learners l ON l.id=p.learner_id JOIN prod.enrollments e ON e.class_id=p.class_id AND e.learner_id=p.learner_id JOIN prod.devices d ON d.id=p.device_id
 WHERE p.revoked_at IS NULL AND d.revoked_at IS NULL AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now()) AND (prod.teacher_has_class(p.class_id) OR d.user_id=auth.uid()) AND prod.has_consent(p.learner_id,'core') AND prod.has_consent(p.learner_id,'serverSync')
$$;
CREATE FUNCTION prod.pull_changes(after_seq bigint DEFAULT 0) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('interventions',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.delivery_seq) FROM (SELECT i.* FROM prod.interventions i WHERE i.delivery_seq>after_seq AND prod.can_read_learner(i.learner_id) ORDER BY i.delivery_seq LIMIT 500)i),'[]'::jsonb),'erasures',coalesce((SELECT jsonb_agg(learner_id) FROM prod.erasure_targets WHERE user_id=auth.uid() AND acknowledged_at IS NULL),'[]'::jsonb))
$$;
CREATE FUNCTION prod.ack_erasure(learner text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 UPDATE prod.erasure_targets SET acknowledged_at=now() WHERE learner_id=learner AND user_id=auth.uid()
$$;

-- A paired, assigned teacher may relay only this learner's authenticated bundle.
-- Restore request identity even on failure; callers cannot choose a device user.
CREATE FUNCTION prod.relay_events(pair_id uuid,batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p prod.pairings; device_user uuid; original_sub text:=current_setting('request.jwt.claim.sub',true);original_claims text:=current_setting('request.jwt.claims',true);result jsonb;
BEGIN
 SELECT * INTO p FROM prod.pairings WHERE id=pair_id AND revoked_at IS NULL;
 IF p.id IS NULL OR NOT prod.teacher_has_class(p.class_id) OR NOT EXISTS(SELECT 1 FROM prod.enrollments WHERE class_id=p.class_id AND learner_id=p.learner_id AND status='active' AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Pairing not authorized';END IF;
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR EXISTS(SELECT 1 FROM jsonb_array_elements(batch)e WHERE e->>'learnerId' IS DISTINCT FROM p.learner_id OR e->>'deviceId' IS DISTINCT FROM p.device_id) THEN RAISE EXCEPTION 'Events outside pairing';END IF;
 SELECT user_id INTO device_user FROM prod.devices WHERE id=p.device_id AND revoked_at IS NULL;
 IF device_user IS NULL THEN RAISE EXCEPTION 'Device revoked';END IF;
 PERFORM set_config('request.jwt.claim.sub',device_user::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',device_user,'role','authenticated')::text,true);
 BEGIN result:=prod.ingest_events(batch);
 EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claim.sub',coalesce(original_sub,''),true);PERFORM set_config('request.jwt.claims',coalesce(original_claims,''),true);RAISE;
 END;
 PERFORM set_config('request.jwt.claim.sub',coalesce(original_sub,''),true);PERFORM set_config('request.jwt.claims',coalesce(original_claims,''),true);
 RETURN result;
END $$;
REVOKE ALL ON prod.join_attempts,prod.pairings,prod.teacher_keys FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION prod.register_device(text),prod.create_join_code(uuid),prod.join_class(text,text,text,text,boolean,boolean),prod.review_enrollment(uuid,text,boolean,text),prod.register_teacher_key(text),prod.sync_pairings(),prod.pull_changes(bigint),prod.ack_erasure(text),prod.relay_events(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION prod.register_device(text),prod.create_join_code(uuid),prod.join_class(text,text,text,text,boolean,boolean),prod.review_enrollment(uuid,text,boolean,text),prod.register_teacher_key(text),prod.sync_pairings(),prod.pull_changes(bigint),prod.ack_erasure(text),prod.relay_events(uuid,jsonb) TO authenticated;
GRANT ALL ON prod.join_attempts,prod.pairings,prod.teacher_keys TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA prod TO service_role;
ALTER FUNCTION prod.ingest_events(jsonb) RENAME TO ingest_events_base;
REVOKE EXECUTE ON FUNCTION prod.ingest_events_base(jsonb) FROM authenticated;
CREATE FUNCTION prod.ingest_events(batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb;
BEGIN
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR octet_length(batch::text)>4194304 THEN RAISE EXCEPTION 'Invalid batch';END IF;
 FOR e IN SELECT value FROM jsonb_array_elements(batch) LOOP
  IF e->>'type' NOT IN ('LearnerErased','ConsentRevoked') AND NOT EXISTS(SELECT 1 FROM prod.enrollments WHERE learner_id=e->>'learnerId' AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) AND NOT EXISTS(SELECT 1 FROM prod.erasure_targets WHERE learner_id=e->>'learnerId' AND user_id=auth.uid()) THEN RAISE EXCEPTION 'Teacher approval required';END IF;
 END LOOP;
 RETURN prod.ingest_events_base(batch);
END $$;
REVOKE ALL ON FUNCTION prod.ingest_events(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION prod.ingest_events(jsonb) TO authenticated,service_role;
CREATE FUNCTION prod.refresh_class_insights(target_class uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT prod.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned';END IF;
 INSERT INTO prod.insights(learner_id,node_id,claim,evidence_ids)
 SELECT learner_id,node_id,format('%s of the last %s attempts on %s scored below 50%%.',count(*) FILTER(WHERE score<.5),count(*),node_id),array_agg(id ORDER BY hlc,id)
 FROM(SELECT e.learner_id,e.payload->>'nodeId' node_id,e.id,e.hlc,(e.payload->>'score')::double precision score,row_number() OVER(PARTITION BY e.learner_id,e.payload->>'nodeId' ORDER BY e.hlc DESC,e.id DESC)rn FROM prod.events e JOIN prod.enrollments r ON r.learner_id=e.learner_id WHERE r.class_id=target_class AND r.status='active' AND e.type IN('PracticeAttempt','AssessmentItemAnswered')) recent
 WHERE rn<=14 GROUP BY learner_id,node_id HAVING count(*)>=6 AND count(*) FILTER(WHERE score<.5)::double precision/count(*)>=.6
 ON CONFLICT(learner_id,node_id) WHERE status='open' DO UPDATE SET claim=excluded.claim,evidence_ids=excluded.evidence_ids;
END $$;
REVOKE ALL ON FUNCTION prod.refresh_class_insights(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION prod.refresh_class_insights(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION prod.teacher_intervene(target_learner text,target_class uuid,target_node text,action_kind text,insight_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT prod.teacher_has_class(target_class) OR NOT EXISTS(SELECT 1 FROM prod.enrollments WHERE learner_id=target_learner AND class_id=target_class AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF action_kind NOT IN ('approve','reject','assign','pin','unpin','replace') THEN RAISE EXCEPTION 'Invalid intervention';END IF;
 INSERT INTO prod.interventions(learner_id,class_id,teacher_id,node_id,kind) VALUES(target_learner,target_class,auth.uid(),target_node,action_kind) RETURNING id INTO result;
 IF insight_id IS NOT NULL THEN
  UPDATE prod.insights SET status=CASE WHEN action_kind='reject' THEN 'rejected' ELSE 'approved' END,reviewed_by=auth.uid() WHERE id=insight_id AND learner_id=target_learner AND node_id=target_node AND status='open';
  IF NOT FOUND THEN RAISE EXCEPTION 'Insight does not match learner';END IF;
 END IF;
 INSERT INTO prod.audit_log(actor,action,target_hash) VALUES(auth.uid(),'intervention:'||action_kind,encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN result;
END $$;

NOTIFY pgrst, 'reload schema';
