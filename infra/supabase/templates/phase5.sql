-- Phase 5: classroom classification, teacher voice recordings and practice assignments.
-- Additive only. Every table is default-deny; RPCs are the only mutation surface.

-- ---------------------------------------------------------------------------
-- 1. Classification: standard (grade), section, pincode, state, district, language.
--    Stored on the school (org) and the class. Learners inherit it through their
--    class; no learner-level location is collected (data minimisation).
-- ---------------------------------------------------------------------------
ALTER TABLE __ENV__.orgs
 ADD COLUMN pincode text CHECK(pincode IS NULL OR pincode ~ '^[1-9][0-9]{5}$'),
 ADD COLUMN state text CHECK(state IS NULL OR length(trim(state)) BETWEEN 2 AND 60),
 ADD COLUMN district text CHECK(district IS NULL OR length(trim(district)) BETWEEN 2 AND 60),
 ADD COLUMN primary_language text CHECK(primary_language IS NULL OR primary_language ~ '^[a-z]{2,3}$');
ALTER TABLE __ENV__.classes
 ADD COLUMN standard text CHECK(standard IS NULL OR standard IN ('KG','1','2','3','4','5','6','7','8','9','10','11','12','adult')),
 ADD COLUMN section text CHECK(section IS NULL OR length(trim(section)) BETWEEN 1 AND 8),
 ADD COLUMN pincode text CHECK(pincode IS NULL OR pincode ~ '^[1-9][0-9]{5}$'),
 ADD COLUMN state text CHECK(state IS NULL OR length(trim(state)) BETWEEN 2 AND 60),
 ADD COLUMN district text CHECK(district IS NULL OR length(trim(district)) BETWEEN 2 AND 60),
 ADD COLUMN instruction_language text CHECK(instruction_language IS NULL OR instruction_language ~ '^[a-z]{2,3}$'),
 ADD COLUMN academic_year text CHECK(academic_year IS NULL OR academic_year ~ '^20[0-9]{2}-[0-9]{2}$');
CREATE INDEX ON __ENV__.classes(org_id,standard);
CREATE INDEX ON __ENV__.classes(pincode);

