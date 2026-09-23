-- Additive Phase 3 application RPCs. All data remains schema-isolated.
CREATE TABLE __ENV__.join_attempts(user_id uuid PRIMARY KEY REFERENCES auth.users(id),window_start timestamptz NOT NULL,attempts integer NOT NULL);
CREATE TABLE __ENV__.pairings(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),class_id uuid NOT NULL REFERENCES __ENV__.classes(id) ON DELETE CASCADE,learner_id text NOT NULL REFERENCES __ENV__.learners(id) ON DELETE CASCADE,device_id text NOT NULL REFERENCES __ENV__.devices(id),secret text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32),'hex'),revoked_at timestamptz,UNIQUE(class_id,learner_id,device_id));
CREATE TABLE __ENV__.teacher_keys(teacher_id uuid PRIMARY KEY REFERENCES __ENV__.teachers(id),public_key text NOT NULL CHECK(length(public_key)=44));
ALTER TABLE __ENV__.interventions ADD COLUMN delivery_seq bigint GENERATED ALWAYS AS IDENTITY;
CREATE UNIQUE INDEX ON __ENV__.interventions(delivery_seq);
ALTER TABLE __ENV__.join_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE __ENV__.pairings ENABLE ROW LEVEL SECURITY;
ALTER TABLE __ENV__.teacher_keys ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION __ENV__.register_device(device text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR device IS NULL OR device !~ '^[A-Za-z0-9_-]{1,80}$' OR EXISTS(SELECT 1 FROM __ENV__.teachers WHERE id=auth.uid()) THEN RAISE EXCEPTION 'Invalid device account';END IF;
 INSERT INTO __ENV__.devices(id,user_id) VALUES(device,auth.uid()) ON CONFLICT DO NOTHING;
 IF NOT EXISTS(SELECT 1 FROM __ENV__.devices WHERE id=device AND user_id=auth.uid() AND revoked_at IS NULL) THEN RAISE EXCEPTION 'Device identity already bound';END IF;
END $$;

CREATE FUNCTION __ENV__.create_join_code(target_class uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE code text:=upper(encode(extensions.gen_random_bytes(8),'hex'));
BEGIN
 IF NOT __ENV__.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 UPDATE __ENV__.classes SET code_hash=encode(extensions.digest(code,'sha256'),'hex'),code_expires_at=now()+interval '20 minutes' WHERE id=target_class;
 RETURN code;
END $$;

CREATE FUNCTION __ENV__.join_class(code text,learner text,display_name text,age_band text,is_minor boolean,sync_consent boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c __ENV__.classes;d text;attempt_count integer;
BEGIN
 SELECT id INTO d FROM __ENV__.devices WHERE user_id=auth.uid() AND revoked_at IS NULL;
 IF d IS NULL THEN RAISE EXCEPTION 'Register this device first';END IF;
 INSERT INTO __ENV__.join_attempts VALUES(auth.uid(),now(),1) ON CONFLICT(user_id) DO UPDATE SET attempts=CASE WHEN __ENV__.join_attempts.window_start<now()-interval '1 hour' THEN 1 ELSE __ENV__.join_attempts.attempts+1 END,window_start=CASE WHEN __ENV__.join_attempts.window_start<now()-interval '1 hour' THEN now() ELSE __ENV__.join_attempts.window_start END RETURNING attempts INTO attempt_count;
 IF attempt_count>10 THEN RETURN jsonb_build_object('error','Too many join attempts. Try again in an hour.');END IF;
 SELECT * INTO c FROM __ENV__.classes WHERE code_hash=encode(extensions.digest(upper(trim(code)),'sha256'),'hex') AND code_expires_at>now();
 IF NOT FOUND THEN RETURN jsonb_build_object('error','Class code is invalid or expired.');END IF;
 IF sync_consent IS DISTINCT FROM true OR is_minor IS NULL OR age_band NOT IN ('child','student','adult') OR (age_band='child' AND NOT is_minor) THEN RAISE EXCEPTION 'Consent and valid profile required';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(learner,0));
 IF EXISTS(SELECT 1 FROM __ENV__.learners WHERE id=learner) AND NOT __ENV__.owns_learner(learner) THEN RAISE EXCEPTION 'Learner identity belongs to another device';END IF;
 IF EXISTS(SELECT 1 FROM __ENV__.learners WHERE id=learner AND (org_id<>c.org_id OR minor<>is_minor)) THEN RAISE EXCEPTION 'Profile organization or age classification mismatch';END IF;
 INSERT INTO __ENV__.learners(id,org_id,display_name,age_band,minor) VALUES(learner,c.org_id,display_name,age_band,is_minor) ON CONFLICT(id) DO NOTHING;
 INSERT INTO __ENV__.device_learners VALUES(d,learner) ON CONFLICT DO NOTHING;
 INSERT INTO __ENV__.enrollments(class_id,learner_id,status) VALUES(c.id,learner,'pending') ON CONFLICT(class_id,learner_id) DO NOTHING;
 IF NOT is_minor THEN
  INSERT INTO __ENV__.consents(learner_id,purpose,verified_via,version) SELECT learner,p,'self',1 FROM unnest(ARRAY['core','serverSync']) p WHERE NOT __ENV__.has_consent(learner,p);
 END IF;
 INSERT INTO __ENV__.pairings(class_id,learner_id,device_id) VALUES(c.id,learner,d) ON CONFLICT DO NOTHING;
 RETURN jsonb_build_object('classId',c.id,'className',c.name,'status',(SELECT status FROM __ENV__.enrollments WHERE class_id=c.id AND learner_id=learner));
END $$;

CREATE FUNCTION __ENV__.review_enrollment(target_class uuid,target_learner text,approve boolean,witness_reference text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE g uuid;minor_learner boolean;
BEGIN
 IF NOT __ENV__.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 SELECT l.minor INTO minor_learner FROM __ENV__.learners l JOIN __ENV__.enrollments e ON e.learner_id=l.id WHERE l.id=target_learner AND e.class_id=target_class AND e.status='pending' FOR UPDATE OF e;
 IF NOT FOUND THEN RAISE EXCEPTION 'No pending enrollment';END IF;
 IF approve AND minor_learner THEN
  IF witness_reference IS NULL OR length(trim(witness_reference)) NOT BETWEEN 6 AND 120 THEN RAISE EXCEPTION 'Witnessed guardian consent reference required';END IF;
  INSERT INTO __ENV__.guardians(learner_id,contact_hash,verified_via,verification_reference) VALUES(target_learner,encode(extensions.digest(witness_reference,'sha256'),'hex'),'teacherWitnessedPaper',witness_reference) RETURNING id INTO g;
  INSERT INTO __ENV__.consents(learner_id,purpose,guardian_id,verified_via,version) SELECT target_learner,p,g,'teacherWitnessedPaper',1 FROM unnest(ARRAY['core','serverSync']) p WHERE NOT __ENV__.has_consent(target_learner,p);
 END IF;
 UPDATE __ENV__.enrollments SET status=CASE WHEN approve THEN 'active' ELSE 'left' END,to_at=CASE WHEN approve THEN NULL ELSE now() END WHERE class_id=target_class AND learner_id=target_learner;
 IF NOT approve THEN UPDATE __ENV__.pairings SET revoked_at=now() WHERE class_id=target_class AND learner_id=target_learner;END IF;
END $$;
-- Pending identities are visible only to the teacher who must approve them.
CREATE POLICY pending_roster ON __ENV__.learners FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM __ENV__.enrollments e WHERE e.learner_id=id AND e.status='pending' AND __ENV__.teacher_has_class(e.class_id)));

CREATE FUNCTION __ENV__.register_teacher_key(public_key text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM __ENV__.teachers WHERE id=auth.uid()) THEN RAISE EXCEPTION 'Teacher required';END IF;
 INSERT INTO __ENV__.teacher_keys VALUES(auth.uid(),public_key) ON CONFLICT(teacher_id) DO UPDATE SET public_key=excluded.public_key;
END $$;
CREATE FUNCTION __ENV__.sync_pairings() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'classId',p.class_id,'learnerId',p.learner_id,'deviceId',p.device_id,'secret',p.secret,'name',l.display_name,'teacherKeys',coalesce((SELECT jsonb_object_agg(k.teacher_id,k.public_key) FROM __ENV__.teacher_keys k JOIN __ENV__.teacher_assignments a ON a.teacher_id=k.teacher_id WHERE a.class_id=p.class_id AND a.from_at<=now() AND (a.to_at IS NULL OR a.to_at>now())),'{}'::jsonb))),'[]'::jsonb)
 FROM __ENV__.pairings p JOIN __ENV__.learners l ON l.id=p.learner_id JOIN __ENV__.enrollments e ON e.class_id=p.class_id AND e.learner_id=p.learner_id JOIN __ENV__.devices d ON d.id=p.device_id
 WHERE p.revoked_at IS NULL AND d.revoked_at IS NULL AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now()) AND (__ENV__.teacher_has_class(p.class_id) OR d.user_id=auth.uid()) AND __ENV__.has_consent(p.learner_id,'core') AND __ENV__.has_consent(p.learner_id,'serverSync')
