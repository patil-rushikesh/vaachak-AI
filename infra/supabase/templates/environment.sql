CREATE SCHEMA IF NOT EXISTS __ENV__;
REVOKE ALL ON SCHEMA __ENV__ FROM PUBLIC;
GRANT USAGE ON SCHEMA __ENV__ TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA __ENV__ REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE __ENV__.orgs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text NOT NULL,region text NOT NULL DEFAULT 'IN');
CREATE TABLE __ENV__.teachers(id uuid PRIMARY KEY REFERENCES auth.users(id),org_id uuid NOT NULL REFERENCES __ENV__.orgs(id),display_name text NOT NULL);
CREATE TABLE __ENV__.classes(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),org_id uuid NOT NULL REFERENCES __ENV__.orgs(id),name text NOT NULL,code_hash text UNIQUE,code_expires_at timestamptz);
CREATE TABLE __ENV__.teacher_assignments(class_id uuid REFERENCES __ENV__.classes(id) ON DELETE CASCADE,teacher_id uuid REFERENCES __ENV__.teachers(id) ON DELETE CASCADE,from_at timestamptz NOT NULL DEFAULT now(),to_at timestamptz,PRIMARY KEY(class_id,teacher_id),CHECK(to_at IS NULL OR to_at>from_at));
CREATE TABLE __ENV__.learners(id text PRIMARY KEY CHECK(id ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$'),org_id uuid NOT NULL REFERENCES __ENV__.orgs(id),display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 60),age_band text NOT NULL CHECK(age_band IN ('child','student','adult')),minor boolean NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE __ENV__.enrollments(class_id uuid REFERENCES __ENV__.classes(id) ON DELETE CASCADE,learner_id text REFERENCES __ENV__.learners(id) ON DELETE CASCADE,status text NOT NULL CHECK(status IN ('pending','active','left')),from_at timestamptz NOT NULL DEFAULT now(),to_at timestamptz,PRIMARY KEY(class_id,learner_id));
CREATE TABLE __ENV__.guardians(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES __ENV__.learners(id) ON DELETE CASCADE,contact_hash text NOT NULL,verified_via text NOT NULL CHECK(verified_via IN ('otp','teacherWitnessedPaper')),verification_reference text NOT NULL);
CREATE TABLE __ENV__.consents(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES __ENV__.learners(id) ON DELETE CASCADE,purpose text NOT NULL CHECK(purpose IN ('core','microphone','clipRetention','serverSync','telemetry')),guardian_id uuid REFERENCES __ENV__.guardians(id) ON DELETE CASCADE,verified_via text NOT NULL CHECK(verified_via IN ('self','otp','teacherWitnessedPaper')),version integer NOT NULL CHECK(version>0),granted_at timestamptz NOT NULL DEFAULT now(),revoked_at timestamptz);
CREATE TABLE __ENV__.devices(id text PRIMARY KEY,user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id),revoked_at timestamptz,last_seen_at timestamptz);
CREATE TABLE __ENV__.device_learners(device_id text REFERENCES __ENV__.devices(id) ON DELETE CASCADE,learner_id text REFERENCES __ENV__.learners(id) ON DELETE CASCADE,PRIMARY KEY(device_id,learner_id));
CREATE TABLE __ENV__.skill_nodes(id text PRIMARY KEY,skill text NOT NULL,prior double precision NOT NULL DEFAULT .3,transition double precision NOT NULL DEFAULT .1,guess double precision NOT NULL DEFAULT .2,slip double precision NOT NULL DEFAULT .1,CHECK(prior BETWEEN 0 AND 1 AND transition BETWEEN 0 AND 1 AND guess>0 AND guess<1 AND slip>0 AND slip<1));
-- A separate registry enforces global identity across monthly partitions.
CREATE TABLE __ENV__.event_ids(id text PRIMARY KEY,device_id text NOT NULL,seq bigint NOT NULL,learner_id text NOT NULL REFERENCES __ENV__.learners(id) ON DELETE CASCADE,fingerprint bytea NOT NULL,UNIQUE(device_id,seq));
CREATE TABLE __ENV__.events(id text NOT NULL,learner_id text NOT NULL REFERENCES __ENV__.learners(id) ON DELETE CASCADE,device_id text NOT NULL,seq bigint NOT NULL CHECK(seq>0),hlc text NOT NULL,type text NOT NULL,v integer NOT NULL CHECK(v=1),payload jsonb NOT NULL,received_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(id,received_at)) PARTITION BY RANGE(received_at);
CREATE INDEX ON __ENV__.events(learner_id,hlc,id);
CREATE INDEX ON __ENV__.events(device_id,seq);
CREATE TABLE __ENV__.learner_node_state(learner_id text REFERENCES __ENV__.learners(id) ON DELETE CASCADE,node_id text REFERENCES __ENV__.skill_nodes(id),p_learned double precision NOT NULL CHECK(p_learned BETWEEN 0 AND 1),n_obs integer NOT NULL,last_hlc text NOT NULL,PRIMARY KEY(learner_id,node_id));
CREATE TABLE __ENV__.learner_daily(learner_id text REFERENCES __ENV__.learners(id) ON DELETE CASCADE,day date NOT NULL,attempts integer NOT NULL DEFAULT 0,sessions integer NOT NULL DEFAULT 0,minutes double precision NOT NULL DEFAULT 0,PRIMARY KEY(learner_id,day));
CREATE TABLE __ENV__.class_snapshot(class_id uuid REFERENCES __ENV__.classes(id) ON DELETE CASCADE,day date NOT NULL,body jsonb NOT NULL,PRIMARY KEY(class_id,day));
CREATE TABLE __ENV__.insights(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES __ENV__.learners(id) ON DELETE CASCADE,node_id text NOT NULL REFERENCES __ENV__.skill_nodes(id),claim text NOT NULL,evidence_ids text[] NOT NULL,status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','approved','rejected')),reviewed_by uuid REFERENCES __ENV__.teachers(id),created_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX ON __ENV__.insights(learner_id,node_id) WHERE status='open';
CREATE TABLE __ENV__.interventions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES __ENV__.learners(id) ON DELETE CASCADE,class_id uuid NOT NULL REFERENCES __ENV__.classes(id) ON DELETE CASCADE,teacher_id uuid NOT NULL REFERENCES __ENV__.teachers(id),node_id text NOT NULL REFERENCES __ENV__.skill_nodes(id),kind text NOT NULL CHECK(kind IN ('approve','reject','assign','replace','pin','unpin','note')),payload jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE __ENV__.content_packs(id text PRIMARY KEY,manifest jsonb NOT NULL,channel text NOT NULL CHECK(channel IN ('internal','pilot','production')),enabled boolean NOT NULL DEFAULT false);
CREATE TABLE __ENV__.model_packs(LIKE __ENV__.content_packs INCLUDING ALL);
CREATE TABLE __ENV__.erasure_tombstones(learner_id text PRIMARY KEY,erased_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE __ENV__.erasure_targets(learner_id text REFERENCES __ENV__.erasure_tombstones(learner_id),user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,acknowledged_at timestamptz,PRIMARY KEY(learner_id,user_id));
CREATE TABLE __ENV__.audit_log(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,actor uuid,action text NOT NULL,target_hash text NOT NULL,at timestamptz NOT NULL DEFAULT now());

CREATE FUNCTION __ENV__.teacher_has_class(target uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM __ENV__.teacher_assignments a WHERE a.class_id=target AND a.teacher_id=auth.uid() AND a.from_at<=now() AND (a.to_at IS NULL OR a.to_at>now()))
$$;
CREATE FUNCTION __ENV__.can_read_learner(target text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM __ENV__.enrollments e WHERE e.learner_id=target AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now()) AND __ENV__.teacher_has_class(e.class_id))
 OR EXISTS(SELECT 1 FROM __ENV__.device_learners dl JOIN __ENV__.devices d ON d.id=dl.device_id WHERE dl.learner_id=target AND d.user_id=auth.uid() AND d.revoked_at IS NULL)
$$;
CREATE FUNCTION __ENV__.owns_learner(target text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM __ENV__.device_learners dl JOIN __ENV__.devices d ON d.id=dl.device_id WHERE dl.learner_id=target AND d.user_id=auth.uid() AND d.revoked_at IS NULL)
$$;
CREATE FUNCTION __ENV__.has_consent(target text,wanted text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM __ENV__.consents c JOIN __ENV__.learners l ON l.id=c.learner_id LEFT JOIN __ENV__.guardians g ON g.id=c.guardian_id
 WHERE c.learner_id=target AND c.purpose=wanted AND c.revoked_at IS NULL AND c.granted_at<=now()
 AND (NOT l.minor OR (g.learner_id=l.id AND c.verified_via IN ('otp','teacherWitnessedPaper'))))
$$;
CREATE FUNCTION __ENV__.ensure_month(month_start date) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE start_at date:=date_trunc('month',month_start)::date; table_name text;
BEGIN
 table_name:='events_'||to_char(start_at,'YYYYMM');
 EXECUTE format('CREATE TABLE IF NOT EXISTS __ENV__.%I PARTITION OF __ENV__.events FOR VALUES FROM (%L) TO (%L)',table_name,start_at,(start_at+interval '1 month')::date);
 EXECUTE format('ALTER TABLE __ENV__.%I ENABLE ROW LEVEL SECURITY',table_name);
END $$;
SELECT __ENV__.ensure_month(current_date);
SELECT __ENV__.ensure_month((current_date+interval '1 month')::date);
SELECT __ENV__.ensure_month((current_date-interval '1 month')::date);

CREATE FUNCTION __ENV__.fold_learner(target text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e record;p record;old double precision;post double precision;s double precision;
BEGIN
 DELETE FROM __ENV__.learner_node_state WHERE learner_id=target;
 DELETE FROM __ENV__.learner_daily WHERE learner_id=target;
 FOR e IN SELECT * FROM __ENV__.events WHERE learner_id=target ORDER BY hlc,id LOOP
  IF e.type IN ('PracticeAttempt','AssessmentItemAnswered') THEN
   SELECT * INTO STRICT p FROM __ENV__.skill_nodes WHERE id=e.payload->>'nodeId';
   SELECT p_learned INTO old FROM __ENV__.learner_node_state WHERE learner_id=target AND node_id=p.id;
   old:=coalesce(old,p.prior);s:=(e.payload->>'score')::double precision;
   post:=s*(old*(1-p.slip)/(old*(1-p.slip)+(1-old)*p.guess))+(1-s)*(old*p.slip/(old*p.slip+(1-old)*(1-p.guess)));
   INSERT INTO __ENV__.learner_node_state VALUES(target,p.id,post+(1-post)*p.transition,1,e.hlc)
    ON CONFLICT(learner_id,node_id) DO UPDATE SET p_learned=excluded.p_learned,n_obs=__ENV__.learner_node_state.n_obs+1,last_hlc=excluded.last_hlc;
   INSERT INTO __ENV__.learner_daily(learner_id,day,attempts) VALUES(target,to_timestamp(split_part(e.hlc,':',1)::bigint/1000.0)::date,1)
    ON CONFLICT(learner_id,day) DO UPDATE SET attempts=__ENV__.learner_daily.attempts+1;
  ELSIF e.type='SessionEnded' THEN
   INSERT INTO __ENV__.learner_daily(learner_id,day,sessions,minutes) VALUES(target,to_timestamp(split_part(e.hlc,':',1)::bigint/1000.0)::date,1,least(120,greatest(0,coalesce((e.payload->>'durationMs')::double precision,0)/60000)))
    ON CONFLICT(learner_id,day) DO UPDATE SET sessions=__ENV__.learner_daily.sessions+1,minutes=__ENV__.learner_daily.minutes+excluded.minutes;
  END IF;
 END LOOP;
END $$;

CREATE FUNCTION __ENV__.erase_learner(target_learner text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT __ENV__.owns_learner(target_learner) AND coalesce(auth.jwt()->>'role','')<>'service_role' THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(target_learner,0));
 INSERT INTO __ENV__.erasure_tombstones(learner_id) VALUES(target_learner) ON CONFLICT DO NOTHING;
 INSERT INTO __ENV__.erasure_targets(learner_id,user_id) SELECT target_learner,d.user_id FROM __ENV__.device_learners dl JOIN __ENV__.devices d ON d.id=dl.device_id WHERE dl.learner_id=target_learner ON CONFLICT DO NOTHING;
 -- Remove aggregates for every affected class before deleting enrolments.
 DELETE FROM __ENV__.class_snapshot WHERE class_id IN(SELECT class_id FROM __ENV__.enrollments WHERE learner_id=target_learner);
 DELETE FROM __ENV__.learners WHERE id=target_learner;
 INSERT INTO __ENV__.audit_log(actor,action,target_hash) VALUES(auth.uid(),'erase',encode(extensions.digest(target_learner,'sha256'),'hex'));
END $$;
CREATE FUNCTION __ENV__.prevent_resurrection() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF EXISTS(SELECT 1 FROM __ENV__.erasure_tombstones WHERE learner_id=NEW.id) THEN RAISE EXCEPTION 'Learner has been erased';END IF;RETURN NEW;END $$;
CREATE TRIGGER no_resurrection BEFORE INSERT ON __ENV__.learners FOR EACH ROW EXECUTE FUNCTION __ENV__.prevent_resurrection();

CREATE FUNCTION __ENV__.ingest_events(batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb; bound text; existing __ENV__.event_ids; fingerprint bytea; learner text; seen text[]:='{}';accepted text[]:='{}';n integer;event_type text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR octet_length(batch::text)>4194304 THEN RAISE EXCEPTION 'Invalid batch';END IF;
 SELECT id INTO bound FROM __ENV__.devices WHERE user_id=auth.uid() AND revoked_at IS NULL;
 IF bound IS NULL THEN RAISE EXCEPTION 'Unbound device' USING ERRCODE='42501';END IF;
 FOR e IN SELECT value FROM jsonb_array_elements(batch) LOOP
  IF jsonb_typeof(e)<>'object' OR NOT(e ?& ARRAY['id','learnerId','deviceId','seq','hlc','type','v','payload']) OR (SELECT count(*) FROM jsonb_object_keys(e))<>8 THEN RAISE EXCEPTION 'Invalid event envelope';END IF;
  learner:=e->>'learnerId';event_type:=e->>'type';
  IF jsonb_typeof(e->'seq')<>'number' OR jsonb_typeof(e->'v')<>'number' OR e->>'deviceId'<>bound OR e->>'id' !~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$' OR e->>'seq' !~ '^[1-9][0-9]{0,15}$' OR e->>'v'<>'1'
   OR e->>'hlc' !~ '^[0-9]{13}:[0-9]{6}:[A-Za-z0-9_-]{1,80}$' OR split_part(e->>'hlc',':',3)<>bound
   OR split_part(e->>'hlc',':',1)::bigint>extract(epoch FROM now())*1000+86400000 OR jsonb_typeof(e->'payload')<>'object' OR octet_length((e->'payload')::text)>32768
   OR jsonb_path_exists(e->'payload','$.** ? (@.type() == "object").keyvalue() ? (@.key like_regex "^(audio|pcm|samples|rawAudio|recording|transcript)$" flag "i")') THEN RAISE EXCEPTION 'Invalid event';END IF;
  IF event_type NOT IN ('ProfileCreated','ProfileUpdated','ConsentGranted','ConsentRevoked','AssessmentStarted','AssessmentItemAnswered','AssessmentCompleted','PracticeAttempt','ReadingAttemptScored','ReadingAttemptUnscored','WordFlagged','WordRepeated','WordCleared','SentenceSubmitted','CorrectionShown','RuleExplained','SessionStarted','SessionEnded','PathRebuilt','InterventionApplied','LearnerErased') THEN RAISE EXCEPTION 'Unsupported event type';END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(learner,0));
  IF EXISTS(SELECT 1 FROM __ENV__.erasure_targets WHERE learner_id=learner AND user_id=auth.uid()) THEN accepted:=array_append(accepted,e->>'id');CONTINUE;END IF;
  IF NOT __ENV__.owns_learner(learner) THEN RAISE EXCEPTION 'Learner not bound to device' USING ERRCODE='42501';END IF;
  IF event_type='LearnerErased' THEN PERFORM __ENV__.erase_learner(learner);accepted:=array_append(accepted,e->>'id');CONTINUE;END IF;
  IF event_type='ConsentRevoked' THEN
   IF e->'payload'->>'purpose' NOT IN ('core','microphone','clipRetention','serverSync','telemetry') OR NOT(e->'payload' ? 'purpose') THEN RAISE EXCEPTION 'Invalid consent purpose';END IF;
   IF e->'payload'->>'purpose'='core' THEN PERFORM __ENV__.erase_learner(learner);
   ELSE
    UPDATE __ENV__.consents SET revoked_at=now() WHERE learner_id=learner AND purpose=e->'payload'->>'purpose' AND revoked_at IS NULL;
    INSERT INTO __ENV__.audit_log(actor,action,target_hash) VALUES(auth.uid(),'revoke:'||(e->'payload'->>'purpose'),encode(extensions.digest(learner,'sha256'),'hex'));
   END IF;
   accepted:=array_append(accepted,e->>'id');CONTINUE;
  END IF;
  IF NOT __ENV__.has_consent(learner,'core') OR NOT __ENV__.has_consent(learner,'serverSync') THEN RAISE EXCEPTION 'Sync consent missing' USING ERRCODE='42501';END IF;
  IF event_type IN ('PracticeAttempt','AssessmentItemAnswered') THEN
   IF jsonb_typeof(e->'payload'->'score')<>'number' OR (e->'payload'->>'score')::numeric NOT BETWEEN 0 AND 1 OR NOT(e->'payload' ?& ARRAY['score','itemId','nodeId']) OR NOT EXISTS(SELECT 1 FROM __ENV__.skill_nodes WHERE id=e->'payload'->>'nodeId') THEN RAISE EXCEPTION 'Invalid observation';END IF;
  END IF;
  fingerprint:=extensions.digest(e::text,'sha256');
  SELECT * INTO existing FROM __ENV__.event_ids WHERE id=e->>'id' OR (device_id=bound AND seq=(e->>'seq')::bigint) LIMIT 1;
  IF FOUND THEN
   IF existing.id<>e->>'id' OR existing.fingerprint<>fingerprint THEN RAISE EXCEPTION 'Conflicting event identity';END IF;
  ELSE
   INSERT INTO __ENV__.event_ids VALUES(e->>'id',bound,(e->>'seq')::bigint,learner,fingerprint);
   INSERT INTO __ENV__.events(id,learner_id,device_id,seq,hlc,type,v,payload) VALUES(e->>'id',learner,bound,(e->>'seq')::bigint,e->>'hlc',event_type,1,e->'payload');
   seen:=array_append(seen,learner);
  END IF;
  accepted:=array_append(accepted,e->>'id');
 END LOOP;
 FOR learner IN SELECT DISTINCT unnest(seen) LOOP PERFORM __ENV__.fold_learner(learner);END LOOP;
 UPDATE __ENV__.devices SET last_seen_at=now() WHERE id=bound;
 RETURN jsonb_build_object('acceptedIds',to_jsonb(accepted));
END $$;

CREATE FUNCTION __ENV__.teacher_intervene(target_learner text,target_class uuid,target_node text,action_kind text,insight_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT __ENV__.teacher_has_class(target_class) OR NOT EXISTS(SELECT 1 FROM __ENV__.enrollments WHERE learner_id=target_learner AND class_id=target_class AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF action_kind NOT IN ('approve','reject','assign','pin','unpin') THEN RAISE EXCEPTION 'Invalid intervention';END IF;
 INSERT INTO __ENV__.interventions(learner_id,class_id,teacher_id,node_id,kind) VALUES(target_learner,target_class,auth.uid(),target_node,action_kind) RETURNING id INTO result;
 IF insight_id IS NOT NULL THEN
  UPDATE __ENV__.insights SET status=CASE WHEN action_kind='reject' THEN 'rejected' ELSE 'approved' END,reviewed_by=auth.uid() WHERE id=insight_id AND learner_id=target_learner AND node_id=target_node AND status='open';
  IF NOT FOUND THEN RAISE EXCEPTION 'Insight does not match learner';END IF;
 END IF;
 INSERT INTO __ENV__.audit_log(actor,action,target_hash) VALUES(auth.uid(),'intervention:'||action_kind,encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN result;
END $$;
CREATE FUNCTION __ENV__.export_learner(target_learner text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT __ENV__.owns_learner(target_learner) AND coalesce(auth.jwt()->>'role','')<>'service_role' THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';END IF;
 INSERT INTO __ENV__.audit_log(actor,action,target_hash) VALUES(auth.uid(),'export',encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN jsonb_build_object('learner',(SELECT to_jsonb(l) FROM __ENV__.learners l WHERE id=target_learner),'events',coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY hlc,id) FROM __ENV__.events e WHERE learner_id=target_learner),'[]'::jsonb));
END $$;
CREATE FUNCTION __ENV__.build_insights() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 INSERT INTO __ENV__.insights(learner_id,node_id,claim,evidence_ids)
 SELECT learner_id,node_id,format('%s of the last %s attempts on %s scored below 50%%.',count(*) FILTER(WHERE score<.5),count(*),node_id),array_agg(id ORDER BY hlc,id)
 FROM(SELECT learner_id,payload->>'nodeId' node_id,id,hlc,(payload->>'score')::double precision score,row_number() OVER(PARTITION BY learner_id,payload->>'nodeId' ORDER BY hlc DESC,id DESC) rn FROM __ENV__.events WHERE type IN ('PracticeAttempt','AssessmentItemAnswered')) recent
 WHERE rn<=14 GROUP BY learner_id,node_id HAVING count(*)>=6 AND count(*) FILTER(WHERE score<.5)::double precision/count(*)>=.6
 ON CONFLICT(learner_id,node_id) WHERE status='open' DO NOTHING;
END $$;
CREATE FUNCTION __ENV__.refresh_class_snapshots() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 INSERT INTO __ENV__.class_snapshot(class_id,day,body)
 SELECT c.id,current_date,jsonb_build_object('activeLearners',count(DISTINCT e.learner_id),'observations',coalesce(sum(s.n_obs),0),'meanMastery',avg(s.p_learned))
 FROM __ENV__.classes c LEFT JOIN __ENV__.enrollments e ON e.class_id=c.id AND e.status='active' LEFT JOIN __ENV__.learner_node_state s ON s.learner_id=e.learner_id GROUP BY c.id
 ON CONFLICT(class_id,day) DO UPDATE SET body=excluded.body
$$;

-- Every application table is default-deny. RPCs are the only mutation surface.
DO $$ DECLARE r record;BEGIN FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='__ENV__' LOOP EXECUTE format('ALTER TABLE __ENV__.%I ENABLE ROW LEVEL SECURITY',r.tablename);END LOOP;END $$;
CREATE POLICY teacher_self ON __ENV__.teachers FOR SELECT TO authenticated USING(id=auth.uid());
CREATE POLICY assigned_classes ON __ENV__.classes FOR SELECT TO authenticated USING(__ENV__.teacher_has_class(id));
CREATE POLICY own_assignments ON __ENV__.teacher_assignments FOR SELECT TO authenticated USING(teacher_id=auth.uid());
CREATE POLICY assigned_enrollments ON __ENV__.enrollments FOR SELECT TO authenticated USING(__ENV__.teacher_has_class(class_id) OR __ENV__.owns_learner(learner_id));
CREATE POLICY assigned_learners ON __ENV__.learners FOR SELECT TO authenticated USING(__ENV__.can_read_learner(id));
CREATE POLICY own_devices ON __ENV__.devices FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY own_bindings ON __ENV__.device_learners FOR SELECT TO authenticated USING(__ENV__.owns_learner(learner_id));
CREATE POLICY learner_events ON __ENV__.events FOR SELECT TO authenticated USING(__ENV__.can_read_learner(learner_id));
CREATE POLICY learner_mastery ON __ENV__.learner_node_state FOR SELECT TO authenticated USING(__ENV__.can_read_learner(learner_id));
CREATE POLICY learner_daily ON __ENV__.learner_daily FOR SELECT TO authenticated USING(__ENV__.can_read_learner(learner_id));
CREATE POLICY class_summary ON __ENV__.class_snapshot FOR SELECT TO authenticated USING(__ENV__.teacher_has_class(class_id));
CREATE POLICY learner_insights ON __ENV__.insights FOR SELECT TO authenticated USING(__ENV__.can_read_learner(learner_id));
CREATE POLICY learner_interventions ON __ENV__.interventions FOR SELECT TO authenticated USING(__ENV__.can_read_learner(learner_id));
CREATE POLICY own_consents ON __ENV__.consents FOR SELECT TO authenticated USING(__ENV__.owns_learner(learner_id));
CREATE POLICY erasure_delivery ON __ENV__.erasure_targets FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY content_published ON __ENV__.content_packs FOR SELECT TO authenticated USING(enabled AND channel='production');
CREATE POLICY model_published ON __ENV__.model_packs FOR SELECT TO authenticated USING(enabled AND channel='production');
CREATE POLICY skill_catalog ON __ENV__.skill_nodes FOR SELECT TO authenticated USING(true);
REVOKE ALL ON ALL TABLES IN SCHEMA __ENV__ FROM anon,authenticated;
GRANT SELECT ON __ENV__.teachers,__ENV__.classes,__ENV__.teacher_assignments,__ENV__.enrollments,__ENV__.learners,__ENV__.devices,__ENV__.device_learners,__ENV__.events,__ENV__.learner_node_state,__ENV__.learner_daily,__ENV__.class_snapshot,__ENV__.insights,__ENV__.interventions,__ENV__.consents,__ENV__.erasure_targets,__ENV__.content_packs,__ENV__.model_packs,__ENV__.skill_nodes TO authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA __ENV__ FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION __ENV__.teacher_has_class(uuid),__ENV__.can_read_learner(text),__ENV__.owns_learner(text),__ENV__.ingest_events(jsonb),__ENV__.erase_learner(text),__ENV__.export_learner(text),__ENV__.teacher_intervene(text,uuid,text,text,uuid) TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA __ENV__ TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA __ENV__ TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA __ENV__ TO service_role;
