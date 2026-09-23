CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE SCHEMA IF NOT EXISTS dev;
REVOKE ALL ON SCHEMA dev FROM PUBLIC;
GRANT USAGE ON SCHEMA dev TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA dev REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE dev.orgs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text NOT NULL,region text NOT NULL DEFAULT 'IN');
CREATE TABLE dev.teachers(id uuid PRIMARY KEY REFERENCES auth.users(id),org_id uuid NOT NULL REFERENCES dev.orgs(id),display_name text NOT NULL);
CREATE TABLE dev.classes(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),org_id uuid NOT NULL REFERENCES dev.orgs(id),name text NOT NULL,code_hash text UNIQUE,code_expires_at timestamptz);
CREATE TABLE dev.teacher_assignments(class_id uuid REFERENCES dev.classes(id) ON DELETE CASCADE,teacher_id uuid REFERENCES dev.teachers(id) ON DELETE CASCADE,from_at timestamptz NOT NULL DEFAULT now(),to_at timestamptz,PRIMARY KEY(class_id,teacher_id),CHECK(to_at IS NULL OR to_at>from_at));
CREATE TABLE dev.learners(id text PRIMARY KEY CHECK(id ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$'),org_id uuid NOT NULL REFERENCES dev.orgs(id),display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 60),age_band text NOT NULL CHECK(age_band IN ('child','student','adult')),minor boolean NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE dev.enrollments(class_id uuid REFERENCES dev.classes(id) ON DELETE CASCADE,learner_id text REFERENCES dev.learners(id) ON DELETE CASCADE,status text NOT NULL CHECK(status IN ('pending','active','left')),from_at timestamptz NOT NULL DEFAULT now(),to_at timestamptz,PRIMARY KEY(class_id,learner_id));
CREATE TABLE dev.guardians(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES dev.learners(id) ON DELETE CASCADE,contact_hash text NOT NULL,verified_via text NOT NULL CHECK(verified_via IN ('otp','teacherWitnessedPaper')),verification_reference text NOT NULL);
CREATE TABLE dev.consents(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES dev.learners(id) ON DELETE CASCADE,purpose text NOT NULL CHECK(purpose IN ('core','microphone','clipRetention','serverSync','telemetry')),guardian_id uuid REFERENCES dev.guardians(id) ON DELETE CASCADE,verified_via text NOT NULL CHECK(verified_via IN ('self','otp','teacherWitnessedPaper')),version integer NOT NULL CHECK(version>0),granted_at timestamptz NOT NULL DEFAULT now(),revoked_at timestamptz);
CREATE TABLE dev.devices(id text PRIMARY KEY,user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id),revoked_at timestamptz,last_seen_at timestamptz);
CREATE TABLE dev.device_learners(device_id text REFERENCES dev.devices(id) ON DELETE CASCADE,learner_id text REFERENCES dev.learners(id) ON DELETE CASCADE,PRIMARY KEY(device_id,learner_id));
CREATE TABLE dev.skill_nodes(id text PRIMARY KEY,skill text NOT NULL,prior double precision NOT NULL DEFAULT .3,transition double precision NOT NULL DEFAULT .1,guess double precision NOT NULL DEFAULT .2,slip double precision NOT NULL DEFAULT .1,CHECK(prior BETWEEN 0 AND 1 AND transition BETWEEN 0 AND 1 AND guess>0 AND guess<1 AND slip>0 AND slip<1));
-- A separate registry enforces global identity across monthly partitions.
CREATE TABLE dev.event_ids(id text PRIMARY KEY,device_id text NOT NULL,seq bigint NOT NULL,learner_id text NOT NULL REFERENCES dev.learners(id) ON DELETE CASCADE,fingerprint bytea NOT NULL,UNIQUE(device_id,seq));
CREATE TABLE dev.events(id text NOT NULL,learner_id text NOT NULL REFERENCES dev.learners(id) ON DELETE CASCADE,device_id text NOT NULL,seq bigint NOT NULL CHECK(seq>0),hlc text NOT NULL,type text NOT NULL,v integer NOT NULL CHECK(v=1),payload jsonb NOT NULL,received_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(id,received_at)) PARTITION BY RANGE(received_at);
CREATE INDEX ON dev.events(learner_id,hlc,id);
CREATE INDEX ON dev.events(device_id,seq);
CREATE TABLE dev.learner_node_state(learner_id text REFERENCES dev.learners(id) ON DELETE CASCADE,node_id text REFERENCES dev.skill_nodes(id),p_learned double precision NOT NULL CHECK(p_learned BETWEEN 0 AND 1),n_obs integer NOT NULL,last_hlc text NOT NULL,PRIMARY KEY(learner_id,node_id));
CREATE TABLE dev.learner_daily(learner_id text REFERENCES dev.learners(id) ON DELETE CASCADE,day date NOT NULL,attempts integer NOT NULL DEFAULT 0,sessions integer NOT NULL DEFAULT 0,minutes double precision NOT NULL DEFAULT 0,PRIMARY KEY(learner_id,day));
CREATE TABLE dev.class_snapshot(class_id uuid REFERENCES dev.classes(id) ON DELETE CASCADE,day date NOT NULL,body jsonb NOT NULL,PRIMARY KEY(class_id,day));
CREATE TABLE dev.insights(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES dev.learners(id) ON DELETE CASCADE,node_id text NOT NULL REFERENCES dev.skill_nodes(id),claim text NOT NULL,evidence_ids text[] NOT NULL,status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','approved','rejected')),reviewed_by uuid REFERENCES dev.teachers(id),created_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX ON dev.insights(learner_id,node_id) WHERE status='open';
CREATE TABLE dev.interventions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES dev.learners(id) ON DELETE CASCADE,class_id uuid NOT NULL REFERENCES dev.classes(id) ON DELETE CASCADE,teacher_id uuid NOT NULL REFERENCES dev.teachers(id),node_id text NOT NULL REFERENCES dev.skill_nodes(id),kind text NOT NULL CHECK(kind IN ('approve','reject','assign','replace','pin','unpin','note')),payload jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE dev.content_packs(id text PRIMARY KEY,manifest jsonb NOT NULL,channel text NOT NULL CHECK(channel IN ('internal','pilot','production')),enabled boolean NOT NULL DEFAULT false);
CREATE TABLE dev.model_packs(LIKE dev.content_packs INCLUDING ALL);
CREATE TABLE dev.erasure_tombstones(learner_id text PRIMARY KEY,erased_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE dev.erasure_targets(learner_id text REFERENCES dev.erasure_tombstones(learner_id),user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,acknowledged_at timestamptz,PRIMARY KEY(learner_id,user_id));
CREATE TABLE dev.audit_log(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,actor uuid,action text NOT NULL,target_hash text NOT NULL,at timestamptz NOT NULL DEFAULT now());

CREATE FUNCTION dev.teacher_has_class(target uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM dev.teacher_assignments a WHERE a.class_id=target AND a.teacher_id=auth.uid() AND a.from_at<=now() AND (a.to_at IS NULL OR a.to_at>now()))
$$;
CREATE FUNCTION dev.can_read_learner(target text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM dev.enrollments e WHERE e.learner_id=target AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now()) AND dev.teacher_has_class(e.class_id))
 OR EXISTS(SELECT 1 FROM dev.device_learners dl JOIN dev.devices d ON d.id=dl.device_id WHERE dl.learner_id=target AND d.user_id=auth.uid() AND d.revoked_at IS NULL)
$$;
CREATE FUNCTION dev.owns_learner(target text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM dev.device_learners dl JOIN dev.devices d ON d.id=dl.device_id WHERE dl.learner_id=target AND d.user_id=auth.uid() AND d.revoked_at IS NULL)
$$;
CREATE FUNCTION dev.has_consent(target text,wanted text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM dev.consents c JOIN dev.learners l ON l.id=c.learner_id LEFT JOIN dev.guardians g ON g.id=c.guardian_id
 WHERE c.learner_id=target AND c.purpose=wanted AND c.revoked_at IS NULL AND c.granted_at<=now()
 AND (NOT l.minor OR (g.learner_id=l.id AND c.verified_via IN ('otp','teacherWitnessedPaper'))))
$$;
CREATE FUNCTION dev.ensure_month(month_start date) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE start_at date:=date_trunc('month',month_start)::date; table_name text;
BEGIN
 table_name:='events_'||to_char(start_at,'YYYYMM');
 EXECUTE format('CREATE TABLE IF NOT EXISTS dev.%I PARTITION OF dev.events FOR VALUES FROM (%L) TO (%L)',table_name,start_at,(start_at+interval '1 month')::date);
 EXECUTE format('ALTER TABLE dev.%I ENABLE ROW LEVEL SECURITY',table_name);
END $$;
SELECT dev.ensure_month(current_date);
SELECT dev.ensure_month((current_date+interval '1 month')::date);
SELECT dev.ensure_month((current_date-interval '1 month')::date);

CREATE FUNCTION dev.fold_learner(target text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e record;p record;old double precision;post double precision;s double precision;
BEGIN
 DELETE FROM dev.learner_node_state WHERE learner_id=target;
 DELETE FROM dev.learner_daily WHERE learner_id=target;
 FOR e IN SELECT * FROM dev.events WHERE learner_id=target ORDER BY hlc,id LOOP
  IF e.type IN ('PracticeAttempt','AssessmentItemAnswered') THEN
   SELECT * INTO STRICT p FROM dev.skill_nodes WHERE id=e.payload->>'nodeId';
   SELECT p_learned INTO old FROM dev.learner_node_state WHERE learner_id=target AND node_id=p.id;
   old:=coalesce(old,p.prior);s:=(e.payload->>'score')::double precision;
   post:=s*(old*(1-p.slip)/(old*(1-p.slip)+(1-old)*p.guess))+(1-s)*(old*p.slip/(old*p.slip+(1-old)*(1-p.guess)));
   INSERT INTO dev.learner_node_state VALUES(target,p.id,post+(1-post)*p.transition,1,e.hlc)
    ON CONFLICT(learner_id,node_id) DO UPDATE SET p_learned=excluded.p_learned,n_obs=dev.learner_node_state.n_obs+1,last_hlc=excluded.last_hlc;
   INSERT INTO dev.learner_daily(learner_id,day,attempts) VALUES(target,to_timestamp(split_part(e.hlc,':',1)::bigint/1000.0)::date,1)
    ON CONFLICT(learner_id,day) DO UPDATE SET attempts=dev.learner_daily.attempts+1;
  ELSIF e.type='SessionEnded' THEN
   INSERT INTO dev.learner_daily(learner_id,day,sessions,minutes) VALUES(target,to_timestamp(split_part(e.hlc,':',1)::bigint/1000.0)::date,1,least(120,greatest(0,coalesce((e.payload->>'durationMs')::double precision,0)/60000)))
    ON CONFLICT(learner_id,day) DO UPDATE SET sessions=dev.learner_daily.sessions+1,minutes=dev.learner_daily.minutes+excluded.minutes;
  END IF;
 END LOOP;
END $$;

CREATE FUNCTION dev.erase_learner(target_learner text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT dev.owns_learner(target_learner) AND coalesce(auth.jwt()->>'role','')<>'service_role' THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(target_learner,0));
 INSERT INTO dev.erasure_tombstones(learner_id) VALUES(target_learner) ON CONFLICT DO NOTHING;
 INSERT INTO dev.erasure_targets(learner_id,user_id) SELECT target_learner,d.user_id FROM dev.device_learners dl JOIN dev.devices d ON d.id=dl.device_id WHERE dl.learner_id=target_learner ON CONFLICT DO NOTHING;
 -- Remove aggregates for every affected class before deleting enrolments.
 DELETE FROM dev.class_snapshot WHERE class_id IN(SELECT class_id FROM dev.enrollments WHERE learner_id=target_learner);
 DELETE FROM dev.learners WHERE id=target_learner;
 INSERT INTO dev.audit_log(actor,action,target_hash) VALUES(auth.uid(),'erase',encode(extensions.digest(target_learner,'sha256'),'hex'));
END $$;
CREATE FUNCTION dev.prevent_resurrection() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF EXISTS(SELECT 1 FROM dev.erasure_tombstones WHERE learner_id=NEW.id) THEN RAISE EXCEPTION 'Learner has been erased';END IF;RETURN NEW;END $$;
CREATE TRIGGER no_resurrection BEFORE INSERT ON dev.learners FOR EACH ROW EXECUTE FUNCTION dev.prevent_resurrection();

CREATE FUNCTION dev.ingest_events(batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb; bound text; existing dev.event_ids; fingerprint bytea; learner text; seen text[]:='{}';accepted text[]:='{}';n integer;event_type text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR octet_length(batch::text)>4194304 THEN RAISE EXCEPTION 'Invalid batch';END IF;
 SELECT id INTO bound FROM dev.devices WHERE user_id=auth.uid() AND revoked_at IS NULL;
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
  IF EXISTS(SELECT 1 FROM dev.erasure_targets WHERE learner_id=learner AND user_id=auth.uid()) THEN accepted:=array_append(accepted,e->>'id');CONTINUE;END IF;
  IF NOT dev.owns_learner(learner) THEN RAISE EXCEPTION 'Learner not bound to device' USING ERRCODE='42501';END IF;
  IF event_type='LearnerErased' THEN PERFORM dev.erase_learner(learner);accepted:=array_append(accepted,e->>'id');CONTINUE;END IF;
  IF event_type='ConsentRevoked' THEN
   IF e->'payload'->>'purpose' NOT IN ('core','microphone','clipRetention','serverSync','telemetry') OR NOT(e->'payload' ? 'purpose') THEN RAISE EXCEPTION 'Invalid consent purpose';END IF;
   IF e->'payload'->>'purpose'='core' THEN PERFORM dev.erase_learner(learner);
   ELSE
    UPDATE dev.consents SET revoked_at=now() WHERE learner_id=learner AND purpose=e->'payload'->>'purpose' AND revoked_at IS NULL;
    INSERT INTO dev.audit_log(actor,action,target_hash) VALUES(auth.uid(),'revoke:'||(e->'payload'->>'purpose'),encode(extensions.digest(learner,'sha256'),'hex'));
   END IF;
   accepted:=array_append(accepted,e->>'id');CONTINUE;
  END IF;
  IF NOT dev.has_consent(learner,'core') OR NOT dev.has_consent(learner,'serverSync') THEN RAISE EXCEPTION 'Sync consent missing' USING ERRCODE='42501';END IF;
  IF event_type IN ('PracticeAttempt','AssessmentItemAnswered') THEN
   IF jsonb_typeof(e->'payload'->'score')<>'number' OR (e->'payload'->>'score')::numeric NOT BETWEEN 0 AND 1 OR NOT(e->'payload' ?& ARRAY['score','itemId','nodeId']) OR NOT EXISTS(SELECT 1 FROM dev.skill_nodes WHERE id=e->'payload'->>'nodeId') THEN RAISE EXCEPTION 'Invalid observation';END IF;
  END IF;
  fingerprint:=extensions.digest(e::text,'sha256');
  SELECT * INTO existing FROM dev.event_ids WHERE id=e->>'id' OR (device_id=bound AND seq=(e->>'seq')::bigint) LIMIT 1;
  IF FOUND THEN
   IF existing.id<>e->>'id' OR existing.fingerprint<>fingerprint THEN RAISE EXCEPTION 'Conflicting event identity';END IF;
  ELSE
   INSERT INTO dev.event_ids VALUES(e->>'id',bound,(e->>'seq')::bigint,learner,fingerprint);
   INSERT INTO dev.events(id,learner_id,device_id,seq,hlc,type,v,payload) VALUES(e->>'id',learner,bound,(e->>'seq')::bigint,e->>'hlc',event_type,1,e->'payload');
   seen:=array_append(seen,learner);
  END IF;
  accepted:=array_append(accepted,e->>'id');
 END LOOP;
 FOR learner IN SELECT DISTINCT unnest(seen) LOOP PERFORM dev.fold_learner(learner);END LOOP;
 UPDATE dev.devices SET last_seen_at=now() WHERE id=bound;
 RETURN jsonb_build_object('acceptedIds',to_jsonb(accepted));
END $$;

CREATE FUNCTION dev.teacher_intervene(target_learner text,target_class uuid,target_node text,action_kind text,insight_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT dev.teacher_has_class(target_class) OR NOT EXISTS(SELECT 1 FROM dev.enrollments WHERE learner_id=target_learner AND class_id=target_class AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF action_kind NOT IN ('approve','reject','assign','pin','unpin') THEN RAISE EXCEPTION 'Invalid intervention';END IF;
 INSERT INTO dev.interventions(learner_id,class_id,teacher_id,node_id,kind) VALUES(target_learner,target_class,auth.uid(),target_node,action_kind) RETURNING id INTO result;
 IF insight_id IS NOT NULL THEN
  UPDATE dev.insights SET status=CASE WHEN action_kind='reject' THEN 'rejected' ELSE 'approved' END,reviewed_by=auth.uid() WHERE id=insight_id AND learner_id=target_learner AND node_id=target_node AND status='open';
  IF NOT FOUND THEN RAISE EXCEPTION 'Insight does not match learner';END IF;
 END IF;
 INSERT INTO dev.audit_log(actor,action,target_hash) VALUES(auth.uid(),'intervention:'||action_kind,encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN result;
END $$;
CREATE FUNCTION dev.export_learner(target_learner text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT dev.owns_learner(target_learner) AND coalesce(auth.jwt()->>'role','')<>'service_role' THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';END IF;
 INSERT INTO dev.audit_log(actor,action,target_hash) VALUES(auth.uid(),'export',encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN jsonb_build_object('learner',(SELECT to_jsonb(l) FROM dev.learners l WHERE id=target_learner),'events',coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY hlc,id) FROM dev.events e WHERE learner_id=target_learner),'[]'::jsonb));
END $$;
CREATE FUNCTION dev.build_insights() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 INSERT INTO dev.insights(learner_id,node_id,claim,evidence_ids)
 SELECT learner_id,node_id,format('%s of the last %s attempts on %s scored below 50%%.',count(*) FILTER(WHERE score<.5),count(*),node_id),array_agg(id ORDER BY hlc,id)
 FROM(SELECT learner_id,payload->>'nodeId' node_id,id,hlc,(payload->>'score')::double precision score,row_number() OVER(PARTITION BY learner_id,payload->>'nodeId' ORDER BY hlc DESC,id DESC) rn FROM dev.events WHERE type IN ('PracticeAttempt','AssessmentItemAnswered')) recent
 WHERE rn<=14 GROUP BY learner_id,node_id HAVING count(*)>=6 AND count(*) FILTER(WHERE score<.5)::double precision/count(*)>=.6
 ON CONFLICT(learner_id,node_id) WHERE status='open' DO NOTHING;
END $$;
CREATE FUNCTION dev.refresh_class_snapshots() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 INSERT INTO dev.class_snapshot(class_id,day,body)
 SELECT c.id,current_date,jsonb_build_object('activeLearners',count(DISTINCT e.learner_id),'observations',coalesce(sum(s.n_obs),0),'meanMastery',avg(s.p_learned))
 FROM dev.classes c LEFT JOIN dev.enrollments e ON e.class_id=c.id AND e.status='active' LEFT JOIN dev.learner_node_state s ON s.learner_id=e.learner_id GROUP BY c.id
 ON CONFLICT(class_id,day) DO UPDATE SET body=excluded.body
$$;

-- Every application table is default-deny. RPCs are the only mutation surface.
DO $$ DECLARE r record;BEGIN FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='dev' LOOP EXECUTE format('ALTER TABLE dev.%I ENABLE ROW LEVEL SECURITY',r.tablename);END LOOP;END $$;
CREATE POLICY teacher_self ON dev.teachers FOR SELECT TO authenticated USING(id=auth.uid());
CREATE POLICY assigned_classes ON dev.classes FOR SELECT TO authenticated USING(dev.teacher_has_class(id));
CREATE POLICY own_assignments ON dev.teacher_assignments FOR SELECT TO authenticated USING(teacher_id=auth.uid());
CREATE POLICY assigned_enrollments ON dev.enrollments FOR SELECT TO authenticated USING(dev.teacher_has_class(class_id) OR dev.owns_learner(learner_id));
CREATE POLICY assigned_learners ON dev.learners FOR SELECT TO authenticated USING(dev.can_read_learner(id));
CREATE POLICY own_devices ON dev.devices FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY own_bindings ON dev.device_learners FOR SELECT TO authenticated USING(dev.owns_learner(learner_id));
CREATE POLICY learner_events ON dev.events FOR SELECT TO authenticated USING(dev.can_read_learner(learner_id));
CREATE POLICY learner_mastery ON dev.learner_node_state FOR SELECT TO authenticated USING(dev.can_read_learner(learner_id));
CREATE POLICY learner_daily ON dev.learner_daily FOR SELECT TO authenticated USING(dev.can_read_learner(learner_id));
CREATE POLICY class_summary ON dev.class_snapshot FOR SELECT TO authenticated USING(dev.teacher_has_class(class_id));
CREATE POLICY learner_insights ON dev.insights FOR SELECT TO authenticated USING(dev.can_read_learner(learner_id));
CREATE POLICY learner_interventions ON dev.interventions FOR SELECT TO authenticated USING(dev.can_read_learner(learner_id));
CREATE POLICY own_consents ON dev.consents FOR SELECT TO authenticated USING(dev.owns_learner(learner_id));
CREATE POLICY erasure_delivery ON dev.erasure_targets FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY content_published ON dev.content_packs FOR SELECT TO authenticated USING(enabled AND channel='production');
CREATE POLICY model_published ON dev.model_packs FOR SELECT TO authenticated USING(enabled AND channel='production');
CREATE POLICY skill_catalog ON dev.skill_nodes FOR SELECT TO authenticated USING(true);
REVOKE ALL ON ALL TABLES IN SCHEMA dev FROM anon,authenticated;
GRANT SELECT ON dev.teachers,dev.classes,dev.teacher_assignments,dev.enrollments,dev.learners,dev.devices,dev.device_learners,dev.events,dev.learner_node_state,dev.learner_daily,dev.class_snapshot,dev.insights,dev.interventions,dev.consents,dev.erasure_targets,dev.content_packs,dev.model_packs,dev.skill_nodes TO authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA dev FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION dev.teacher_has_class(uuid),dev.can_read_learner(text),dev.owns_learner(text),dev.ingest_events(jsonb),dev.erase_learner(text),dev.export_learner(text),dev.teacher_intervene(text,uuid,text,text,uuid) TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA dev TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA dev TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA dev TO service_role;

INSERT INTO dev.skill_nodes(id,skill) VALUES
('vocabulary.frequent_500','vocabulary'),
('vocabulary.people','vocabulary'),
('vocabulary.places','vocabulary'),
('vocabulary.actions','vocabulary'),
('vocabulary.describing','vocabulary'),
('vocabulary.time','vocabulary'),
('vocabulary.context','vocabulary'),
('vocabulary.collocations','vocabulary'),
('vocabulary.word_families','vocabulary'),
('vocabulary.academic','vocabulary'),
('grammar.simple_present_agreement','grammar'),
('grammar.articles','grammar'),
('grammar.pronouns','grammar'),
('grammar.plurals','grammar'),
('grammar.prepositions','grammar'),
('grammar.regular_past','grammar'),
('grammar.irregular_past','grammar'),
('grammar.progressive','grammar'),
('grammar.modals','grammar'),
('grammar.complex','grammar'),
('sentence.simple','sentence'),
('sentence.questions','sentence'),
('sentence.negatives','sentence'),
('sentence.descriptions','sentence'),
('sentence.past_narration','sentence'),
('sentence.future','sentence'),
('sentence.joining','sentence'),
('sentence.ordering','sentence'),
('sentence.paragraphs','sentence'),
('sentence.arguments','sentence'),
('reading.letters','reading'),
('reading.words','reading'),
('reading.phrases','reading'),
('reading.a1','reading'),
('reading.a2','reading'),
('reading.punctuation','reading'),
('reading.detail','reading'),
('reading.inference','reading'),
('reading.b1','reading'),
('reading.b2','reading'),
('pronunciation.v_w','pronunciation'),
('pronunciation.th','pronunciation'),
('pronunciation.vowels','pronunciation'),
('pronunciation.final_consonants','pronunciation'),
('pronunciation.clusters','pronunciation'),
('pronunciation.syllables','pronunciation'),
('pronunciation.word_stress','pronunciation'),
('pronunciation.sentence_stress','pronunciation'),
('pronunciation.linking','pronunciation'),
('pronunciation.intonation','pronunciation'),
('listening.sounds','listening'),
('listening.words','listening'),
('listening.instructions','listening'),
('listening.details','listening'),
('listening.sequence','listening'),
('listening.gist','listening'),
('listening.questions','listening'),
('listening.conversation','listening'),
('listening.inference','listening'),
('listening.lectures','listening'),
('speaking.greetings','speaking'),
('speaking.introductions','speaking'),
('speaking.picture','speaking'),
('speaking.routine','speaking'),
('speaking.past','speaking'),
('speaking.requests','speaking'),
('speaking.opinions','speaking'),
('speaking.conversation','speaking'),
('speaking.presentation','speaking'),
('speaking.discussion','speaking');

CREATE SCHEMA IF NOT EXISTS qa;
REVOKE ALL ON SCHEMA qa FROM PUBLIC;
GRANT USAGE ON SCHEMA qa TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA qa REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE qa.orgs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text NOT NULL,region text NOT NULL DEFAULT 'IN');
CREATE TABLE qa.teachers(id uuid PRIMARY KEY REFERENCES auth.users(id),org_id uuid NOT NULL REFERENCES qa.orgs(id),display_name text NOT NULL);
CREATE TABLE qa.classes(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),org_id uuid NOT NULL REFERENCES qa.orgs(id),name text NOT NULL,code_hash text UNIQUE,code_expires_at timestamptz);
CREATE TABLE qa.teacher_assignments(class_id uuid REFERENCES qa.classes(id) ON DELETE CASCADE,teacher_id uuid REFERENCES qa.teachers(id) ON DELETE CASCADE,from_at timestamptz NOT NULL DEFAULT now(),to_at timestamptz,PRIMARY KEY(class_id,teacher_id),CHECK(to_at IS NULL OR to_at>from_at));
CREATE TABLE qa.learners(id text PRIMARY KEY CHECK(id ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$'),org_id uuid NOT NULL REFERENCES qa.orgs(id),display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 60),age_band text NOT NULL CHECK(age_band IN ('child','student','adult')),minor boolean NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE qa.enrollments(class_id uuid REFERENCES qa.classes(id) ON DELETE CASCADE,learner_id text REFERENCES qa.learners(id) ON DELETE CASCADE,status text NOT NULL CHECK(status IN ('pending','active','left')),from_at timestamptz NOT NULL DEFAULT now(),to_at timestamptz,PRIMARY KEY(class_id,learner_id));
CREATE TABLE qa.guardians(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES qa.learners(id) ON DELETE CASCADE,contact_hash text NOT NULL,verified_via text NOT NULL CHECK(verified_via IN ('otp','teacherWitnessedPaper')),verification_reference text NOT NULL);
CREATE TABLE qa.consents(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES qa.learners(id) ON DELETE CASCADE,purpose text NOT NULL CHECK(purpose IN ('core','microphone','clipRetention','serverSync','telemetry')),guardian_id uuid REFERENCES qa.guardians(id) ON DELETE CASCADE,verified_via text NOT NULL CHECK(verified_via IN ('self','otp','teacherWitnessedPaper')),version integer NOT NULL CHECK(version>0),granted_at timestamptz NOT NULL DEFAULT now(),revoked_at timestamptz);
CREATE TABLE qa.devices(id text PRIMARY KEY,user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id),revoked_at timestamptz,last_seen_at timestamptz);
CREATE TABLE qa.device_learners(device_id text REFERENCES qa.devices(id) ON DELETE CASCADE,learner_id text REFERENCES qa.learners(id) ON DELETE CASCADE,PRIMARY KEY(device_id,learner_id));
CREATE TABLE qa.skill_nodes(id text PRIMARY KEY,skill text NOT NULL,prior double precision NOT NULL DEFAULT .3,transition double precision NOT NULL DEFAULT .1,guess double precision NOT NULL DEFAULT .2,slip double precision NOT NULL DEFAULT .1,CHECK(prior BETWEEN 0 AND 1 AND transition BETWEEN 0 AND 1 AND guess>0 AND guess<1 AND slip>0 AND slip<1));
-- A separate registry enforces global identity across monthly partitions.
CREATE TABLE qa.event_ids(id text PRIMARY KEY,device_id text NOT NULL,seq bigint NOT NULL,learner_id text NOT NULL REFERENCES qa.learners(id) ON DELETE CASCADE,fingerprint bytea NOT NULL,UNIQUE(device_id,seq));
CREATE TABLE qa.events(id text NOT NULL,learner_id text NOT NULL REFERENCES qa.learners(id) ON DELETE CASCADE,device_id text NOT NULL,seq bigint NOT NULL CHECK(seq>0),hlc text NOT NULL,type text NOT NULL,v integer NOT NULL CHECK(v=1),payload jsonb NOT NULL,received_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(id,received_at)) PARTITION BY RANGE(received_at);
CREATE INDEX ON qa.events(learner_id,hlc,id);
CREATE INDEX ON qa.events(device_id,seq);
CREATE TABLE qa.learner_node_state(learner_id text REFERENCES qa.learners(id) ON DELETE CASCADE,node_id text REFERENCES qa.skill_nodes(id),p_learned double precision NOT NULL CHECK(p_learned BETWEEN 0 AND 1),n_obs integer NOT NULL,last_hlc text NOT NULL,PRIMARY KEY(learner_id,node_id));
CREATE TABLE qa.learner_daily(learner_id text REFERENCES qa.learners(id) ON DELETE CASCADE,day date NOT NULL,attempts integer NOT NULL DEFAULT 0,sessions integer NOT NULL DEFAULT 0,minutes double precision NOT NULL DEFAULT 0,PRIMARY KEY(learner_id,day));
CREATE TABLE qa.class_snapshot(class_id uuid REFERENCES qa.classes(id) ON DELETE CASCADE,day date NOT NULL,body jsonb NOT NULL,PRIMARY KEY(class_id,day));
CREATE TABLE qa.insights(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES qa.learners(id) ON DELETE CASCADE,node_id text NOT NULL REFERENCES qa.skill_nodes(id),claim text NOT NULL,evidence_ids text[] NOT NULL,status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','approved','rejected')),reviewed_by uuid REFERENCES qa.teachers(id),created_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX ON qa.insights(learner_id,node_id) WHERE status='open';
CREATE TABLE qa.interventions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES qa.learners(id) ON DELETE CASCADE,class_id uuid NOT NULL REFERENCES qa.classes(id) ON DELETE CASCADE,teacher_id uuid NOT NULL REFERENCES qa.teachers(id),node_id text NOT NULL REFERENCES qa.skill_nodes(id),kind text NOT NULL CHECK(kind IN ('approve','reject','assign','replace','pin','unpin','note')),payload jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE qa.content_packs(id text PRIMARY KEY,manifest jsonb NOT NULL,channel text NOT NULL CHECK(channel IN ('internal','pilot','production')),enabled boolean NOT NULL DEFAULT false);
CREATE TABLE qa.model_packs(LIKE qa.content_packs INCLUDING ALL);
CREATE TABLE qa.erasure_tombstones(learner_id text PRIMARY KEY,erased_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE qa.erasure_targets(learner_id text REFERENCES qa.erasure_tombstones(learner_id),user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,acknowledged_at timestamptz,PRIMARY KEY(learner_id,user_id));
CREATE TABLE qa.audit_log(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,actor uuid,action text NOT NULL,target_hash text NOT NULL,at timestamptz NOT NULL DEFAULT now());

CREATE FUNCTION qa.teacher_has_class(target uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM qa.teacher_assignments a WHERE a.class_id=target AND a.teacher_id=auth.uid() AND a.from_at<=now() AND (a.to_at IS NULL OR a.to_at>now()))
$$;
CREATE FUNCTION qa.can_read_learner(target text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM qa.enrollments e WHERE e.learner_id=target AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now()) AND qa.teacher_has_class(e.class_id))
 OR EXISTS(SELECT 1 FROM qa.device_learners dl JOIN qa.devices d ON d.id=dl.device_id WHERE dl.learner_id=target AND d.user_id=auth.uid() AND d.revoked_at IS NULL)
$$;
CREATE FUNCTION qa.owns_learner(target text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM qa.device_learners dl JOIN qa.devices d ON d.id=dl.device_id WHERE dl.learner_id=target AND d.user_id=auth.uid() AND d.revoked_at IS NULL)
$$;
CREATE FUNCTION qa.has_consent(target text,wanted text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM qa.consents c JOIN qa.learners l ON l.id=c.learner_id LEFT JOIN qa.guardians g ON g.id=c.guardian_id
 WHERE c.learner_id=target AND c.purpose=wanted AND c.revoked_at IS NULL AND c.granted_at<=now()
 AND (NOT l.minor OR (g.learner_id=l.id AND c.verified_via IN ('otp','teacherWitnessedPaper'))))
$$;
CREATE FUNCTION qa.ensure_month(month_start date) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE start_at date:=date_trunc('month',month_start)::date; table_name text;
BEGIN
 table_name:='events_'||to_char(start_at,'YYYYMM');
 EXECUTE format('CREATE TABLE IF NOT EXISTS qa.%I PARTITION OF qa.events FOR VALUES FROM (%L) TO (%L)',table_name,start_at,(start_at+interval '1 month')::date);
 EXECUTE format('ALTER TABLE qa.%I ENABLE ROW LEVEL SECURITY',table_name);
END $$;
SELECT qa.ensure_month(current_date);
SELECT qa.ensure_month((current_date+interval '1 month')::date);
SELECT qa.ensure_month((current_date-interval '1 month')::date);

CREATE FUNCTION qa.fold_learner(target text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e record;p record;old double precision;post double precision;s double precision;
BEGIN
 DELETE FROM qa.learner_node_state WHERE learner_id=target;
 DELETE FROM qa.learner_daily WHERE learner_id=target;
 FOR e IN SELECT * FROM qa.events WHERE learner_id=target ORDER BY hlc,id LOOP
  IF e.type IN ('PracticeAttempt','AssessmentItemAnswered') THEN
   SELECT * INTO STRICT p FROM qa.skill_nodes WHERE id=e.payload->>'nodeId';
   SELECT p_learned INTO old FROM qa.learner_node_state WHERE learner_id=target AND node_id=p.id;
   old:=coalesce(old,p.prior);s:=(e.payload->>'score')::double precision;
   post:=s*(old*(1-p.slip)/(old*(1-p.slip)+(1-old)*p.guess))+(1-s)*(old*p.slip/(old*p.slip+(1-old)*(1-p.guess)));
   INSERT INTO qa.learner_node_state VALUES(target,p.id,post+(1-post)*p.transition,1,e.hlc)
    ON CONFLICT(learner_id,node_id) DO UPDATE SET p_learned=excluded.p_learned,n_obs=qa.learner_node_state.n_obs+1,last_hlc=excluded.last_hlc;
   INSERT INTO qa.learner_daily(learner_id,day,attempts) VALUES(target,to_timestamp(split_part(e.hlc,':',1)::bigint/1000.0)::date,1)
    ON CONFLICT(learner_id,day) DO UPDATE SET attempts=qa.learner_daily.attempts+1;
  ELSIF e.type='SessionEnded' THEN
   INSERT INTO qa.learner_daily(learner_id,day,sessions,minutes) VALUES(target,to_timestamp(split_part(e.hlc,':',1)::bigint/1000.0)::date,1,least(120,greatest(0,coalesce((e.payload->>'durationMs')::double precision,0)/60000)))
    ON CONFLICT(learner_id,day) DO UPDATE SET sessions=qa.learner_daily.sessions+1,minutes=qa.learner_daily.minutes+excluded.minutes;
  END IF;
 END LOOP;
END $$;

CREATE FUNCTION qa.erase_learner(target_learner text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT qa.owns_learner(target_learner) AND coalesce(auth.jwt()->>'role','')<>'service_role' THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(target_learner,0));
 INSERT INTO qa.erasure_tombstones(learner_id) VALUES(target_learner) ON CONFLICT DO NOTHING;
 INSERT INTO qa.erasure_targets(learner_id,user_id) SELECT target_learner,d.user_id FROM qa.device_learners dl JOIN qa.devices d ON d.id=dl.device_id WHERE dl.learner_id=target_learner ON CONFLICT DO NOTHING;
 -- Remove aggregates for every affected class before deleting enrolments.
 DELETE FROM qa.class_snapshot WHERE class_id IN(SELECT class_id FROM qa.enrollments WHERE learner_id=target_learner);
 DELETE FROM qa.learners WHERE id=target_learner;
 INSERT INTO qa.audit_log(actor,action,target_hash) VALUES(auth.uid(),'erase',encode(extensions.digest(target_learner,'sha256'),'hex'));
END $$;
CREATE FUNCTION qa.prevent_resurrection() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF EXISTS(SELECT 1 FROM qa.erasure_tombstones WHERE learner_id=NEW.id) THEN RAISE EXCEPTION 'Learner has been erased';END IF;RETURN NEW;END $$;
CREATE TRIGGER no_resurrection BEFORE INSERT ON qa.learners FOR EACH ROW EXECUTE FUNCTION qa.prevent_resurrection();

CREATE FUNCTION qa.ingest_events(batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb; bound text; existing qa.event_ids; fingerprint bytea; learner text; seen text[]:='{}';accepted text[]:='{}';n integer;event_type text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR octet_length(batch::text)>4194304 THEN RAISE EXCEPTION 'Invalid batch';END IF;
 SELECT id INTO bound FROM qa.devices WHERE user_id=auth.uid() AND revoked_at IS NULL;
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
  IF EXISTS(SELECT 1 FROM qa.erasure_targets WHERE learner_id=learner AND user_id=auth.uid()) THEN accepted:=array_append(accepted,e->>'id');CONTINUE;END IF;
  IF NOT qa.owns_learner(learner) THEN RAISE EXCEPTION 'Learner not bound to device' USING ERRCODE='42501';END IF;
  IF event_type='LearnerErased' THEN PERFORM qa.erase_learner(learner);accepted:=array_append(accepted,e->>'id');CONTINUE;END IF;
  IF event_type='ConsentRevoked' THEN
   IF e->'payload'->>'purpose' NOT IN ('core','microphone','clipRetention','serverSync','telemetry') OR NOT(e->'payload' ? 'purpose') THEN RAISE EXCEPTION 'Invalid consent purpose';END IF;
   IF e->'payload'->>'purpose'='core' THEN PERFORM qa.erase_learner(learner);
   ELSE
    UPDATE qa.consents SET revoked_at=now() WHERE learner_id=learner AND purpose=e->'payload'->>'purpose' AND revoked_at IS NULL;
    INSERT INTO qa.audit_log(actor,action,target_hash) VALUES(auth.uid(),'revoke:'||(e->'payload'->>'purpose'),encode(extensions.digest(learner,'sha256'),'hex'));
   END IF;
   accepted:=array_append(accepted,e->>'id');CONTINUE;
  END IF;
  IF NOT qa.has_consent(learner,'core') OR NOT qa.has_consent(learner,'serverSync') THEN RAISE EXCEPTION 'Sync consent missing' USING ERRCODE='42501';END IF;
  IF event_type IN ('PracticeAttempt','AssessmentItemAnswered') THEN
   IF jsonb_typeof(e->'payload'->'score')<>'number' OR (e->'payload'->>'score')::numeric NOT BETWEEN 0 AND 1 OR NOT(e->'payload' ?& ARRAY['score','itemId','nodeId']) OR NOT EXISTS(SELECT 1 FROM qa.skill_nodes WHERE id=e->'payload'->>'nodeId') THEN RAISE EXCEPTION 'Invalid observation';END IF;
  END IF;
  fingerprint:=extensions.digest(e::text,'sha256');
  SELECT * INTO existing FROM qa.event_ids WHERE id=e->>'id' OR (device_id=bound AND seq=(e->>'seq')::bigint) LIMIT 1;
  IF FOUND THEN
   IF existing.id<>e->>'id' OR existing.fingerprint<>fingerprint THEN RAISE EXCEPTION 'Conflicting event identity';END IF;
  ELSE
   INSERT INTO qa.event_ids VALUES(e->>'id',bound,(e->>'seq')::bigint,learner,fingerprint);
   INSERT INTO qa.events(id,learner_id,device_id,seq,hlc,type,v,payload) VALUES(e->>'id',learner,bound,(e->>'seq')::bigint,e->>'hlc',event_type,1,e->'payload');
   seen:=array_append(seen,learner);
  END IF;
  accepted:=array_append(accepted,e->>'id');
 END LOOP;
 FOR learner IN SELECT DISTINCT unnest(seen) LOOP PERFORM qa.fold_learner(learner);END LOOP;
 UPDATE qa.devices SET last_seen_at=now() WHERE id=bound;
 RETURN jsonb_build_object('acceptedIds',to_jsonb(accepted));
END $$;

CREATE FUNCTION qa.teacher_intervene(target_learner text,target_class uuid,target_node text,action_kind text,insight_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT qa.teacher_has_class(target_class) OR NOT EXISTS(SELECT 1 FROM qa.enrollments WHERE learner_id=target_learner AND class_id=target_class AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF action_kind NOT IN ('approve','reject','assign','pin','unpin') THEN RAISE EXCEPTION 'Invalid intervention';END IF;
 INSERT INTO qa.interventions(learner_id,class_id,teacher_id,node_id,kind) VALUES(target_learner,target_class,auth.uid(),target_node,action_kind) RETURNING id INTO result;
 IF insight_id IS NOT NULL THEN
  UPDATE qa.insights SET status=CASE WHEN action_kind='reject' THEN 'rejected' ELSE 'approved' END,reviewed_by=auth.uid() WHERE id=insight_id AND learner_id=target_learner AND node_id=target_node AND status='open';
  IF NOT FOUND THEN RAISE EXCEPTION 'Insight does not match learner';END IF;
 END IF;
 INSERT INTO qa.audit_log(actor,action,target_hash) VALUES(auth.uid(),'intervention:'||action_kind,encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN result;
END $$;
CREATE FUNCTION qa.export_learner(target_learner text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT qa.owns_learner(target_learner) AND coalesce(auth.jwt()->>'role','')<>'service_role' THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';END IF;
 INSERT INTO qa.audit_log(actor,action,target_hash) VALUES(auth.uid(),'export',encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN jsonb_build_object('learner',(SELECT to_jsonb(l) FROM qa.learners l WHERE id=target_learner),'events',coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY hlc,id) FROM qa.events e WHERE learner_id=target_learner),'[]'::jsonb));
END $$;
CREATE FUNCTION qa.build_insights() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 INSERT INTO qa.insights(learner_id,node_id,claim,evidence_ids)
 SELECT learner_id,node_id,format('%s of the last %s attempts on %s scored below 50%%.',count(*) FILTER(WHERE score<.5),count(*),node_id),array_agg(id ORDER BY hlc,id)
 FROM(SELECT learner_id,payload->>'nodeId' node_id,id,hlc,(payload->>'score')::double precision score,row_number() OVER(PARTITION BY learner_id,payload->>'nodeId' ORDER BY hlc DESC,id DESC) rn FROM qa.events WHERE type IN ('PracticeAttempt','AssessmentItemAnswered')) recent
 WHERE rn<=14 GROUP BY learner_id,node_id HAVING count(*)>=6 AND count(*) FILTER(WHERE score<.5)::double precision/count(*)>=.6
 ON CONFLICT(learner_id,node_id) WHERE status='open' DO NOTHING;
END $$;
CREATE FUNCTION qa.refresh_class_snapshots() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 INSERT INTO qa.class_snapshot(class_id,day,body)
 SELECT c.id,current_date,jsonb_build_object('activeLearners',count(DISTINCT e.learner_id),'observations',coalesce(sum(s.n_obs),0),'meanMastery',avg(s.p_learned))
 FROM qa.classes c LEFT JOIN qa.enrollments e ON e.class_id=c.id AND e.status='active' LEFT JOIN qa.learner_node_state s ON s.learner_id=e.learner_id GROUP BY c.id
 ON CONFLICT(class_id,day) DO UPDATE SET body=excluded.body
$$;

-- Every application table is default-deny. RPCs are the only mutation surface.
DO $$ DECLARE r record;BEGIN FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='qa' LOOP EXECUTE format('ALTER TABLE qa.%I ENABLE ROW LEVEL SECURITY',r.tablename);END LOOP;END $$;
CREATE POLICY teacher_self ON qa.teachers FOR SELECT TO authenticated USING(id=auth.uid());
CREATE POLICY assigned_classes ON qa.classes FOR SELECT TO authenticated USING(qa.teacher_has_class(id));
CREATE POLICY own_assignments ON qa.teacher_assignments FOR SELECT TO authenticated USING(teacher_id=auth.uid());
CREATE POLICY assigned_enrollments ON qa.enrollments FOR SELECT TO authenticated USING(qa.teacher_has_class(class_id) OR qa.owns_learner(learner_id));
CREATE POLICY assigned_learners ON qa.learners FOR SELECT TO authenticated USING(qa.can_read_learner(id));
CREATE POLICY own_devices ON qa.devices FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY own_bindings ON qa.device_learners FOR SELECT TO authenticated USING(qa.owns_learner(learner_id));
CREATE POLICY learner_events ON qa.events FOR SELECT TO authenticated USING(qa.can_read_learner(learner_id));
CREATE POLICY learner_mastery ON qa.learner_node_state FOR SELECT TO authenticated USING(qa.can_read_learner(learner_id));
CREATE POLICY learner_daily ON qa.learner_daily FOR SELECT TO authenticated USING(qa.can_read_learner(learner_id));
CREATE POLICY class_summary ON qa.class_snapshot FOR SELECT TO authenticated USING(qa.teacher_has_class(class_id));
CREATE POLICY learner_insights ON qa.insights FOR SELECT TO authenticated USING(qa.can_read_learner(learner_id));
CREATE POLICY learner_interventions ON qa.interventions FOR SELECT TO authenticated USING(qa.can_read_learner(learner_id));
CREATE POLICY own_consents ON qa.consents FOR SELECT TO authenticated USING(qa.owns_learner(learner_id));
CREATE POLICY erasure_delivery ON qa.erasure_targets FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY content_published ON qa.content_packs FOR SELECT TO authenticated USING(enabled AND channel='production');
CREATE POLICY model_published ON qa.model_packs FOR SELECT TO authenticated USING(enabled AND channel='production');
CREATE POLICY skill_catalog ON qa.skill_nodes FOR SELECT TO authenticated USING(true);
REVOKE ALL ON ALL TABLES IN SCHEMA qa FROM anon,authenticated;
GRANT SELECT ON qa.teachers,qa.classes,qa.teacher_assignments,qa.enrollments,qa.learners,qa.devices,qa.device_learners,qa.events,qa.learner_node_state,qa.learner_daily,qa.class_snapshot,qa.insights,qa.interventions,qa.consents,qa.erasure_targets,qa.content_packs,qa.model_packs,qa.skill_nodes TO authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA qa FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION qa.teacher_has_class(uuid),qa.can_read_learner(text),qa.owns_learner(text),qa.ingest_events(jsonb),qa.erase_learner(text),qa.export_learner(text),qa.teacher_intervene(text,uuid,text,text,uuid) TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA qa TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA qa TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA qa TO service_role;

INSERT INTO qa.skill_nodes(id,skill) VALUES
('vocabulary.frequent_500','vocabulary'),
('vocabulary.people','vocabulary'),
('vocabulary.places','vocabulary'),
('vocabulary.actions','vocabulary'),
('vocabulary.describing','vocabulary'),
('vocabulary.time','vocabulary'),
('vocabulary.context','vocabulary'),
('vocabulary.collocations','vocabulary'),
('vocabulary.word_families','vocabulary'),
('vocabulary.academic','vocabulary'),
('grammar.simple_present_agreement','grammar'),
('grammar.articles','grammar'),
('grammar.pronouns','grammar'),
('grammar.plurals','grammar'),
('grammar.prepositions','grammar'),
('grammar.regular_past','grammar'),
('grammar.irregular_past','grammar'),
('grammar.progressive','grammar'),
('grammar.modals','grammar'),
('grammar.complex','grammar'),
('sentence.simple','sentence'),
('sentence.questions','sentence'),
('sentence.negatives','sentence'),
('sentence.descriptions','sentence'),
('sentence.past_narration','sentence'),
('sentence.future','sentence'),
('sentence.joining','sentence'),
('sentence.ordering','sentence'),
('sentence.paragraphs','sentence'),
('sentence.arguments','sentence'),
('reading.letters','reading'),
('reading.words','reading'),
('reading.phrases','reading'),
('reading.a1','reading'),
('reading.a2','reading'),
('reading.punctuation','reading'),
('reading.detail','reading'),
('reading.inference','reading'),
('reading.b1','reading'),
('reading.b2','reading'),
('pronunciation.v_w','pronunciation'),
('pronunciation.th','pronunciation'),
('pronunciation.vowels','pronunciation'),
('pronunciation.final_consonants','pronunciation'),
('pronunciation.clusters','pronunciation'),
('pronunciation.syllables','pronunciation'),
('pronunciation.word_stress','pronunciation'),
('pronunciation.sentence_stress','pronunciation'),
('pronunciation.linking','pronunciation'),
('pronunciation.intonation','pronunciation'),
('listening.sounds','listening'),
('listening.words','listening'),
('listening.instructions','listening'),
('listening.details','listening'),
('listening.sequence','listening'),
('listening.gist','listening'),
('listening.questions','listening'),
('listening.conversation','listening'),
('listening.inference','listening'),
('listening.lectures','listening'),
('speaking.greetings','speaking'),
('speaking.introductions','speaking'),
('speaking.picture','speaking'),
('speaking.routine','speaking'),
('speaking.past','speaking'),
('speaking.requests','speaking'),
('speaking.opinions','speaking'),
('speaking.conversation','speaking'),
('speaking.presentation','speaking'),
('speaking.discussion','speaking');

CREATE SCHEMA IF NOT EXISTS prod;
REVOKE ALL ON SCHEMA prod FROM PUBLIC;
GRANT USAGE ON SCHEMA prod TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA prod REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE prod.orgs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),name text NOT NULL,region text NOT NULL DEFAULT 'IN');
CREATE TABLE prod.teachers(id uuid PRIMARY KEY REFERENCES auth.users(id),org_id uuid NOT NULL REFERENCES prod.orgs(id),display_name text NOT NULL);
CREATE TABLE prod.classes(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),org_id uuid NOT NULL REFERENCES prod.orgs(id),name text NOT NULL,code_hash text UNIQUE,code_expires_at timestamptz);
CREATE TABLE prod.teacher_assignments(class_id uuid REFERENCES prod.classes(id) ON DELETE CASCADE,teacher_id uuid REFERENCES prod.teachers(id) ON DELETE CASCADE,from_at timestamptz NOT NULL DEFAULT now(),to_at timestamptz,PRIMARY KEY(class_id,teacher_id),CHECK(to_at IS NULL OR to_at>from_at));
CREATE TABLE prod.learners(id text PRIMARY KEY CHECK(id ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$'),org_id uuid NOT NULL REFERENCES prod.orgs(id),display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 60),age_band text NOT NULL CHECK(age_band IN ('child','student','adult')),minor boolean NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE prod.enrollments(class_id uuid REFERENCES prod.classes(id) ON DELETE CASCADE,learner_id text REFERENCES prod.learners(id) ON DELETE CASCADE,status text NOT NULL CHECK(status IN ('pending','active','left')),from_at timestamptz NOT NULL DEFAULT now(),to_at timestamptz,PRIMARY KEY(class_id,learner_id));
CREATE TABLE prod.guardians(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES prod.learners(id) ON DELETE CASCADE,contact_hash text NOT NULL,verified_via text NOT NULL CHECK(verified_via IN ('otp','teacherWitnessedPaper')),verification_reference text NOT NULL);
CREATE TABLE prod.consents(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES prod.learners(id) ON DELETE CASCADE,purpose text NOT NULL CHECK(purpose IN ('core','microphone','clipRetention','serverSync','telemetry')),guardian_id uuid REFERENCES prod.guardians(id) ON DELETE CASCADE,verified_via text NOT NULL CHECK(verified_via IN ('self','otp','teacherWitnessedPaper')),version integer NOT NULL CHECK(version>0),granted_at timestamptz NOT NULL DEFAULT now(),revoked_at timestamptz);
CREATE TABLE prod.devices(id text PRIMARY KEY,user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id),revoked_at timestamptz,last_seen_at timestamptz);
CREATE TABLE prod.device_learners(device_id text REFERENCES prod.devices(id) ON DELETE CASCADE,learner_id text REFERENCES prod.learners(id) ON DELETE CASCADE,PRIMARY KEY(device_id,learner_id));
CREATE TABLE prod.skill_nodes(id text PRIMARY KEY,skill text NOT NULL,prior double precision NOT NULL DEFAULT .3,transition double precision NOT NULL DEFAULT .1,guess double precision NOT NULL DEFAULT .2,slip double precision NOT NULL DEFAULT .1,CHECK(prior BETWEEN 0 AND 1 AND transition BETWEEN 0 AND 1 AND guess>0 AND guess<1 AND slip>0 AND slip<1));
-- A separate registry enforces global identity across monthly partitions.
CREATE TABLE prod.event_ids(id text PRIMARY KEY,device_id text NOT NULL,seq bigint NOT NULL,learner_id text NOT NULL REFERENCES prod.learners(id) ON DELETE CASCADE,fingerprint bytea NOT NULL,UNIQUE(device_id,seq));
CREATE TABLE prod.events(id text NOT NULL,learner_id text NOT NULL REFERENCES prod.learners(id) ON DELETE CASCADE,device_id text NOT NULL,seq bigint NOT NULL CHECK(seq>0),hlc text NOT NULL,type text NOT NULL,v integer NOT NULL CHECK(v=1),payload jsonb NOT NULL,received_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(id,received_at)) PARTITION BY RANGE(received_at);
CREATE INDEX ON prod.events(learner_id,hlc,id);
CREATE INDEX ON prod.events(device_id,seq);
CREATE TABLE prod.learner_node_state(learner_id text REFERENCES prod.learners(id) ON DELETE CASCADE,node_id text REFERENCES prod.skill_nodes(id),p_learned double precision NOT NULL CHECK(p_learned BETWEEN 0 AND 1),n_obs integer NOT NULL,last_hlc text NOT NULL,PRIMARY KEY(learner_id,node_id));
CREATE TABLE prod.learner_daily(learner_id text REFERENCES prod.learners(id) ON DELETE CASCADE,day date NOT NULL,attempts integer NOT NULL DEFAULT 0,sessions integer NOT NULL DEFAULT 0,minutes double precision NOT NULL DEFAULT 0,PRIMARY KEY(learner_id,day));
CREATE TABLE prod.class_snapshot(class_id uuid REFERENCES prod.classes(id) ON DELETE CASCADE,day date NOT NULL,body jsonb NOT NULL,PRIMARY KEY(class_id,day));
CREATE TABLE prod.insights(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES prod.learners(id) ON DELETE CASCADE,node_id text NOT NULL REFERENCES prod.skill_nodes(id),claim text NOT NULL,evidence_ids text[] NOT NULL,status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','approved','rejected')),reviewed_by uuid REFERENCES prod.teachers(id),created_at timestamptz NOT NULL DEFAULT now());
CREATE UNIQUE INDEX ON prod.insights(learner_id,node_id) WHERE status='open';
CREATE TABLE prod.interventions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),learner_id text NOT NULL REFERENCES prod.learners(id) ON DELETE CASCADE,class_id uuid NOT NULL REFERENCES prod.classes(id) ON DELETE CASCADE,teacher_id uuid NOT NULL REFERENCES prod.teachers(id),node_id text NOT NULL REFERENCES prod.skill_nodes(id),kind text NOT NULL CHECK(kind IN ('approve','reject','assign','replace','pin','unpin','note')),payload jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE prod.content_packs(id text PRIMARY KEY,manifest jsonb NOT NULL,channel text NOT NULL CHECK(channel IN ('internal','pilot','production')),enabled boolean NOT NULL DEFAULT false);
CREATE TABLE prod.model_packs(LIKE prod.content_packs INCLUDING ALL);
CREATE TABLE prod.erasure_tombstones(learner_id text PRIMARY KEY,erased_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE prod.erasure_targets(learner_id text REFERENCES prod.erasure_tombstones(learner_id),user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,acknowledged_at timestamptz,PRIMARY KEY(learner_id,user_id));
CREATE TABLE prod.audit_log(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,actor uuid,action text NOT NULL,target_hash text NOT NULL,at timestamptz NOT NULL DEFAULT now());

CREATE FUNCTION prod.teacher_has_class(target uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM prod.teacher_assignments a WHERE a.class_id=target AND a.teacher_id=auth.uid() AND a.from_at<=now() AND (a.to_at IS NULL OR a.to_at>now()))
$$;
CREATE FUNCTION prod.can_read_learner(target text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM prod.enrollments e WHERE e.learner_id=target AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now()) AND prod.teacher_has_class(e.class_id))
 OR EXISTS(SELECT 1 FROM prod.device_learners dl JOIN prod.devices d ON d.id=dl.device_id WHERE dl.learner_id=target AND d.user_id=auth.uid() AND d.revoked_at IS NULL)
$$;
CREATE FUNCTION prod.owns_learner(target text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM prod.device_learners dl JOIN prod.devices d ON d.id=dl.device_id WHERE dl.learner_id=target AND d.user_id=auth.uid() AND d.revoked_at IS NULL)
$$;
CREATE FUNCTION prod.has_consent(target text,wanted text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM prod.consents c JOIN prod.learners l ON l.id=c.learner_id LEFT JOIN prod.guardians g ON g.id=c.guardian_id
 WHERE c.learner_id=target AND c.purpose=wanted AND c.revoked_at IS NULL AND c.granted_at<=now()
 AND (NOT l.minor OR (g.learner_id=l.id AND c.verified_via IN ('otp','teacherWitnessedPaper'))))
$$;
CREATE FUNCTION prod.ensure_month(month_start date) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE start_at date:=date_trunc('month',month_start)::date; table_name text;
BEGIN
 table_name:='events_'||to_char(start_at,'YYYYMM');
 EXECUTE format('CREATE TABLE IF NOT EXISTS prod.%I PARTITION OF prod.events FOR VALUES FROM (%L) TO (%L)',table_name,start_at,(start_at+interval '1 month')::date);
 EXECUTE format('ALTER TABLE prod.%I ENABLE ROW LEVEL SECURITY',table_name);
END $$;
SELECT prod.ensure_month(current_date);
SELECT prod.ensure_month((current_date+interval '1 month')::date);
SELECT prod.ensure_month((current_date-interval '1 month')::date);

CREATE FUNCTION prod.fold_learner(target text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e record;p record;old double precision;post double precision;s double precision;
BEGIN
 DELETE FROM prod.learner_node_state WHERE learner_id=target;
 DELETE FROM prod.learner_daily WHERE learner_id=target;
 FOR e IN SELECT * FROM prod.events WHERE learner_id=target ORDER BY hlc,id LOOP
  IF e.type IN ('PracticeAttempt','AssessmentItemAnswered') THEN
   SELECT * INTO STRICT p FROM prod.skill_nodes WHERE id=e.payload->>'nodeId';
   SELECT p_learned INTO old FROM prod.learner_node_state WHERE learner_id=target AND node_id=p.id;
   old:=coalesce(old,p.prior);s:=(e.payload->>'score')::double precision;
   post:=s*(old*(1-p.slip)/(old*(1-p.slip)+(1-old)*p.guess))+(1-s)*(old*p.slip/(old*p.slip+(1-old)*(1-p.guess)));
   INSERT INTO prod.learner_node_state VALUES(target,p.id,post+(1-post)*p.transition,1,e.hlc)
    ON CONFLICT(learner_id,node_id) DO UPDATE SET p_learned=excluded.p_learned,n_obs=prod.learner_node_state.n_obs+1,last_hlc=excluded.last_hlc;
   INSERT INTO prod.learner_daily(learner_id,day,attempts) VALUES(target,to_timestamp(split_part(e.hlc,':',1)::bigint/1000.0)::date,1)
    ON CONFLICT(learner_id,day) DO UPDATE SET attempts=prod.learner_daily.attempts+1;
  ELSIF e.type='SessionEnded' THEN
   INSERT INTO prod.learner_daily(learner_id,day,sessions,minutes) VALUES(target,to_timestamp(split_part(e.hlc,':',1)::bigint/1000.0)::date,1,least(120,greatest(0,coalesce((e.payload->>'durationMs')::double precision,0)/60000)))
    ON CONFLICT(learner_id,day) DO UPDATE SET sessions=prod.learner_daily.sessions+1,minutes=prod.learner_daily.minutes+excluded.minutes;
  END IF;
 END LOOP;
END $$;

CREATE FUNCTION prod.erase_learner(target_learner text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT prod.owns_learner(target_learner) AND coalesce(auth.jwt()->>'role','')<>'service_role' THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(target_learner,0));
 INSERT INTO prod.erasure_tombstones(learner_id) VALUES(target_learner) ON CONFLICT DO NOTHING;
 INSERT INTO prod.erasure_targets(learner_id,user_id) SELECT target_learner,d.user_id FROM prod.device_learners dl JOIN prod.devices d ON d.id=dl.device_id WHERE dl.learner_id=target_learner ON CONFLICT DO NOTHING;
 -- Remove aggregates for every affected class before deleting enrolments.
 DELETE FROM prod.class_snapshot WHERE class_id IN(SELECT class_id FROM prod.enrollments WHERE learner_id=target_learner);
 DELETE FROM prod.learners WHERE id=target_learner;
 INSERT INTO prod.audit_log(actor,action,target_hash) VALUES(auth.uid(),'erase',encode(extensions.digest(target_learner,'sha256'),'hex'));
END $$;
CREATE FUNCTION prod.prevent_resurrection() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN IF EXISTS(SELECT 1 FROM prod.erasure_tombstones WHERE learner_id=NEW.id) THEN RAISE EXCEPTION 'Learner has been erased';END IF;RETURN NEW;END $$;
CREATE TRIGGER no_resurrection BEFORE INSERT ON prod.learners FOR EACH ROW EXECUTE FUNCTION prod.prevent_resurrection();

CREATE FUNCTION prod.ingest_events(batch jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb; bound text; existing prod.event_ids; fingerprint bytea; learner text; seen text[]:='{}';accepted text[]:='{}';n integer;event_type text;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;
 IF jsonb_typeof(batch)<>'array' OR jsonb_array_length(batch)>500 OR octet_length(batch::text)>4194304 THEN RAISE EXCEPTION 'Invalid batch';END IF;
 SELECT id INTO bound FROM prod.devices WHERE user_id=auth.uid() AND revoked_at IS NULL;
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
  IF EXISTS(SELECT 1 FROM prod.erasure_targets WHERE learner_id=learner AND user_id=auth.uid()) THEN accepted:=array_append(accepted,e->>'id');CONTINUE;END IF;
  IF NOT prod.owns_learner(learner) THEN RAISE EXCEPTION 'Learner not bound to device' USING ERRCODE='42501';END IF;
  IF event_type='LearnerErased' THEN PERFORM prod.erase_learner(learner);accepted:=array_append(accepted,e->>'id');CONTINUE;END IF;
  IF event_type='ConsentRevoked' THEN
   IF e->'payload'->>'purpose' NOT IN ('core','microphone','clipRetention','serverSync','telemetry') OR NOT(e->'payload' ? 'purpose') THEN RAISE EXCEPTION 'Invalid consent purpose';END IF;
   IF e->'payload'->>'purpose'='core' THEN PERFORM prod.erase_learner(learner);
   ELSE
    UPDATE prod.consents SET revoked_at=now() WHERE learner_id=learner AND purpose=e->'payload'->>'purpose' AND revoked_at IS NULL;
    INSERT INTO prod.audit_log(actor,action,target_hash) VALUES(auth.uid(),'revoke:'||(e->'payload'->>'purpose'),encode(extensions.digest(learner,'sha256'),'hex'));
   END IF;
   accepted:=array_append(accepted,e->>'id');CONTINUE;
  END IF;
  IF NOT prod.has_consent(learner,'core') OR NOT prod.has_consent(learner,'serverSync') THEN RAISE EXCEPTION 'Sync consent missing' USING ERRCODE='42501';END IF;
  IF event_type IN ('PracticeAttempt','AssessmentItemAnswered') THEN
   IF jsonb_typeof(e->'payload'->'score')<>'number' OR (e->'payload'->>'score')::numeric NOT BETWEEN 0 AND 1 OR NOT(e->'payload' ?& ARRAY['score','itemId','nodeId']) OR NOT EXISTS(SELECT 1 FROM prod.skill_nodes WHERE id=e->'payload'->>'nodeId') THEN RAISE EXCEPTION 'Invalid observation';END IF;
  END IF;
  fingerprint:=extensions.digest(e::text,'sha256');
  SELECT * INTO existing FROM prod.event_ids WHERE id=e->>'id' OR (device_id=bound AND seq=(e->>'seq')::bigint) LIMIT 1;
  IF FOUND THEN
   IF existing.id<>e->>'id' OR existing.fingerprint<>fingerprint THEN RAISE EXCEPTION 'Conflicting event identity';END IF;
  ELSE
   INSERT INTO prod.event_ids VALUES(e->>'id',bound,(e->>'seq')::bigint,learner,fingerprint);
   INSERT INTO prod.events(id,learner_id,device_id,seq,hlc,type,v,payload) VALUES(e->>'id',learner,bound,(e->>'seq')::bigint,e->>'hlc',event_type,1,e->'payload');
   seen:=array_append(seen,learner);
  END IF;
  accepted:=array_append(accepted,e->>'id');
 END LOOP;
 FOR learner IN SELECT DISTINCT unnest(seen) LOOP PERFORM prod.fold_learner(learner);END LOOP;
 UPDATE prod.devices SET last_seen_at=now() WHERE id=bound;
 RETURN jsonb_build_object('acceptedIds',to_jsonb(accepted));
END $$;

CREATE FUNCTION prod.teacher_intervene(target_learner text,target_class uuid,target_node text,action_kind text,insight_id uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT prod.teacher_has_class(target_class) OR NOT EXISTS(SELECT 1 FROM prod.enrollments WHERE learner_id=target_learner AND class_id=target_class AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF action_kind NOT IN ('approve','reject','assign','pin','unpin') THEN RAISE EXCEPTION 'Invalid intervention';END IF;
 INSERT INTO prod.interventions(learner_id,class_id,teacher_id,node_id,kind) VALUES(target_learner,target_class,auth.uid(),target_node,action_kind) RETURNING id INTO result;
 IF insight_id IS NOT NULL THEN
  UPDATE prod.insights SET status=CASE WHEN action_kind='reject' THEN 'rejected' ELSE 'approved' END,reviewed_by=auth.uid() WHERE id=insight_id AND learner_id=target_learner AND node_id=target_node AND status='open';
  IF NOT FOUND THEN RAISE EXCEPTION 'Insight does not match learner';END IF;
 END IF;
 INSERT INTO prod.audit_log(actor,action,target_hash) VALUES(auth.uid(),'intervention:'||action_kind,encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN result;
END $$;
CREATE FUNCTION prod.export_learner(target_learner text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT prod.owns_learner(target_learner) AND coalesce(auth.jwt()->>'role','')<>'service_role' THEN RAISE EXCEPTION 'Not authorised' USING ERRCODE='42501';END IF;
 INSERT INTO prod.audit_log(actor,action,target_hash) VALUES(auth.uid(),'export',encode(extensions.digest(target_learner,'sha256'),'hex'));
 RETURN jsonb_build_object('learner',(SELECT to_jsonb(l) FROM prod.learners l WHERE id=target_learner),'events',coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY hlc,id) FROM prod.events e WHERE learner_id=target_learner),'[]'::jsonb));
END $$;
CREATE FUNCTION prod.build_insights() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 INSERT INTO prod.insights(learner_id,node_id,claim,evidence_ids)
 SELECT learner_id,node_id,format('%s of the last %s attempts on %s scored below 50%%.',count(*) FILTER(WHERE score<.5),count(*),node_id),array_agg(id ORDER BY hlc,id)
 FROM(SELECT learner_id,payload->>'nodeId' node_id,id,hlc,(payload->>'score')::double precision score,row_number() OVER(PARTITION BY learner_id,payload->>'nodeId' ORDER BY hlc DESC,id DESC) rn FROM prod.events WHERE type IN ('PracticeAttempt','AssessmentItemAnswered')) recent
 WHERE rn<=14 GROUP BY learner_id,node_id HAVING count(*)>=6 AND count(*) FILTER(WHERE score<.5)::double precision/count(*)>=.6
 ON CONFLICT(learner_id,node_id) WHERE status='open' DO NOTHING;
END $$;
CREATE FUNCTION prod.refresh_class_snapshots() RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 INSERT INTO prod.class_snapshot(class_id,day,body)
 SELECT c.id,current_date,jsonb_build_object('activeLearners',count(DISTINCT e.learner_id),'observations',coalesce(sum(s.n_obs),0),'meanMastery',avg(s.p_learned))
 FROM prod.classes c LEFT JOIN prod.enrollments e ON e.class_id=c.id AND e.status='active' LEFT JOIN prod.learner_node_state s ON s.learner_id=e.learner_id GROUP BY c.id
 ON CONFLICT(class_id,day) DO UPDATE SET body=excluded.body
$$;

-- Every application table is default-deny. RPCs are the only mutation surface.
DO $$ DECLARE r record;BEGIN FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='prod' LOOP EXECUTE format('ALTER TABLE prod.%I ENABLE ROW LEVEL SECURITY',r.tablename);END LOOP;END $$;
CREATE POLICY teacher_self ON prod.teachers FOR SELECT TO authenticated USING(id=auth.uid());
CREATE POLICY assigned_classes ON prod.classes FOR SELECT TO authenticated USING(prod.teacher_has_class(id));
CREATE POLICY own_assignments ON prod.teacher_assignments FOR SELECT TO authenticated USING(teacher_id=auth.uid());
CREATE POLICY assigned_enrollments ON prod.enrollments FOR SELECT TO authenticated USING(prod.teacher_has_class(class_id) OR prod.owns_learner(learner_id));
CREATE POLICY assigned_learners ON prod.learners FOR SELECT TO authenticated USING(prod.can_read_learner(id));
CREATE POLICY own_devices ON prod.devices FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY own_bindings ON prod.device_learners FOR SELECT TO authenticated USING(prod.owns_learner(learner_id));
CREATE POLICY learner_events ON prod.events FOR SELECT TO authenticated USING(prod.can_read_learner(learner_id));
CREATE POLICY learner_mastery ON prod.learner_node_state FOR SELECT TO authenticated USING(prod.can_read_learner(learner_id));
CREATE POLICY learner_daily ON prod.learner_daily FOR SELECT TO authenticated USING(prod.can_read_learner(learner_id));
CREATE POLICY class_summary ON prod.class_snapshot FOR SELECT TO authenticated USING(prod.teacher_has_class(class_id));
CREATE POLICY learner_insights ON prod.insights FOR SELECT TO authenticated USING(prod.can_read_learner(learner_id));
CREATE POLICY learner_interventions ON prod.interventions FOR SELECT TO authenticated USING(prod.can_read_learner(learner_id));
CREATE POLICY own_consents ON prod.consents FOR SELECT TO authenticated USING(prod.owns_learner(learner_id));
CREATE POLICY erasure_delivery ON prod.erasure_targets FOR SELECT TO authenticated USING(user_id=auth.uid());
CREATE POLICY content_published ON prod.content_packs FOR SELECT TO authenticated USING(enabled AND channel='production');
CREATE POLICY model_published ON prod.model_packs FOR SELECT TO authenticated USING(enabled AND channel='production');
CREATE POLICY skill_catalog ON prod.skill_nodes FOR SELECT TO authenticated USING(true);
REVOKE ALL ON ALL TABLES IN SCHEMA prod FROM anon,authenticated;
GRANT SELECT ON prod.teachers,prod.classes,prod.teacher_assignments,prod.enrollments,prod.learners,prod.devices,prod.device_learners,prod.events,prod.learner_node_state,prod.learner_daily,prod.class_snapshot,prod.insights,prod.interventions,prod.consents,prod.erasure_targets,prod.content_packs,prod.model_packs,prod.skill_nodes TO authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA prod FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION prod.teacher_has_class(uuid),prod.can_read_learner(text),prod.owns_learner(text),prod.ingest_events(jsonb),prod.erase_learner(text),prod.export_learner(text),prod.teacher_intervene(text,uuid,text,text,uuid) TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA prod TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA prod TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA prod TO service_role;

INSERT INTO prod.skill_nodes(id,skill) VALUES
('vocabulary.frequent_500','vocabulary'),
('vocabulary.people','vocabulary'),
('vocabulary.places','vocabulary'),
('vocabulary.actions','vocabulary'),
('vocabulary.describing','vocabulary'),
('vocabulary.time','vocabulary'),
('vocabulary.context','vocabulary'),
('vocabulary.collocations','vocabulary'),
('vocabulary.word_families','vocabulary'),
('vocabulary.academic','vocabulary'),
('grammar.simple_present_agreement','grammar'),
('grammar.articles','grammar'),
('grammar.pronouns','grammar'),
('grammar.plurals','grammar'),
('grammar.prepositions','grammar'),
('grammar.regular_past','grammar'),
('grammar.irregular_past','grammar'),
('grammar.progressive','grammar'),
('grammar.modals','grammar'),
('grammar.complex','grammar'),
('sentence.simple','sentence'),
('sentence.questions','sentence'),
('sentence.negatives','sentence'),
('sentence.descriptions','sentence'),
('sentence.past_narration','sentence'),
('sentence.future','sentence'),
('sentence.joining','sentence'),
('sentence.ordering','sentence'),
('sentence.paragraphs','sentence'),
('sentence.arguments','sentence'),
('reading.letters','reading'),
('reading.words','reading'),
('reading.phrases','reading'),
('reading.a1','reading'),
('reading.a2','reading'),
('reading.punctuation','reading'),
('reading.detail','reading'),
('reading.inference','reading'),
('reading.b1','reading'),
('reading.b2','reading'),
('pronunciation.v_w','pronunciation'),
('pronunciation.th','pronunciation'),
('pronunciation.vowels','pronunciation'),
('pronunciation.final_consonants','pronunciation'),
('pronunciation.clusters','pronunciation'),
('pronunciation.syllables','pronunciation'),
('pronunciation.word_stress','pronunciation'),
('pronunciation.sentence_stress','pronunciation'),
('pronunciation.linking','pronunciation'),
('pronunciation.intonation','pronunciation'),
('listening.sounds','listening'),
('listening.words','listening'),
('listening.instructions','listening'),
('listening.details','listening'),
('listening.sequence','listening'),
('listening.gist','listening'),
('listening.questions','listening'),
('listening.conversation','listening'),
('listening.inference','listening'),
('listening.lectures','listening'),
('speaking.greetings','speaking'),
('speaking.introductions','speaking'),
('speaking.picture','speaking'),
('speaking.routine','speaking'),
('speaking.past','speaking'),
('speaking.requests','speaking'),
('speaking.opinions','speaking'),
('speaking.conversation','speaking'),
('speaking.presentation','speaking'),
('speaking.discussion','speaking');