$$;
CREATE FUNCTION __ENV__.pull_changes(after_seq bigint DEFAULT 0) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('interventions',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.delivery_seq) FROM (SELECT i.* FROM __ENV__.interventions i WHERE i.delivery_seq>after_seq AND __ENV__.can_read_learner(i.learner_id) ORDER BY i.delivery_seq LIMIT 500)i),'[]'::jsonb),'erasures',coalesce((SELECT jsonb_agg(learner_id) FROM __ENV__.erasure_targets WHERE user_id=auth.uid() AND acknowledged_at IS NULL),'[]'::jsonb))
$$;
CREATE FUNCTION __ENV__.ack_erasure(learner text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 UPDATE __ENV__.erasure_targets SET acknowledged_at=now() WHERE learner_id=learner AND user_id=auth.uid()
$$;

-- A paired, assigned teacher may relay only this learner's authenticated bundle.
-- Restore request identity even on failure; callers cannot choose a device user.
CREATE FUNCTION __ENV__.relay_events(pair_id uuid,batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p __ENV__.pairings; device_user uuid; original_sub text:=current_setting('request.jwt.claim.sub',true);original_claims text:=current_setting('request.jwt.claims',true);result jsonb;
BEGIN
 SELECT * INTO p FROM __ENV__.pairings WHERE id=pair_id AND revoked_at IS NULL;
 IF p.id IS NULL OR NOT __ENV__.teacher_has_class(p.class_id) OR NOT EXISTS(SELECT 1 FROM __ENV__.enrollments WHERE class_id=p.class_id AND learner_id=p.learner_id AND status='active' AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Pairing not authorized';END IF;
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR EXISTS(SELECT 1 FROM jsonb_array_elements(batch)e WHERE e->>'learnerId' IS DISTINCT FROM p.learner_id OR e->>'deviceId' IS DISTINCT FROM p.device_id) THEN RAISE EXCEPTION 'Events outside pairing';END IF;
 SELECT user_id INTO device_user FROM __ENV__.devices WHERE id=p.device_id AND revoked_at IS NULL;
 IF device_user IS NULL THEN RAISE EXCEPTION 'Device revoked';END IF;
 PERFORM set_config('request.jwt.claim.sub',device_user::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',device_user,'role','authenticated')::text,true);
 BEGIN result:=__ENV__.ingest_events(batch);
 EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claim.sub',coalesce(original_sub,''),true);PERFORM set_config('request.jwt.claims',coalesce(original_claims,''),true);RAISE;
 END;
 PERFORM set_config('request.jwt.claim.sub',coalesce(original_sub,''),true);PERFORM set_config('request.jwt.claims',coalesce(original_claims,''),true);
 RETURN result;
END $$;
REVOKE ALL ON __ENV__.join_attempts,__ENV__.pairings,__ENV__.teacher_keys FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION __ENV__.register_device(text),__ENV__.create_join_code(uuid),__ENV__.join_class(text,text,text,text,boolean,boolean),__ENV__.review_enrollment(uuid,text,boolean,text),__ENV__.register_teacher_key(text),__ENV__.sync_pairings(),__ENV__.pull_changes(bigint),__ENV__.ack_erasure(text),__ENV__.relay_events(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION __ENV__.register_device(text),__ENV__.create_join_code(uuid),__ENV__.join_class(text,text,text,text,boolean,boolean),__ENV__.review_enrollment(uuid,text,boolean,text),__ENV__.register_teacher_key(text),__ENV__.sync_pairings(),__ENV__.pull_changes(bigint),__ENV__.ack_erasure(text),__ENV__.relay_events(uuid,jsonb) TO authenticated;
GRANT ALL ON __ENV__.join_attempts,__ENV__.pairings,__ENV__.teacher_keys TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA __ENV__ TO service_role;
ALTER FUNCTION __ENV__.ingest_events(jsonb) RENAME TO ingest_events_base;
REVOKE EXECUTE ON FUNCTION __ENV__.ingest_events_base(jsonb) FROM authenticated;
CREATE FUNCTION __ENV__.ingest_events(batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb;
BEGIN
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR octet_length(batch::text)>4194304 THEN RAISE EXCEPTION 'Invalid batch';END IF;
 FOR e IN SELECT value FROM jsonb_array_elements(batch) LOOP
  IF e->>'type' NOT IN ('LearnerErased','ConsentRevoked') AND NOT EXISTS(SELECT 1 FROM __ENV__.enrollments WHERE learner_id=e->>'learnerId' AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) AND NOT EXISTS(SELECT 1 FROM __ENV__.erasure_targets WHERE learner_id=e->>'learnerId' AND user_id=auth.uid()) THEN RAISE EXCEPTION 'Teacher approval required';END IF;
 END LOOP;
 RETURN __ENV__.ingest_events_base(batch);
END $$;
REVOKE ALL ON FUNCTION __ENV__.ingest_events(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION __ENV__.ingest_events(jsonb) TO authenticated,service_role;
CREATE FUNCTION __ENV__.refresh_class_insights(target_class uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT __ENV__.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned';END IF;
 INSERT INTO __ENV__.insights(learner_id,node_id,claim,evidence_ids)
 SELECT learner_id,node_id,format('%s of the last %s attempts on %s scored below 50%%.',count(*) FILTER(WHERE score<.5),count(*),node_id),array_agg(id ORDER BY hlc,id)
 FROM(SELECT e.learner_id,e.payload->>'nodeId' node_id,e.id,e.hlc,(e.payload->>'score')::double precision score,row_number() OVER(PARTITION BY e.learner_id,e.payload->>'nodeId' ORDER BY e.hlc DESC,e.id DESC)rn FROM __ENV__.events e JOIN __ENV__.enrollments r ON r.learner_id=e.learner_id WHERE r.class_id=target_class AND r.status='active' AND e.type IN('PracticeAttempt','AssessmentItemAnswered')) recent
 WHERE rn<=14 GROUP BY learner_id,node_id HAVING count(*)>=6 AND count(*) FILTER(WHERE score<.5)::double precision/count(*)>=.6
 ON CONFLICT(learner_id,node_id) WHERE status='open' DO UPDATE SET claim=excluded.claim,evidence_ids=excluded.evidence_ids;
END $$;
REVOKE ALL ON FUNCTION __ENV__.refresh_class_insights(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION __ENV__.refresh_class_insights(uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION __ENV__.teacher_intervene(target_learner text,target_class uuid,target_node text,action_kind text,insight_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT __ENV__.teacher_has_class(target_class) OR NOT EXISTS(SELECT 1 FROM __ENV__.enrollments WHERE learner_id=target_learner AND class_id=target_class AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF action_kind NOT IN ('approve','reject','assign','pin','unpin','replace') THEN RAISE EXCEPTION 'Invalid intervention';END IF;
 INSERT INTO __ENV__.interventions(learner_id,class_id,teacher_id,node_id,kind) VALUES(target_learner,target_class,auth.uid(),target_node,action_kind) RETURNING id INTO result;
 IF insight_id IS NOT NULL THEN
  UPDATE __ENV__.insights SET status=CASE WHEN action_kind='reject' THEN 'rejected' ELSE 'approved' END,reviewed_by=auth.uid() WHERE id=insight_id AND learner_id=target_learner AND node_id=target_node AND status='open';
  IF NOT FOUND THEN RAISE EXCEPTION 'Insight does not match learner';END IF;
 END IF;
 INSERT INTO __ENV__.audit_log(actor,action,target_hash) VALUES(auth.uid(),'intervention:'||action_kind,encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN result;
END $$;
