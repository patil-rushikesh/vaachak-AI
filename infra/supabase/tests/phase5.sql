BEGIN;
CREATE FUNCTION pg_temp.check(ok boolean,label text) RETURNS void LANGUAGE plpgsql AS $$BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'Phase5 assertion: %',label;END IF;END$$;
CREATE FUNCTION pg_temp.fails(sql text,label text) RETURNS void LANGUAGE plpgsql AS $$BEGIN
 BEGIN EXECUTE sql;RAISE EXCEPTION 'expected failure: %',label;
 EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'expected failure:%' THEN RAISE;END IF;END;
END$$;
-- fixtures: two teachers (same school), a minor-free adult learner on a device, one outsider
INSERT INTO auth.users(id) VALUES('10000000-0000-0000-0000-000000000051'),('10000000-0000-0000-0000-000000000052'),('10000000-0000-0000-0000-000000000053'),('10000000-0000-0000-0000-000000000054');
INSERT INTO dev.orgs(id,name) VALUES('20000000-0000-0000-0000-000000000051','Phase5 school'),('20000000-0000-0000-0000-000000000052','Other school');
INSERT INTO dev.teachers VALUES('10000000-0000-0000-0000-000000000051','20000000-0000-0000-0000-000000000051','Teacher A'),('10000000-0000-0000-0000-000000000052','20000000-0000-0000-0000-000000000052','Teacher B');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000051',true);
-- classification
CREATE TEMP TABLE ids(k text PRIMARY KEY,v text);
GRANT ALL ON ids TO authenticated;
INSERT INTO ids VALUES('class',dev.create_class('Std 5 A','5','A','411001','Maharashtra','Pune','mr','2026-27')::text);
SELECT pg_temp.check((SELECT standard='5' AND pincode='411001' AND district='Pune' AND instruction_language='mr' AND org_id='20000000-0000-0000-0000-000000000051' FROM dev.classes WHERE id=(SELECT v::uuid FROM ids WHERE k='class')),'class created with classification in teacher org');
SELECT pg_temp.check(dev.teacher_has_class((SELECT v::uuid FROM ids WHERE k='class')),'creator is assigned');
SELECT pg_temp.fails($$SELECT dev.create_class('Bad','13','A','411001','MH','Pune','mr')$$,'invalid standard rejected');
SELECT pg_temp.fails($$SELECT dev.create_class('Bad','5','A','011001','MH','Pune','mr')$$,'invalid pincode rejected');
SELECT pg_temp.fails($$SELECT dev.create_class('Bad','5','A','411001','MH','Pune','Marathi')$$,'invalid language rejected');
SELECT dev.update_class_classification((SELECT v::uuid FROM ids WHERE k='class'),'6','B','411002','Maharashtra','Pune','mr','2026-27');
SELECT pg_temp.check((SELECT standard='6' AND section='B' FROM dev.classes WHERE id=(SELECT v::uuid FROM ids WHERE k='class')),'classification updated');
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000052',true);
SELECT pg_temp.fails(format($$SELECT dev.update_class_classification(%L,'7','A','411001','MH','Pune','mr')$$,(SELECT v FROM ids WHERE k='class')),'other teacher cannot reclassify');
SELECT pg_temp.check((SELECT count(*) FROM dev.classes)=0,'other teacher cannot see class');
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000053',true);
SELECT pg_temp.fails($$SELECT dev.create_class('X','5','A','411001','MH','Pune','mr')$$,'non-teacher cannot create class');
-- recordings
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000051',true);
INSERT INTO ids VALUES('rec','aaaaaaaa-0000-4000-8000-000000000001');
SELECT dev.register_recording('aaaaaaaa-0000-4000-8000-000000000001','Read the poem','mr',45000,350000,'audio/mp4',repeat('a',64),'m4a');
SELECT pg_temp.check((SELECT storage_path='10000000-0000-0000-0000-000000000051/aaaaaaaa-0000-4000-8000-000000000001.m4a' FROM dev.lesson_recordings),'path is teacher folder + id');
SELECT pg_temp.fails($$SELECT dev.register_recording('aaaaaaaa-0000-4000-8000-000000000002','Too big','mr',45000,99999999,'audio/mp4',repeat('a',64),'m4a')$$,'oversize rejected');
SELECT pg_temp.fails($$SELECT dev.register_recording('aaaaaaaa-0000-4000-8000-000000000003','Wrong type','mr',45000,1000,'video/mp4',repeat('a',64),'m4a')$$,'mime rejected');
SELECT pg_temp.fails($$SELECT dev.register_recording('aaaaaaaa-0000-4000-8000-000000000004','Traversal','mr',45000,1000,'audio/mp4',repeat('a',64),'../x')$$,'bad extension rejected');
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000052',true);
SELECT pg_temp.check((SELECT count(*) FROM dev.lesson_recordings)=0,'other teacher cannot see recording');
SELECT pg_temp.fails(format($$SELECT dev.assign_recording(%L,'aaaaaaaa-0000-4000-8000-000000000001','Steal')$$,(SELECT v FROM ids WHERE k='class')),'other teacher cannot assign');
-- learner on a device joins and is approved
RESET ROLE;
UPDATE dev.classes SET code_hash=encode(extensions.digest('P5-CODE','sha256'),'hex'),code_expires_at=now()+interval '20 minutes' WHERE id=(SELECT v::uuid FROM ids WHERE k='class');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000053',true);
SELECT dev.register_device('phase5-device-1');
SELECT pg_temp.check((dev.join_class('P5-CODE','00000000000000000000000051','Adult learner','adult',false,true)->>'status')='pending','learner pending');
SELECT pg_temp.check(dev.my_practice_assignments()='[]'::jsonb,'nothing before assignment');
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000054',true);
SELECT dev.register_device('phase5-device-2');
SELECT pg_temp.check((dev.join_class('P5-CODE','00000000000000000000000052','Second learner','adult',false,true)->>'status')='pending','second pending');
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000051',true);
SELECT dev.review_enrollment((SELECT v::uuid FROM ids WHERE k='class'),'00000000000000000000000051',true);
SELECT dev.review_enrollment((SELECT v::uuid FROM ids WHERE k='class'),'00000000000000000000000052',true);
-- assignment: whole class, then one learner
INSERT INTO ids VALUES('a_class',dev.assign_recording((SELECT v::uuid FROM ids WHERE k='class'),'aaaaaaaa-0000-4000-8000-000000000001','Poem for everyone','Listen then read aloud',now()+interval '3 days')::text);
INSERT INTO ids VALUES('a_one',dev.assign_recording((SELECT v::uuid FROM ids WHERE k='class'),'aaaaaaaa-0000-4000-8000-000000000001','Extra for learner 51',NULL,NULL,'00000000000000000000000051')::text);
SELECT pg_temp.fails(format($$SELECT dev.assign_recording(%L,'aaaaaaaa-0000-4000-8000-000000000001','Past due',NULL,now()-interval '1 day')$$,(SELECT v FROM ids WHERE k='class')),'past due rejected');
SELECT pg_temp.fails(format($$SELECT dev.assign_recording(%L,'aaaaaaaa-0000-4000-8000-000000000001','Nobody',NULL,NULL,'00000000000000000000000099')$$,(SELECT v FROM ids WHERE k='class')),'non-enrolled learner rejected');
SELECT pg_temp.check((SELECT count(*) FROM dev.practice_assignments)=2,'teacher sees both assignments');
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000053',true);
SELECT pg_temp.check(jsonb_array_length(dev.my_practice_assignments())=2,'learner 51 sees class + own assignment');
SELECT pg_temp.check(dev.can_play_recording('10000000-0000-0000-0000-000000000051/aaaaaaaa-0000-4000-8000-000000000001.m4a'),'assigned learner may play');
SELECT pg_temp.check(NOT dev.can_play_recording('10000000-0000-0000-0000-000000000051/other.m4a'),'unassigned path denied');
SELECT pg_temp.check((SELECT count(*) FROM dev.lesson_recordings)=0,'learner cannot read recordings table');
SELECT pg_temp.fails($$SELECT dev.revoke_assignment((SELECT v::uuid FROM ids WHERE k='a_class'))$$,'learner cannot revoke');
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000054',true);
SELECT pg_temp.check(jsonb_array_length(dev.my_practice_assignments())=1,'learner 52 sees only the class assignment');
-- revoke, then delete
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000051',true);
SELECT dev.revoke_assignment((SELECT v::uuid FROM ids WHERE k='a_one'));
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000053',true);
SELECT pg_temp.check(jsonb_array_length(dev.my_practice_assignments())=1,'revoked assignment disappears');
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000051',true);
SELECT dev.delete_recording('aaaaaaaa-0000-4000-8000-000000000001');
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000053',true);
SELECT pg_temp.check(dev.my_practice_assignments()='[]'::jsonb,'deleted recording vanishes for learners');
SELECT pg_temp.check(NOT dev.can_play_recording('10000000-0000-0000-0000-000000000051/aaaaaaaa-0000-4000-8000-000000000001.m4a'),'deleted recording cannot be played');
-- anon and direct writes are blocked
RESET ROLE;
SELECT pg_temp.check(NOT has_table_privilege('authenticated','dev.lesson_recordings','INSERT') AND NOT has_table_privilege('authenticated','dev.practice_assignments','INSERT'),'no direct writes');
SELECT pg_temp.check(NOT has_function_privilege('anon','dev.my_practice_assignments()','EXECUTE'),'anon cannot call');
SELECT pg_temp.check((SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN('dev','qa','prod') AND p.proname='assign_recording')=3,'three isolated environments');
-- erasure of a learner removes learner-targeted assignments
SELECT dev.erase_learner('00000000000000000000000051');
SELECT pg_temp.check((SELECT count(*) FROM dev.practice_assignments WHERE learner_id='00000000000000000000000051')=0,'erasure cascades to assignments');
ROLLBACK;
