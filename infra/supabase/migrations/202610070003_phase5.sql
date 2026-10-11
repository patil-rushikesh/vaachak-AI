-- Phase 5: classroom classification, teacher voice recordings and practice assignments.
-- Additive only. Every table is default-deny; RPCs are the only mutation surface.

-- ---------------------------------------------------------------------------
-- 1. Classification: standard (grade), section, pincode, state, district, language.
--    Stored on the school (org) and the class. Learners inherit it through their
--    class; no learner-level location is collected (data minimisation).
-- ---------------------------------------------------------------------------
ALTER TABLE dev.orgs
 ADD COLUMN pincode text CHECK(pincode IS NULL OR pincode ~ '^[1-9][0-9]{5}$'),
 ADD COLUMN state text CHECK(state IS NULL OR length(trim(state)) BETWEEN 2 AND 60),
 ADD COLUMN district text CHECK(district IS NULL OR length(trim(district)) BETWEEN 2 AND 60),
 ADD COLUMN primary_language text CHECK(primary_language IS NULL OR primary_language ~ '^[a-z]{2,3}$');
ALTER TABLE dev.classes
 ADD COLUMN standard text CHECK(standard IS NULL OR standard IN ('KG','1','2','3','4','5','6','7','8','9','10','11','12','adult')),
 ADD COLUMN section text CHECK(section IS NULL OR length(trim(section)) BETWEEN 1 AND 8),
 ADD COLUMN pincode text CHECK(pincode IS NULL OR pincode ~ '^[1-9][0-9]{5}$'),
 ADD COLUMN state text CHECK(state IS NULL OR length(trim(state)) BETWEEN 2 AND 60),
 ADD COLUMN district text CHECK(district IS NULL OR length(trim(district)) BETWEEN 2 AND 60),
 ADD COLUMN instruction_language text CHECK(instruction_language IS NULL OR instruction_language ~ '^[a-z]{2,3}$'),
 ADD COLUMN academic_year text CHECK(academic_year IS NULL OR academic_year ~ '^20[0-9]{2}-[0-9]{2}$');
CREATE INDEX ON dev.classes(org_id,standard);
CREATE INDEX ON dev.classes(pincode);

