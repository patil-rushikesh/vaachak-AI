import base64
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, NoEncryption
from catalog import sign_catalog
from pipeline import canonical

class CatalogTests(unittest.TestCase):
    def test_catalog_signature_and_immutable_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); key=Ed25519PrivateKey.generate(); key_file=root/'key.pem'
            key_file.write_bytes(key.private_bytes(Encoding.PEM,PrivateFormat.PKCS8,NoEncryption())); key_file.chmod(0o600)
            now=datetime.now(timezone.utc)
            source=root/'source.json'; output=root/'signed.json'
            source.write_text(json.dumps({'sequence':1,'issuedAt':now.isoformat(),'expiresAt':(now+timedelta(days=7)).isoformat(),'packs':[]}))
            sign_catalog(source,output,key_file,'school')
            data=json.loads(output.read_text()); signature=base64.b64decode(data.pop('signature'))
            key.public_key().verify(signature,canonical(data))
            with self.assertRaises(ValueError): sign_catalog(source,output,key_file,'school')
            key_file.chmod(0o644)
            with self.assertRaises(ValueError): sign_catalog(source,root/'other.json',key_file,'school')
    def test_expired_catalog_is_not_signed(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); key=Ed25519PrivateKey.generate(); key_file=root/'key.pem'
            key_file.write_bytes(key.private_bytes(Encoding.PEM,PrivateFormat.PKCS8,NoEncryption())); key_file.chmod(0o600)
            now=datetime.now(timezone.utc)-timedelta(days=2)
            source=root/'source.json'; source.write_text(json.dumps({'sequence':1,'issuedAt':now.isoformat(),'expiresAt':(now+timedelta(days=1)).isoformat(),'packs':[]}))
            with self.assertRaises(ValueError): sign_catalog(source,root/'signed.json',key_file,'school')
