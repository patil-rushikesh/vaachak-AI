-- Development-only fixture. Run after creating this account through Supabase Auth.
-- Does not create or reset credentials, touch production, or grant broad roles.
BEGIN;
DO $$
DECLARE
  teacher_id uuid;
  school_id constant uuid := 'd321734f-d34b-4c89-9f9a-74d3b77b6301';
  class_id constant uuid := 'd321734f-d34b-4c89-9f9a-74d3b77b6302';
BEGIN
  SELECT id INTO STRICT teacher_id FROM auth.users WHERE lower(email)='teacher.test@example.com';
  IF EXISTS(SELECT 1 FROM dev.teachers WHERE id=teacher_id AND org_id<>school_id) THEN
    RAISE EXCEPTION 'Account already belongs to another organization';
  END IF;
  INSERT INTO dev.orgs(id,name) VALUES(school_id,'Vaachak Test School') ON CONFLICT(id) DO NOTHING;
  INSERT INTO dev.classes(id,org_id,name) VALUES(class_id,school_id,'Test Class A') ON CONFLICT(id) DO NOTHING;
  INSERT INTO dev.teachers(id,org_id,display_name) VALUES(teacher_id,school_id,'Test Teacher') ON CONFLICT(id) DO NOTHING;
  INSERT INTO dev.teacher_assignments(class_id,teacher_id) VALUES(class_id,teacher_id) ON CONFLICT DO NOTHING;
END $$;
COMMIT;