CREATE FUNCTION dev.create_class(class_name text,class_standard text,class_section text,class_pincode text,class_state text,class_district text,class_language text,class_year text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE org uuid; result uuid;
BEGIN
 SELECT org_id INTO org FROM dev.teachers WHERE id=auth.uid();
 IF org IS NULL THEN RAISE EXCEPTION 'Teacher required' USING ERRCODE='42501';END IF;
 IF class_name IS NULL OR length(trim(class_name)) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION 'Class name required';END IF;
 IF (SELECT count(*) FROM dev.teacher_assignments WHERE teacher_id=auth.uid() AND to_at IS NULL)>=50 THEN RAISE EXCEPTION 'Class limit reached';END IF;
 INSERT INTO dev.classes(org_id,name,standard,section,pincode,state,district,instruction_language,academic_year)
 VALUES(org,trim(class_name),class_standard,nullif(trim(class_section),''),class_pincode,nullif(trim(class_state),''),nullif(trim(class_district),''),class_language,class_year) RETURNING id INTO result;
 INSERT INTO dev.teacher_assignments(class_id,teacher_id) VALUES(result,auth.uid());
 INSERT INTO dev.audit_log(actor,action,target_hash) VALUES(auth.uid(),'class:create',encode(extensions.digest(result::text,'sha256'),'hex'));
 RETURN result;
END $$;

CREATE FUNCTION dev.update_class_classification(target_class uuid,class_standard text,class_section text,class_pincode text,class_state text,class_district text,class_language text,class_year text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT dev.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 UPDATE dev.classes SET standard=class_standard,section=nullif(trim(class_section),''),pincode=class_pincode,state=nullif(trim(class_state),''),district=nullif(trim(class_district),''),instruction_language=class_language,academic_year=class_year WHERE id=target_class;
 INSERT INTO dev.audit_log(actor,action,target_hash) VALUES(auth.uid(),'class:classify',encode(extensions.digest(target_class::text,'sha256'),'hex'));
END $$;

-- ---------------------------------------------------------------------------
-- 2. Teacher voice recordings and assignments to a whole class or one learner.
--    Audio bytes live in private object storage; the database holds metadata.
-- ---------------------------------------------------------------------------
CREATE TABLE dev.lesson_recordings(
 id uuid PRIMARY KEY,
 org_id uuid NOT NULL REFERENCES dev.orgs(id),
 teacher_id uuid NOT NULL REFERENCES dev.teachers(id),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 language text NOT NULL CHECK(language ~ '^[a-z]{2,3}$'),
 duration_ms integer NOT NULL CHECK(duration_ms BETWEEN 1000 AND 600000),
 size_bytes bigint NOT NULL CHECK(size_bytes BETWEEN 1 AND 20971520),
 mime text NOT NULL CHECK(mime IN ('audio/mp4','audio/aac','audio/ogg','audio/webm','audio/mpeg','audio/wav')),
 storage_path text NOT NULL UNIQUE CHECK(storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.[a-z0-9]{2,4}$'),
 sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),
 deleted_at timestamptz
);
CREATE INDEX ON dev.lesson_recordings(teacher_id,created_at DESC);
CREATE TABLE dev.practice_assignments(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 class_id uuid NOT NULL REFERENCES dev.classes(id) ON DELETE CASCADE,
 learner_id text REFERENCES dev.learners(id) ON DELETE CASCADE, -- NULL = whole class
 teacher_id uuid NOT NULL REFERENCES dev.teachers(id),
 recording_id uuid NOT NULL REFERENCES dev.lesson_recordings(id),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 instructions text CHECK(instructions IS NULL OR length(instructions)<=500),
 due_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 revoked_at timestamptz,
 delivery_seq bigint GENERATED ALWAYS AS IDENTITY UNIQUE
);
CREATE INDEX ON dev.practice_assignments(class_id,created_at DESC);
CREATE INDEX ON dev.practice_assignments(learner_id);

ALTER TABLE dev.lesson_recordings ENABLE ROW LEVEL SECURITY;
ALTER TABLE dev.practice_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_recordings ON dev.lesson_recordings FOR SELECT TO authenticated USING(teacher_id=auth.uid() AND deleted_at IS NULL);
CREATE POLICY class_assignments ON dev.practice_assignments FOR SELECT TO authenticated USING(dev.teacher_has_class(class_id));
REVOKE ALL ON dev.lesson_recordings,dev.practice_assignments FROM PUBLIC,anon,authenticated;
GRANT SELECT ON dev.lesson_recordings,dev.practice_assignments TO authenticated;
GRANT ALL ON dev.lesson_recordings,dev.practice_assignments TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA dev TO service_role;

-- Called after the client has uploaded audio to <teacher id>/<recording id>.<ext>.
CREATE FUNCTION dev.register_recording(recording_id uuid,recording_title text,recording_language text,recording_duration_ms integer,recording_size_bytes bigint,recording_mime text,recording_sha256 text,recording_ext text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE org uuid;
BEGIN
 SELECT org_id INTO org FROM dev.teachers WHERE id=auth.uid();
 IF org IS NULL THEN RAISE EXCEPTION 'Teacher required' USING ERRCODE='42501';END IF;
 IF recording_ext IS NULL OR recording_ext !~ '^[a-z0-9]{2,4}$' THEN RAISE EXCEPTION 'Invalid file extension';END IF;
 IF (SELECT count(*) FROM dev.lesson_recordings WHERE teacher_id=auth.uid() AND created_at>now()-interval '1 hour')>=60 THEN RAISE EXCEPTION 'Too many recordings. Try again later.';END IF;
 INSERT INTO dev.lesson_recordings(id,org_id,teacher_id,title,language,duration_ms,size_bytes,mime,storage_path,sha256)
 VALUES(recording_id,org,auth.uid(),trim(recording_title),recording_language,recording_duration_ms,recording_size_bytes,recording_mime,auth.uid()::text||'/'||recording_id::text||'.'||recording_ext,recording_sha256);
 INSERT INTO dev.audit_log(actor,action,target_hash) VALUES(auth.uid(),'recording:create',encode(extensions.digest(recording_id::text,'sha256'),'hex'));
 RETURN recording_id;
END $$;

CREATE FUNCTION dev.delete_recording(target_recording uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 UPDATE dev.lesson_recordings SET deleted_at=now() WHERE id=target_recording AND teacher_id=auth.uid() AND deleted_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Recording not found' USING ERRCODE='42501';END IF;
 UPDATE dev.practice_assignments SET revoked_at=now() WHERE recording_id=target_recording AND revoked_at IS NULL;
 INSERT INTO dev.audit_log(actor,action,target_hash) VALUES(auth.uid(),'recording:delete',encode(extensions.digest(target_recording::text,'sha256'),'hex'));
END $$;

-- target_learner NULL assigns to every active learner in the class.
CREATE FUNCTION dev.assign_recording(target_class uuid,target_recording uuid,assignment_title text,assignment_instructions text DEFAULT NULL,assignment_due timestamptz DEFAULT NULL,target_learner text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT dev.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM dev.lesson_recordings WHERE id=target_recording AND teacher_id=auth.uid() AND deleted_at IS NULL) THEN RAISE EXCEPTION 'Recording not found' USING ERRCODE='42501';END IF;
 IF target_learner IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dev.enrollments WHERE class_id=target_class AND learner_id=target_learner AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF assignment_due IS NOT NULL AND assignment_due<now() THEN RAISE EXCEPTION 'Due date is in the past';END IF;
 INSERT INTO dev.practice_assignments(class_id,learner_id,teacher_id,recording_id,title,instructions,due_at)
 VALUES(target_class,target_learner,auth.uid(),target_recording,trim(assignment_title),assignment_instructions,assignment_due) RETURNING id INTO result;
 INSERT INTO dev.audit_log(actor,action,target_hash) VALUES(auth.uid(),'assignment:'||CASE WHEN target_learner IS NULL THEN 'class' ELSE 'learner' END,encode(extensions.digest(result::text,'sha256'),'hex'));
 RETURN result;
END $$;

CREATE FUNCTION dev.revoke_assignment(target_assignment uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 UPDATE dev.practice_assignments a SET revoked_at=now() WHERE a.id=target_assignment AND a.revoked_at IS NULL AND dev.teacher_has_class(a.class_id);
 IF NOT FOUND THEN RAISE EXCEPTION 'Assignment not found' USING ERRCODE='42501';END IF;
END $$;

-- Learner side: only assignments for learners owned by this device, in classes that
-- have approved them, with core + serverSync consent. Never lists other learners.
CREATE FUNCTION dev.my_practice_assignments() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(x.item ORDER BY x.created_at DESC),'[]'::jsonb) FROM (
  SELECT DISTINCT ON (a.id,e.learner_id) a.created_at,jsonb_build_object(
   'id',a.id,'classId',a.class_id,'className',c.name,'learnerId',e.learner_id,'scope',CASE WHEN a.learner_id IS NULL THEN 'class' ELSE 'learner' END,
   'title',a.title,'instructions',a.instructions,'dueAt',a.due_at,'createdAt',a.created_at,
   'recording',jsonb_build_object('id',r.id,'language',r.language,'durationMs',r.duration_ms,'mime',r.mime,'sizeBytes',r.size_bytes,'sha256',r.sha256,'path',r.storage_path)) item
  FROM dev.enrollments e
  JOIN dev.classes c ON c.id=e.class_id
  JOIN dev.practice_assignments a ON a.class_id=e.class_id AND (a.learner_id IS NULL OR a.learner_id=e.learner_id)
  JOIN dev.lesson_recordings r ON r.id=a.recording_id AND r.deleted_at IS NULL
  WHERE e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now())
   AND a.revoked_at IS NULL AND dev.owns_learner(e.learner_id)
   AND dev.has_consent(e.learner_id,'core') AND dev.has_consent(e.learner_id,'serverSync')
  ORDER BY a.id,e.learner_id LIMIT 200) x
$$;

-- Storage access check, reused by the object-storage policies below.
CREATE FUNCTION dev.can_play_recording(object_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM dev.lesson_recordings r WHERE r.storage_path=object_path AND r.deleted_at IS NULL AND (r.teacher_id=auth.uid() OR EXISTS(
  SELECT 1 FROM dev.practice_assignments a JOIN dev.enrollments e ON e.class_id=a.class_id AND (a.learner_id IS NULL OR a.learner_id=e.learner_id)
  WHERE a.recording_id=r.id AND a.revoked_at IS NULL AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now())
   AND dev.owns_learner(e.learner_id) AND dev.has_consent(e.learner_id,'core') AND dev.has_consent(e.learner_id,'serverSync'))))
$$;

REVOKE ALL ON FUNCTION dev.create_class(text,text,text,text,text,text,text,text),dev.update_class_classification(uuid,text,text,text,text,text,text,text),dev.register_recording(uuid,text,text,integer,bigint,text,text,text),dev.delete_recording(uuid),dev.assign_recording(uuid,uuid,text,text,timestamptz,text),dev.revoke_assignment(uuid),dev.my_practice_assignments(),dev.can_play_recording(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION dev.create_class(text,text,text,text,text,text,text,text),dev.update_class_classification(uuid,text,text,text,text,text,text,text),dev.register_recording(uuid,text,text,integer,bigint,text,text,text),dev.delete_recording(uuid),dev.assign_recording(uuid,uuid,text,text,timestamptz,text),dev.revoke_assignment(uuid),dev.my_practice_assignments(),dev.can_play_recording(text) TO authenticated;

-- Private object storage. Skipped on plain Postgres (CI); applied on Supabase.
DO $storage$ BEGIN
 IF to_regclass('storage.objects') IS NOT NULL THEN
  INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  VALUES('teacher-recordings-dev','teacher-recordings-dev',false,20971520,ARRAY['audio/mp4','audio/aac','audio/ogg','audio/webm','audio/mpeg','audio/wav']) ON CONFLICT(id) DO NOTHING;
  CREATE POLICY "dev_recordings_upload" ON storage.objects FOR INSERT TO authenticated
   WITH CHECK(bucket_id='teacher-recordings-dev' AND (storage.foldername(name))[1]=auth.uid()::text AND EXISTS(SELECT 1 FROM dev.teachers t WHERE t.id=auth.uid()));
  CREATE POLICY "dev_recordings_read" ON storage.objects FOR SELECT TO authenticated
   USING(bucket_id='teacher-recordings-dev' AND ((storage.foldername(name))[1]=auth.uid()::text OR dev.can_play_recording(name)));
 END IF;
END $storage$;

-- Phase 5: classroom classification, teacher voice recordings and practice assignments.
-- Additive only. Every table is default-deny; RPCs are the only mutation surface.

-- ---------------------------------------------------------------------------
-- 1. Classification: standard (grade), section, pincode, state, district, language.
--    Stored on the school (org) and the class. Learners inherit it through their
--    class; no learner-level location is collected (data minimisation).
-- ---------------------------------------------------------------------------
ALTER TABLE qa.orgs
 ADD COLUMN pincode text CHECK(pincode IS NULL OR pincode ~ '^[1-9][0-9]{5}$'),
 ADD COLUMN state text CHECK(state IS NULL OR length(trim(state)) BETWEEN 2 AND 60),
 ADD COLUMN district text CHECK(district IS NULL OR length(trim(district)) BETWEEN 2 AND 60),
 ADD COLUMN primary_language text CHECK(primary_language IS NULL OR primary_language ~ '^[a-z]{2,3}$');
ALTER TABLE qa.classes
 ADD COLUMN standard text CHECK(standard IS NULL OR standard IN ('KG','1','2','3','4','5','6','7','8','9','10','11','12','adult')),
 ADD COLUMN section text CHECK(section IS NULL OR length(trim(section)) BETWEEN 1 AND 8),
 ADD COLUMN pincode text CHECK(pincode IS NULL OR pincode ~ '^[1-9][0-9]{5}$'),
 ADD COLUMN state text CHECK(state IS NULL OR length(trim(state)) BETWEEN 2 AND 60),
 ADD COLUMN district text CHECK(district IS NULL OR length(trim(district)) BETWEEN 2 AND 60),
 ADD COLUMN instruction_language text CHECK(instruction_language IS NULL OR instruction_language ~ '^[a-z]{2,3}$'),
 ADD COLUMN academic_year text CHECK(academic_year IS NULL OR academic_year ~ '^20[0-9]{2}-[0-9]{2}$');
CREATE INDEX ON qa.classes(org_id,standard);
CREATE INDEX ON qa.classes(pincode);

CREATE FUNCTION qa.create_class(class_name text,class_standard text,class_section text,class_pincode text,class_state text,class_district text,class_language text,class_year text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE org uuid; result uuid;
BEGIN
 SELECT org_id INTO org FROM qa.teachers WHERE id=auth.uid();
 IF org IS NULL THEN RAISE EXCEPTION 'Teacher required' USING ERRCODE='42501';END IF;
 IF class_name IS NULL OR length(trim(class_name)) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION 'Class name required';END IF;
 IF (SELECT count(*) FROM qa.teacher_assignments WHERE teacher_id=auth.uid() AND to_at IS NULL)>=50 THEN RAISE EXCEPTION 'Class limit reached';END IF;
 INSERT INTO qa.classes(org_id,name,standard,section,pincode,state,district,instruction_language,academic_year)
 VALUES(org,trim(class_name),class_standard,nullif(trim(class_section),''),class_pincode,nullif(trim(class_state),''),nullif(trim(class_district),''),class_language,class_year) RETURNING id INTO result;
 INSERT INTO qa.teacher_assignments(class_id,teacher_id) VALUES(result,auth.uid());
 INSERT INTO qa.audit_log(actor,action,target_hash) VALUES(auth.uid(),'class:create',encode(extensions.digest(result::text,'sha256'),'hex'));
 RETURN result;
END $$;

CREATE FUNCTION qa.update_class_classification(target_class uuid,class_standard text,class_section text,class_pincode text,class_state text,class_district text,class_language text,class_year text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT qa.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 UPDATE qa.classes SET standard=class_standard,section=nullif(trim(class_section),''),pincode=class_pincode,state=nullif(trim(class_state),''),district=nullif(trim(class_district),''),instruction_language=class_language,academic_year=class_year WHERE id=target_class;
 INSERT INTO qa.audit_log(actor,action,target_hash) VALUES(auth.uid(),'class:classify',encode(extensions.digest(target_class::text,'sha256'),'hex'));
END $$;

-- ---------------------------------------------------------------------------
-- 2. Teacher voice recordings and assignments to a whole class or one learner.
--    Audio bytes live in private object storage; the database holds metadata.
-- ---------------------------------------------------------------------------
CREATE TABLE qa.lesson_recordings(
 id uuid PRIMARY KEY,
 org_id uuid NOT NULL REFERENCES qa.orgs(id),
 teacher_id uuid NOT NULL REFERENCES qa.teachers(id),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 language text NOT NULL CHECK(language ~ '^[a-z]{2,3}$'),
 duration_ms integer NOT NULL CHECK(duration_ms BETWEEN 1000 AND 600000),
 size_bytes bigint NOT NULL CHECK(size_bytes BETWEEN 1 AND 20971520),
 mime text NOT NULL CHECK(mime IN ('audio/mp4','audio/aac','audio/ogg','audio/webm','audio/mpeg','audio/wav')),
 storage_path text NOT NULL UNIQUE CHECK(storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.[a-z0-9]{2,4}$'),
 sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),
 deleted_at timestamptz
);
CREATE INDEX ON qa.lesson_recordings(teacher_id,created_at DESC);
CREATE TABLE qa.practice_assignments(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 class_id uuid NOT NULL REFERENCES qa.classes(id) ON DELETE CASCADE,
 learner_id text REFERENCES qa.learners(id) ON DELETE CASCADE, -- NULL = whole class
 teacher_id uuid NOT NULL REFERENCES qa.teachers(id),
 recording_id uuid NOT NULL REFERENCES qa.lesson_recordings(id),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 instructions text CHECK(instructions IS NULL OR length(instructions)<=500),
 due_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 revoked_at timestamptz,
 delivery_seq bigint GENERATED ALWAYS AS IDENTITY UNIQUE
);
CREATE INDEX ON qa.practice_assignments(class_id,created_at DESC);
CREATE INDEX ON qa.practice_assignments(learner_id);

ALTER TABLE qa.lesson_recordings ENABLE ROW LEVEL SECURITY;
ALTER TABLE qa.practice_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_recordings ON qa.lesson_recordings FOR SELECT TO authenticated USING(teacher_id=auth.uid() AND deleted_at IS NULL);
CREATE POLICY class_assignments ON qa.practice_assignments FOR SELECT TO authenticated USING(qa.teacher_has_class(class_id));
REVOKE ALL ON qa.lesson_recordings,qa.practice_assignments FROM PUBLIC,anon,authenticated;
GRANT SELECT ON qa.lesson_recordings,qa.practice_assignments TO authenticated;
GRANT ALL ON qa.lesson_recordings,qa.practice_assignments TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA qa TO service_role;

-- Called after the client has uploaded audio to <teacher id>/<recording id>.<ext>.
CREATE FUNCTION qa.register_recording(recording_id uuid,recording_title text,recording_language text,recording_duration_ms integer,recording_size_bytes bigint,recording_mime text,recording_sha256 text,recording_ext text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE org uuid;
BEGIN
 SELECT org_id INTO org FROM qa.teachers WHERE id=auth.uid();
 IF org IS NULL THEN RAISE EXCEPTION 'Teacher required' USING ERRCODE='42501';END IF;
 IF recording_ext IS NULL OR recording_ext !~ '^[a-z0-9]{2,4}$' THEN RAISE EXCEPTION 'Invalid file extension';END IF;
 IF (SELECT count(*) FROM qa.lesson_recordings WHERE teacher_id=auth.uid() AND created_at>now()-interval '1 hour')>=60 THEN RAISE EXCEPTION 'Too many recordings. Try again later.';END IF;
 INSERT INTO qa.lesson_recordings(id,org_id,teacher_id,title,language,duration_ms,size_bytes,mime,storage_path,sha256)
 VALUES(recording_id,org,auth.uid(),trim(recording_title),recording_language,recording_duration_ms,recording_size_bytes,recording_mime,auth.uid()::text||'/'||recording_id::text||'.'||recording_ext,recording_sha256);
 INSERT INTO qa.audit_log(actor,action,target_hash) VALUES(auth.uid(),'recording:create',encode(extensions.digest(recording_id::text,'sha256'),'hex'));
 RETURN recording_id;
END $$;

CREATE FUNCTION qa.delete_recording(target_recording uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 UPDATE qa.lesson_recordings SET deleted_at=now() WHERE id=target_recording AND teacher_id=auth.uid() AND deleted_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Recording not found' USING ERRCODE='42501';END IF;
 UPDATE qa.practice_assignments SET revoked_at=now() WHERE recording_id=target_recording AND revoked_at IS NULL;
 INSERT INTO qa.audit_log(actor,action,target_hash) VALUES(auth.uid(),'recording:delete',encode(extensions.digest(target_recording::text,'sha256'),'hex'));
END $$;

-- target_learner NULL assigns to every active learner in the class.
CREATE FUNCTION qa.assign_recording(target_class uuid,target_recording uuid,assignment_title text,assignment_instructions text DEFAULT NULL,assignment_due timestamptz DEFAULT NULL,target_learner text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT qa.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM qa.lesson_recordings WHERE id=target_recording AND teacher_id=auth.uid() AND deleted_at IS NULL) THEN RAISE EXCEPTION 'Recording not found' USING ERRCODE='42501';END IF;
 IF target_learner IS NOT NULL AND NOT EXISTS(SELECT 1 FROM qa.enrollments WHERE class_id=target_class AND learner_id=target_learner AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF assignment_due IS NOT NULL AND assignment_due<now() THEN RAISE EXCEPTION 'Due date is in the past';END IF;
 INSERT INTO qa.practice_assignments(class_id,learner_id,teacher_id,recording_id,title,instructions,due_at)
 VALUES(target_class,target_learner,auth.uid(),target_recording,trim(assignment_title),assignment_instructions,assignment_due) RETURNING id INTO result;
 INSERT INTO qa.audit_log(actor,action,target_hash) VALUES(auth.uid(),'assignment:'||CASE WHEN target_learner IS NULL THEN 'class' ELSE 'learner' END,encode(extensions.digest(result::text,'sha256'),'hex'));
 RETURN result;
END $$;

CREATE FUNCTION qa.revoke_assignment(target_assignment uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 UPDATE qa.practice_assignments a SET revoked_at=now() WHERE a.id=target_assignment AND a.revoked_at IS NULL AND qa.teacher_has_class(a.class_id);
 IF NOT FOUND THEN RAISE EXCEPTION 'Assignment not found' USING ERRCODE='42501';END IF;
END $$;

-- Learner side: only assignments for learners owned by this device, in classes that
-- have approved them, with core + serverSync consent. Never lists other learners.
CREATE FUNCTION qa.my_practice_assignments() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(x.item ORDER BY x.created_at DESC),'[]'::jsonb) FROM (
  SELECT DISTINCT ON (a.id,e.learner_id) a.created_at,jsonb_build_object(
   'id',a.id,'classId',a.class_id,'className',c.name,'learnerId',e.learner_id,'scope',CASE WHEN a.learner_id IS NULL THEN 'class' ELSE 'learner' END,
   'title',a.title,'instructions',a.instructions,'dueAt',a.due_at,'createdAt',a.created_at,
   'recording',jsonb_build_object('id',r.id,'language',r.language,'durationMs',r.duration_ms,'mime',r.mime,'sizeBytes',r.size_bytes,'sha256',r.sha256,'path',r.storage_path)) item
  FROM qa.enrollments e
  JOIN qa.classes c ON c.id=e.class_id
  JOIN qa.practice_assignments a ON a.class_id=e.class_id AND (a.learner_id IS NULL OR a.learner_id=e.learner_id)
  JOIN qa.lesson_recordings r ON r.id=a.recording_id AND r.deleted_at IS NULL
  WHERE e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now())
   AND a.revoked_at IS NULL AND qa.owns_learner(e.learner_id)
   AND qa.has_consent(e.learner_id,'core') AND qa.has_consent(e.learner_id,'serverSync')
  ORDER BY a.id,e.learner_id LIMIT 200) x
$$;

-- Storage access check, reused by the object-storage policies below.
CREATE FUNCTION qa.can_play_recording(object_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM qa.lesson_recordings r WHERE r.storage_path=object_path AND r.deleted_at IS NULL AND (r.teacher_id=auth.uid() OR EXISTS(
  SELECT 1 FROM qa.practice_assignments a JOIN qa.enrollments e ON e.class_id=a.class_id AND (a.learner_id IS NULL OR a.learner_id=e.learner_id)
  WHERE a.recording_id=r.id AND a.revoked_at IS NULL AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now())
   AND qa.owns_learner(e.learner_id) AND qa.has_consent(e.learner_id,'core') AND qa.has_consent(e.learner_id,'serverSync'))))
$$;

REVOKE ALL ON FUNCTION qa.create_class(text,text,text,text,text,text,text,text),qa.update_class_classification(uuid,text,text,text,text,text,text,text),qa.register_recording(uuid,text,text,integer,bigint,text,text,text),qa.delete_recording(uuid),qa.assign_recording(uuid,uuid,text,text,timestamptz,text),qa.revoke_assignment(uuid),qa.my_practice_assignments(),qa.can_play_recording(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION qa.create_class(text,text,text,text,text,text,text,text),qa.update_class_classification(uuid,text,text,text,text,text,text,text),qa.register_recording(uuid,text,text,integer,bigint,text,text,text),qa.delete_recording(uuid),qa.assign_recording(uuid,uuid,text,text,timestamptz,text),qa.revoke_assignment(uuid),qa.my_practice_assignments(),qa.can_play_recording(text) TO authenticated;

-- Private object storage. Skipped on plain Postgres (CI); applied on Supabase.
DO $storage$ BEGIN
 IF to_regclass('storage.objects') IS NOT NULL THEN
  INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  VALUES('teacher-recordings-qa','teacher-recordings-qa',false,20971520,ARRAY['audio/mp4','audio/aac','audio/ogg','audio/webm','audio/mpeg','audio/wav']) ON CONFLICT(id) DO NOTHING;
  CREATE POLICY "qa_recordings_upload" ON storage.objects FOR INSERT TO authenticated
   WITH CHECK(bucket_id='teacher-recordings-qa' AND (storage.foldername(name))[1]=auth.uid()::text AND EXISTS(SELECT 1 FROM qa.teachers t WHERE t.id=auth.uid()));
  CREATE POLICY "qa_recordings_read" ON storage.objects FOR SELECT TO authenticated
   USING(bucket_id='teacher-recordings-qa' AND ((storage.foldername(name))[1]=auth.uid()::text OR qa.can_play_recording(name)));
 END IF;
END $storage$;

-- Phase 5: classroom classification, teacher voice recordings and practice assignments.
-- Additive only. Every table is default-deny; RPCs are the only mutation surface.

-- ---------------------------------------------------------------------------
-- 1. Classification: standard (grade), section, pincode, state, district, language.
--    Stored on the school (org) and the class. Learners inherit it through their
--    class; no learner-level location is collected (data minimisation).
-- ---------------------------------------------------------------------------
ALTER TABLE prod.orgs
 ADD COLUMN pincode text CHECK(pincode IS NULL OR pincode ~ '^[1-9][0-9]{5}$'),
 ADD COLUMN state text CHECK(state IS NULL OR length(trim(state)) BETWEEN 2 AND 60),
 ADD COLUMN district text CHECK(district IS NULL OR length(trim(district)) BETWEEN 2 AND 60),
 ADD COLUMN primary_language text CHECK(primary_language IS NULL OR primary_language ~ '^[a-z]{2,3}$');
ALTER TABLE prod.classes
 ADD COLUMN standard text CHECK(standard IS NULL OR standard IN ('KG','1','2','3','4','5','6','7','8','9','10','11','12','adult')),
 ADD COLUMN section text CHECK(section IS NULL OR length(trim(section)) BETWEEN 1 AND 8),
 ADD COLUMN pincode text CHECK(pincode IS NULL OR pincode ~ '^[1-9][0-9]{5}$'),
 ADD COLUMN state text CHECK(state IS NULL OR length(trim(state)) BETWEEN 2 AND 60),
 ADD COLUMN district text CHECK(district IS NULL OR length(trim(district)) BETWEEN 2 AND 60),
 ADD COLUMN instruction_language text CHECK(instruction_language IS NULL OR instruction_language ~ '^[a-z]{2,3}$'),
 ADD COLUMN academic_year text CHECK(academic_year IS NULL OR academic_year ~ '^20[0-9]{2}-[0-9]{2}$');
CREATE INDEX ON prod.classes(org_id,standard);
CREATE INDEX ON prod.classes(pincode);

CREATE FUNCTION prod.create_class(class_name text,class_standard text,class_section text,class_pincode text,class_state text,class_district text,class_language text,class_year text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE org uuid; result uuid;
BEGIN
 SELECT org_id INTO org FROM prod.teachers WHERE id=auth.uid();
 IF org IS NULL THEN RAISE EXCEPTION 'Teacher required' USING ERRCODE='42501';END IF;
 IF class_name IS NULL OR length(trim(class_name)) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION 'Class name required';END IF;
 IF (SELECT count(*) FROM prod.teacher_assignments WHERE teacher_id=auth.uid() AND to_at IS NULL)>=50 THEN RAISE EXCEPTION 'Class limit reached';END IF;
 INSERT INTO prod.classes(org_id,name,standard,section,pincode,state,district,instruction_language,academic_year)
 VALUES(org,trim(class_name),class_standard,nullif(trim(class_section),''),class_pincode,nullif(trim(class_state),''),nullif(trim(class_district),''),class_language,class_year) RETURNING id INTO result;
 INSERT INTO prod.teacher_assignments(class_id,teacher_id) VALUES(result,auth.uid());
 INSERT INTO prod.audit_log(actor,action,target_hash) VALUES(auth.uid(),'class:create',encode(extensions.digest(result::text,'sha256'),'hex'));
 RETURN result;
END $$;

CREATE FUNCTION prod.update_class_classification(target_class uuid,class_standard text,class_section text,class_pincode text,class_state text,class_district text,class_language text,class_year text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT prod.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 UPDATE prod.classes SET standard=class_standard,section=nullif(trim(class_section),''),pincode=class_pincode,state=nullif(trim(class_state),''),district=nullif(trim(class_district),''),instruction_language=class_language,academic_year=class_year WHERE id=target_class;
 INSERT INTO prod.audit_log(actor,action,target_hash) VALUES(auth.uid(),'class:classify',encode(extensions.digest(target_class::text,'sha256'),'hex'));
END $$;

-- ---------------------------------------------------------------------------
-- 2. Teacher voice recordings and assignments to a whole class or one learner.
--    Audio bytes live in private object storage; the database holds metadata.
-- ---------------------------------------------------------------------------
CREATE TABLE prod.lesson_recordings(
 id uuid PRIMARY KEY,
 org_id uuid NOT NULL REFERENCES prod.orgs(id),
 teacher_id uuid NOT NULL REFERENCES prod.teachers(id),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 language text NOT NULL CHECK(language ~ '^[a-z]{2,3}$'),
 duration_ms integer NOT NULL CHECK(duration_ms BETWEEN 1000 AND 600000),
 size_bytes bigint NOT NULL CHECK(size_bytes BETWEEN 1 AND 20971520),
 mime text NOT NULL CHECK(mime IN ('audio/mp4','audio/aac','audio/ogg','audio/webm','audio/mpeg','audio/wav')),
 storage_path text NOT NULL UNIQUE CHECK(storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.[a-z0-9]{2,4}$'),
 sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),
 deleted_at timestamptz
);
CREATE INDEX ON prod.lesson_recordings(teacher_id,created_at DESC);
CREATE TABLE prod.practice_assignments(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 class_id uuid NOT NULL REFERENCES prod.classes(id) ON DELETE CASCADE,
 learner_id text REFERENCES prod.learners(id) ON DELETE CASCADE, -- NULL = whole class
 teacher_id uuid NOT NULL REFERENCES prod.teachers(id),
 recording_id uuid NOT NULL REFERENCES prod.lesson_recordings(id),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 instructions text CHECK(instructions IS NULL OR length(instructions)<=500),
 due_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 revoked_at timestamptz,
 delivery_seq bigint GENERATED ALWAYS AS IDENTITY UNIQUE
);
CREATE INDEX ON prod.practice_assignments(class_id,created_at DESC);
CREATE INDEX ON prod.practice_assignments(learner_id);

ALTER TABLE prod.lesson_recordings ENABLE ROW LEVEL SECURITY;
ALTER TABLE prod.practice_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_recordings ON prod.lesson_recordings FOR SELECT TO authenticated USING(teacher_id=auth.uid() AND deleted_at IS NULL);
CREATE POLICY class_assignments ON prod.practice_assignments FOR SELECT TO authenticated USING(prod.teacher_has_class(class_id));
REVOKE ALL ON prod.lesson_recordings,prod.practice_assignments FROM PUBLIC,anon,authenticated;
GRANT SELECT ON prod.lesson_recordings,prod.practice_assignments TO authenticated;
GRANT ALL ON prod.lesson_recordings,prod.practice_assignments TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA prod TO service_role;

-- Called after the client has uploaded audio to <teacher id>/<recording id>.<ext>.
CREATE FUNCTION prod.register_recording(recording_id uuid,recording_title text,recording_language text,recording_duration_ms integer,recording_size_bytes bigint,recording_mime text,recording_sha256 text,recording_ext text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE org uuid;
BEGIN
 SELECT org_id INTO org FROM prod.teachers WHERE id=auth.uid();
 IF org IS NULL THEN RAISE EXCEPTION 'Teacher required' USING ERRCODE='42501';END IF;
 IF recording_ext IS NULL OR recording_ext !~ '^[a-z0-9]{2,4}$' THEN RAISE EXCEPTION 'Invalid file extension';END IF;
 IF (SELECT count(*) FROM prod.lesson_recordings WHERE teacher_id=auth.uid() AND created_at>now()-interval '1 hour')>=60 THEN RAISE EXCEPTION 'Too many recordings. Try again later.';END IF;
 INSERT INTO prod.lesson_recordings(id,org_id,teacher_id,title,language,duration_ms,size_bytes,mime,storage_path,sha256)
 VALUES(recording_id,org,auth.uid(),trim(recording_title),recording_language,recording_duration_ms,recording_size_bytes,recording_mime,auth.uid()::text||'/'||recording_id::text||'.'||recording_ext,recording_sha256);
 INSERT INTO prod.audit_log(actor,action,target_hash) VALUES(auth.uid(),'recording:create',encode(extensions.digest(recording_id::text,'sha256'),'hex'));
 RETURN recording_id;
END $$;

CREATE FUNCTION prod.delete_recording(target_recording uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 UPDATE prod.lesson_recordings SET deleted_at=now() WHERE id=target_recording AND teacher_id=auth.uid() AND deleted_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Recording not found' USING ERRCODE='42501';END IF;
 UPDATE prod.practice_assignments SET revoked_at=now() WHERE recording_id=target_recording AND revoked_at IS NULL;
 INSERT INTO prod.audit_log(actor,action,target_hash) VALUES(auth.uid(),'recording:delete',encode(extensions.digest(target_recording::text,'sha256'),'hex'));
END $$;

-- target_learner NULL assigns to every active learner in the class.
CREATE FUNCTION prod.assign_recording(target_class uuid,target_recording uuid,assignment_title text,assignment_instructions text DEFAULT NULL,assignment_due timestamptz DEFAULT NULL,target_learner text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT prod.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM prod.lesson_recordings WHERE id=target_recording AND teacher_id=auth.uid() AND deleted_at IS NULL) THEN RAISE EXCEPTION 'Recording not found' USING ERRCODE='42501';END IF;
 IF target_learner IS NOT NULL AND NOT EXISTS(SELECT 1 FROM prod.enrollments WHERE class_id=target_class AND learner_id=target_learner AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF assignment_due IS NOT NULL AND assignment_due<now() THEN RAISE EXCEPTION 'Due date is in the past';END IF;
 INSERT INTO prod.practice_assignments(class_id,learner_id,teacher_id,recording_id,title,instructions,due_at)
 VALUES(target_class,target_learner,auth.uid(),target_recording,trim(assignment_title),assignment_instructions,assignment_due) RETURNING id INTO result;
 INSERT INTO prod.audit_log(actor,action,target_hash) VALUES(auth.uid(),'assignment:'||CASE WHEN target_learner IS NULL THEN 'class' ELSE 'learner' END,encode(extensions.digest(result::text,'sha256'),'hex'));
 RETURN result;
END $$;

CREATE FUNCTION prod.revoke_assignment(target_assignment uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 UPDATE prod.practice_assignments a SET revoked_at=now() WHERE a.id=target_assignment AND a.revoked_at IS NULL AND prod.teacher_has_class(a.class_id);
 IF NOT FOUND THEN RAISE EXCEPTION 'Assignment not found' USING ERRCODE='42501';END IF;
END $$;

-- Learner side: only assignments for learners owned by this device, in classes that
-- have approved them, with core + serverSync consent. Never lists other learners.
CREATE FUNCTION prod.my_practice_assignments() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(x.item ORDER BY x.created_at DESC),'[]'::jsonb) FROM (
  SELECT DISTINCT ON (a.id,e.learner_id) a.created_at,jsonb_build_object(
   'id',a.id,'classId',a.class_id,'className',c.name,'learnerId',e.learner_id,'scope',CASE WHEN a.learner_id IS NULL THEN 'class' ELSE 'learner' END,
   'title',a.title,'instructions',a.instructions,'dueAt',a.due_at,'createdAt',a.created_at,
   'recording',jsonb_build_object('id',r.id,'language',r.language,'durationMs',r.duration_ms,'mime',r.mime,'sizeBytes',r.size_bytes,'sha256',r.sha256,'path',r.storage_path)) item
  FROM prod.enrollments e
  JOIN prod.classes c ON c.id=e.class_id
  JOIN prod.practice_assignments a ON a.class_id=e.class_id AND (a.learner_id IS NULL OR a.learner_id=e.learner_id)
  JOIN prod.lesson_recordings r ON r.id=a.recording_id AND r.deleted_at IS NULL
  WHERE e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now())
   AND a.revoked_at IS NULL AND prod.owns_learner(e.learner_id)
   AND prod.has_consent(e.learner_id,'core') AND prod.has_consent(e.learner_id,'serverSync')
  ORDER BY a.id,e.learner_id LIMIT 200) x
$$;

-- Storage access check, reused by the object-storage policies below.
CREATE FUNCTION prod.can_play_recording(object_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM prod.lesson_recordings r WHERE r.storage_path=object_path AND r.deleted_at IS NULL AND (r.teacher_id=auth.uid() OR EXISTS(
  SELECT 1 FROM prod.practice_assignments a JOIN prod.enrollments e ON e.class_id=a.class_id AND (a.learner_id IS NULL OR a.learner_id=e.learner_id)
  WHERE a.recording_id=r.id AND a.revoked_at IS NULL AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now())
   AND prod.owns_learner(e.learner_id) AND prod.has_consent(e.learner_id,'core') AND prod.has_consent(e.learner_id,'serverSync'))))
$$;

REVOKE ALL ON FUNCTION prod.create_class(text,text,text,text,text,text,text,text),prod.update_class_classification(uuid,text,text,text,text,text,text,text),prod.register_recording(uuid,text,text,integer,bigint,text,text,text),prod.delete_recording(uuid),prod.assign_recording(uuid,uuid,text,text,timestamptz,text),prod.revoke_assignment(uuid),prod.my_practice_assignments(),prod.can_play_recording(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION prod.create_class(text,text,text,text,text,text,text,text),prod.update_class_classification(uuid,text,text,text,text,text,text,text),prod.register_recording(uuid,text,text,integer,bigint,text,text,text),prod.delete_recording(uuid),prod.assign_recording(uuid,uuid,text,text,timestamptz,text),prod.revoke_assignment(uuid),prod.my_practice_assignments(),prod.can_play_recording(text) TO authenticated;

-- Private object storage. Skipped on plain Postgres (CI); applied on Supabase.
DO $storage$ BEGIN
 IF to_regclass('storage.objects') IS NOT NULL THEN
  INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  VALUES('teacher-recordings-prod','teacher-recordings-prod',false,20971520,ARRAY['audio/mp4','audio/aac','audio/ogg','audio/webm','audio/mpeg','audio/wav']) ON CONFLICT(id) DO NOTHING;
  CREATE POLICY "prod_recordings_upload" ON storage.objects FOR INSERT TO authenticated
   WITH CHECK(bucket_id='teacher-recordings-prod' AND (storage.foldername(name))[1]=auth.uid()::text AND EXISTS(SELECT 1 FROM prod.teachers t WHERE t.id=auth.uid()));
  CREATE POLICY "prod_recordings_read" ON storage.objects FOR SELECT TO authenticated
   USING(bucket_id='teacher-recordings-prod' AND ((storage.foldername(name))[1]=auth.uid()::text OR prod.can_play_recording(name)));
 END IF;
END $storage$;

NOTIFY pgrst, 'reload schema';
