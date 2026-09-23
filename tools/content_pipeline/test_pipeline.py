import tempfile
import unittest
from pathlib import Path
from pipeline import canonical, review_export, review_import, validate, sign, validate_runtime

ASSETS = Path(__file__).resolve().parents[2] / 'apps/vaachak_app/assets'
class PipelineTests(unittest.TestCase):
    def test_canonical_is_stable(self):
        self.assertEqual(canonical({'b': 2, 'a': {'z': 1, 'c': 0}}), b'{"a":{"c":0,"z":1},"b":2}')
    def test_development_assets_cannot_be_released(self):
        self.assertEqual(validate(ASSETS, False), [])
        self.assertGreater(len(validate(ASSETS, True)), 100)
    def test_review_round_trip_preserves_draft_status(self):
        import shutil
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for source in ASSETS.glob('*.json'): shutil.copy(source, root / source.name)
            review_export(root, root / 'review.csv')
            review_import(root, root / 'review.csv')
            self.assertEqual(validate(root, False), [])
            self.assertGreater(len(validate(root, True)), 0)
    def test_signed_model_manifest_is_immutable_and_verifiable(self):
        import json, base64
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, NoEncryption
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); source=root/'model'; source.mkdir(); (source/'weights.onnx').write_bytes(b'test-only-model-bytes')
            key=Ed25519PrivateKey.generate(); key_file=root/'key.pem'
            key_file.write_bytes(key.private_bytes(Encoding.PEM,PrivateFormat.PKCS8,NoEncryption())); key_file.chmod(0o600)
            manifest=root/'manifest.json'
            sign(source,manifest,key_file,'test','test.model','1.0.0','pronunciation','B')
            data=json.loads(manifest.read_text()); signature=base64.b64decode(data.pop('signature'))
            key.public_key().verify(signature,canonical(data))
            with self.assertRaises(ValueError): sign(source,manifest,key_file,'test','test.model','1.0.0','pronunciation','B')
    def test_signing_rejects_unreviewed_content(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError,'Content release blocked'):
                sign(ASSETS,Path(temp)/'manifest.json',Path(temp)/'absent.pem','test','test.core','1.0.0','core','C')
    def test_reading_rubric_and_model_versions_are_validated(self):
        import shutil, json
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for source in ASSETS.glob('*.json'): shutil.copy(source, root / source.name)
            passages = json.loads((root / 'passages.json').read_text())
            passages[0]['targetWcpm'] = 0
            (root / 'passages.json').write_text(json.dumps(passages))
            self.assertTrue(any('rubric' in error for error in validate(root, False)))
            passages[0].update(targetWcpm=60, reviewStatus='approved', reviewer='test only', reviewedAt='2026-09-23')
            (root / 'passages.json').write_text(json.dumps(passages))
            self.assertTrue(any('model versions' in error for error in validate(root, False)))

    def test_reading_review_covers_rubric_changes(self):
        import shutil, json, csv
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for source in ASSETS.glob('*.json'): shutil.copy(source, root / source.name)
            review_export(root, root / 'review.csv')
            with (root / 'review.csv').open() as handle:
                rows = list(csv.DictReader(handle))
            self.assertEqual(sum(row['kind'] == 'passage' for row in rows), 1)
            passages = json.loads((root / 'passages.json').read_text())
            passages[0]['targetWcpm'] = 80
            (root / 'passages.json').write_text(json.dumps(passages))
            with self.assertRaisesRegex(ValueError, 'Content changed after export'):
                review_import(root, root / 'review.csv')

class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.files = [{'path': name} for name in ['encoder.onnx', 'decoder.onnx', 'joiner.onnx', 'tokens.txt', 'voice.onnx', 'voice-tokens.txt', 'espeak-ng-data/en', 'model.litertlm']]
        self.runtime = {'asr': {'type': 'whisper', 'tokens': 'tokens.txt', 'encoder': 'encoder.onnx', 'decoder': 'decoder.onnx'}, 'tts': {'model': 'voice.onnx', 'tokens': 'voice-tokens.txt', 'dataDir': 'espeak-ng-data'}}

    def test_speech_types_and_signed_references(self):
        validate_runtime(self.runtime, self.files, 'speech', 'C')
        self.runtime['asr'].update(type='zipformer', joiner='joiner.onnx')
        validate_runtime(self.runtime, self.files, 'speech', 'B')
        self.runtime['asr']['encoder'] = '../unsigned.onnx'
        with self.assertRaisesRegex(ValueError, 'unsigned'):
            validate_runtime(self.runtime, self.files, 'speech', 'B')

    def test_runtime_rejects_unknown_or_incomplete_configuration(self):
        import copy
        for edit in [lambda r: r.update(untrusted={}), lambda r: r['asr'].update(type='unknown'), lambda r: r['tts'].update(dataDir='../data'), lambda r: r.pop('tts'), lambda r: r['asr'].update(joiner='joiner.onnx')]:
            runtime = copy.deepcopy(self.runtime); edit(runtime)
            with self.assertRaises(ValueError): validate_runtime(runtime, self.files, 'speech', 'C')

    def test_explainer_format_and_tier(self):
        runtime = {'explainer': {'type': 'litertlm', 'model': 'model.litertlm'}}
        validate_runtime(runtime, self.files, 'explainer', 'A')
        for kind, tier in [('speech', 'A'), ('explainer', 'B')]:
            with self.assertRaises(ValueError): validate_runtime(runtime, self.files, kind, tier)
        runtime['explainer']['model'] = 'encoder.onnx'
        with self.assertRaises(ValueError): validate_runtime(runtime, self.files, 'explainer', 'A')

if __name__ == '__main__': unittest.main()