CREATE FUNCTION __ENV__.create_class(class_name text,class_standard text,class_section text,class_pincode text,class_state text,class_district text,class_language text,class_year text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE org uuid; result uuid;
BEGIN
 SELECT org_id INTO org FROM __ENV__.teachers WHERE id=auth.uid();
 IF org IS NULL THEN RAISE EXCEPTION 'Teacher required' USING ERRCODE='42501';END IF;
 IF class_name IS NULL OR length(trim(class_name)) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION 'Class name required';END IF;
 IF (SELECT count(*) FROM __ENV__.teacher_assignments WHERE teacher_id=auth.uid() AND to_at IS NULL)>=50 THEN RAISE EXCEPTION 'Class limit reached';END IF;
 INSERT INTO __ENV__.classes(org_id,name,standard,section,pincode,state,district,instruction_language,academic_year)
 VALUES(org,trim(class_name),class_standard,nullif(trim(class_section),''),class_pincode,nullif(trim(class_state),''),nullif(trim(class_district),''),class_language,class_year) RETURNING id INTO result;
 INSERT INTO __ENV__.teacher_assignments(class_id,teacher_id) VALUES(result,auth.uid());
 INSERT INTO __ENV__.audit_log(actor,action,target_hash) VALUES(auth.uid(),'class:create',encode(extensions.digest(result::text,'sha256'),'hex'));
 RETURN result;
END $$;

CREATE FUNCTION __ENV__.update_class_classification(target_class uuid,class_standard text,class_section text,class_pincode text,class_state text,class_district text,class_language text,class_year text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT __ENV__.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 UPDATE __ENV__.classes SET standard=class_standard,section=nullif(trim(class_section),''),pincode=class_pincode,state=nullif(trim(class_state),''),district=nullif(trim(class_district),''),instruction_language=class_language,academic_year=class_year WHERE id=target_class;
 INSERT INTO __ENV__.audit_log(actor,action,target_hash) VALUES(auth.uid(),'class:classify',encode(extensions.digest(target_class::text,'sha256'),'hex'));
END $$;

-- ---------------------------------------------------------------------------
-- 2. Teacher voice recordings and assignments to a whole class or one learner.
--    Audio bytes live in private object storage; the database holds metadata.
-- ---------------------------------------------------------------------------
CREATE TABLE __ENV__.lesson_recordings(
 id uuid PRIMARY KEY,
 org_id uuid NOT NULL REFERENCES __ENV__.orgs(id),
 teacher_id uuid NOT NULL REFERENCES __ENV__.teachers(id),
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
CREATE INDEX ON __ENV__.lesson_recordings(teacher_id,created_at DESC);
CREATE TABLE __ENV__.practice_assignments(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 class_id uuid NOT NULL REFERENCES __ENV__.classes(id) ON DELETE CASCADE,
 learner_id text REFERENCES __ENV__.learners(id) ON DELETE CASCADE, -- NULL = whole class
 teacher_id uuid NOT NULL REFERENCES __ENV__.teachers(id),
 recording_id uuid NOT NULL REFERENCES __ENV__.lesson_recordings(id),
 title text NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 120),
 instructions text CHECK(instructions IS NULL OR length(instructions)<=500),
 due_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 revoked_at timestamptz,
 delivery_seq bigint GENERATED ALWAYS AS IDENTITY UNIQUE
);
CREATE INDEX ON __ENV__.practice_assignments(class_id,created_at DESC);
CREATE INDEX ON __ENV__.practice_assignments(learner_id);

ALTER TABLE __ENV__.lesson_recordings ENABLE ROW LEVEL SECURITY;
ALTER TABLE __ENV__.practice_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY own_recordings ON __ENV__.lesson_recordings FOR SELECT TO authenticated USING(teacher_id=auth.uid() AND deleted_at IS NULL);
CREATE POLICY class_assignments ON __ENV__.practice_assignments FOR SELECT TO authenticated USING(__ENV__.teacher_has_class(class_id));
REVOKE ALL ON __ENV__.lesson_recordings,__ENV__.practice_assignments FROM PUBLIC,anon,authenticated;
GRANT SELECT ON __ENV__.lesson_recordings,__ENV__.practice_assignments TO authenticated;
GRANT ALL ON __ENV__.lesson_recordings,__ENV__.practice_assignments TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA __ENV__ TO service_role;

-- Called after the client has uploaded audio to <teacher id>/<recording id>.<ext>.
CREATE FUNCTION __ENV__.register_recording(recording_id uuid,recording_title text,recording_language text,recording_duration_ms integer,recording_size_bytes bigint,recording_mime text,recording_sha256 text,recording_ext text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE org uuid;
BEGIN
 SELECT org_id INTO org FROM __ENV__.teachers WHERE id=auth.uid();
 IF org IS NULL THEN RAISE EXCEPTION 'Teacher required' USING ERRCODE='42501';END IF;
 IF recording_ext IS NULL OR recording_ext !~ '^[a-z0-9]{2,4}$' THEN RAISE EXCEPTION 'Invalid file extension';END IF;
 IF (SELECT count(*) FROM __ENV__.lesson_recordings WHERE teacher_id=auth.uid() AND created_at>now()-interval '1 hour')>=60 THEN RAISE EXCEPTION 'Too many recordings. Try again later.';END IF;
 INSERT INTO __ENV__.lesson_recordings(id,org_id,teacher_id,title,language,duration_ms,size_bytes,mime,storage_path,sha256)
 VALUES(recording_id,org,auth.uid(),trim(recording_title),recording_language,recording_duration_ms,recording_size_bytes,recording_mime,auth.uid()::text||'/'||recording_id::text||'.'||recording_ext,recording_sha256);
 INSERT INTO __ENV__.audit_log(actor,action,target_hash) VALUES(auth.uid(),'recording:create',encode(extensions.digest(recording_id::text,'sha256'),'hex'));
 RETURN recording_id;
END $$;

CREATE FUNCTION __ENV__.delete_recording(target_recording uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 UPDATE __ENV__.lesson_recordings SET deleted_at=now() WHERE id=target_recording AND teacher_id=auth.uid() AND deleted_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Recording not found' USING ERRCODE='42501';END IF;
 UPDATE __ENV__.practice_assignments SET revoked_at=now() WHERE recording_id=target_recording AND revoked_at IS NULL;
 INSERT INTO __ENV__.audit_log(actor,action,target_hash) VALUES(auth.uid(),'recording:delete',encode(extensions.digest(target_recording::text,'sha256'),'hex'));
END $$;

-- target_learner NULL assigns to every active learner in the class.
CREATE FUNCTION __ENV__.assign_recording(target_class uuid,target_recording uuid,assignment_title text,assignment_instructions text DEFAULT NULL,assignment_due timestamptz DEFAULT NULL,target_learner text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid;
BEGIN
 IF NOT __ENV__.teacher_has_class(target_class) THEN RAISE EXCEPTION 'Not assigned' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM __ENV__.lesson_recordings WHERE id=target_recording AND teacher_id=auth.uid() AND deleted_at IS NULL) THEN RAISE EXCEPTION 'Recording not found' USING ERRCODE='42501';END IF;
 IF target_learner IS NOT NULL AND NOT EXISTS(SELECT 1 FROM __ENV__.enrollments WHERE class_id=target_class AND learner_id=target_learner AND status='active' AND from_at<=now() AND (to_at IS NULL OR to_at>now())) THEN RAISE EXCEPTION 'Not assigned to learner' USING ERRCODE='42501';END IF;
 IF assignment_due IS NOT NULL AND assignment_due<now() THEN RAISE EXCEPTION 'Due date is in the past';END IF;
 INSERT INTO __ENV__.practice_assignments(class_id,learner_id,teacher_id,recording_id,title,instructions,due_at)
 VALUES(target_class,target_learner,auth.uid(),target_recording,trim(assignment_title),assignment_instructions,assignment_due) RETURNING id INTO result;
 INSERT INTO __ENV__.audit_log(actor,action,target_hash) VALUES(auth.uid(),'assignment:'||CASE WHEN target_learner IS NULL THEN 'class' ELSE 'learner' END,encode(extensions.digest(result::text,'sha256'),'hex'));
 RETURN result;
END $$;

CREATE FUNCTION __ENV__.revoke_assignment(target_assignment uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 UPDATE __ENV__.practice_assignments a SET revoked_at=now() WHERE a.id=target_assignment AND a.revoked_at IS NULL AND __ENV__.teacher_has_class(a.class_id);
 IF NOT FOUND THEN RAISE EXCEPTION 'Assignment not found' USING ERRCODE='42501';END IF;
END $$;

-- Learner side: only assignments for learners owned by this device, in classes that
-- have approved them, with core + serverSync consent. Never lists other learners.
CREATE FUNCTION __ENV__.my_practice_assignments() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(x.item ORDER BY x.created_at DESC),'[]'::jsonb) FROM (
  SELECT DISTINCT ON (a.id,e.learner_id) a.created_at,jsonb_build_object(
   'id',a.id,'classId',a.class_id,'className',c.name,'learnerId',e.learner_id,'scope',CASE WHEN a.learner_id IS NULL THEN 'class' ELSE 'learner' END,
   'title',a.title,'instructions',a.instructions,'dueAt',a.due_at,'createdAt',a.created_at,
   'recording',jsonb_build_object('id',r.id,'language',r.language,'durationMs',r.duration_ms,'mime',r.mime,'sizeBytes',r.size_bytes,'sha256',r.sha256,'path',r.storage_path)) item
  FROM __ENV__.enrollments e
  JOIN __ENV__.classes c ON c.id=e.class_id
  JOIN __ENV__.practice_assignments a ON a.class_id=e.class_id AND (a.learner_id IS NULL OR a.learner_id=e.learner_id)
  JOIN __ENV__.lesson_recordings r ON r.id=a.recording_id AND r.deleted_at IS NULL
  WHERE e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now())
   AND a.revoked_at IS NULL AND __ENV__.owns_learner(e.learner_id)
   AND __ENV__.has_consent(e.learner_id,'core') AND __ENV__.has_consent(e.learner_id,'serverSync')
  ORDER BY a.id,e.learner_id LIMIT 200) x
$$;

-- Storage access check, reused by the object-storage policies below.
CREATE FUNCTION __ENV__.can_play_recording(object_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM __ENV__.lesson_recordings r WHERE r.storage_path=object_path AND r.deleted_at IS NULL AND (r.teacher_id=auth.uid() OR EXISTS(
  SELECT 1 FROM __ENV__.practice_assignments a JOIN __ENV__.enrollments e ON e.class_id=a.class_id AND (a.learner_id IS NULL OR a.learner_id=e.learner_id)
  WHERE a.recording_id=r.id AND a.revoked_at IS NULL AND e.status='active' AND e.from_at<=now() AND (e.to_at IS NULL OR e.to_at>now())
   AND __ENV__.owns_learner(e.learner_id) AND __ENV__.has_consent(e.learner_id,'core') AND __ENV__.has_consent(e.learner_id,'serverSync'))))
$$;

REVOKE ALL ON FUNCTION __ENV__.create_class(text,text,text,text,text,text,text,text),__ENV__.update_class_classification(uuid,text,text,text,text,text,text,text),__ENV__.register_recording(uuid,text,text,integer,bigint,text,text,text),__ENV__.delete_recording(uuid),__ENV__.assign_recording(uuid,uuid,text,text,timestamptz,text),__ENV__.revoke_assignment(uuid),__ENV__.my_practice_assignments(),__ENV__.can_play_recording(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION __ENV__.create_class(text,text,text,text,text,text,text,text),__ENV__.update_class_classification(uuid,text,text,text,text,text,text,text),__ENV__.register_recording(uuid,text,text,integer,bigint,text,text,text),__ENV__.delete_recording(uuid),__ENV__.assign_recording(uuid,uuid,text,text,timestamptz,text),__ENV__.revoke_assignment(uuid),__ENV__.my_practice_assignments(),__ENV__.can_play_recording(text) TO authenticated;

-- Private object storage. Skipped on plain Postgres (CI); applied on Supabase.
DO $storage$ BEGIN
 IF to_regclass('storage.objects') IS NOT NULL THEN
  INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  VALUES('teacher-recordings-__ENV__','teacher-recordings-__ENV__',false,20971520,ARRAY['audio/mp4','audio/aac','audio/ogg','audio/webm','audio/mpeg','audio/wav']) ON CONFLICT(id) DO NOTHING;
  CREATE POLICY "__ENV___recordings_upload" ON storage.objects FOR INSERT TO authenticated
   WITH CHECK(bucket_id='teacher-recordings-__ENV__' AND (storage.foldername(name))[1]=auth.uid()::text AND EXISTS(SELECT 1 FROM __ENV__.teachers t WHERE t.id=auth.uid()));
  CREATE POLICY "__ENV___recordings_read" ON storage.objects FOR SELECT TO authenticated
   USING(bucket_id='teacher-recordings-__ENV__' AND ((storage.foldername(name))[1]=auth.uid()::text OR __ENV__.can_play_recording(name)));
 END IF;
END $storage$;
