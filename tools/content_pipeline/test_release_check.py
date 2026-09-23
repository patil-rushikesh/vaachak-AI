import base64
import importlib.util
import unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('release_check',Path(__file__).resolve().parents[1]/'release_check.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class ReleaseCheckTests(unittest.TestCase):
    def config(self):
        return {'VAACHAK_ENV':'prod','SUPABASE_URL':'https://school.supabase.co','SUPABASE_ANON_KEY':'sb_publishable_fixture',
                'PACK_CATALOG_URL':'https://school.example/catalog.json','PACK_KEY_ID':'school','PACK_PUBLIC_KEY':base64.b64encode(bytes(32)).decode(),
                'SCHOOL_PRIVACY_CONTACT':'School office'}
    def test_valid_configuration_and_schema_priority(self):
        self.assertEqual(module.configuration_errors(self.config(),True,4),[])
        self.assertTrue(module.configuration_errors(self.config(),True,0))
    def test_debug_and_secret_credentials_fail_closed(self):
        for change in [{'LOCAL_TEST_ACCESS_TOKEN':'test'}, {'SUPABASE_ANON_KEY':'sb_secret_test'},
                       {'VAACHAK_ENV':'dev'}, {'PACK_PUBLIC_KEY':'invalid'}, {'PACK_CATALOG_URL':'http://example.org/catalog.json'}]:
            self.assertTrue(module.configuration_errors({**self.config(),**change}))
