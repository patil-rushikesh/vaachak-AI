#!/usr/bin/env python3
"""Package downloaded Whisper/Piper assets for tests; never creates a release key."""
import argparse
import base64
import json
from pathlib import Path
import shutil
import tempfile
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, PublicFormat, NoEncryption
from content_pipeline.pipeline import sign


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('models', type=Path, help='Directory containing extracted official Whisper tiny.en and Piper lessac archives')
    parser.add_argument('output', type=Path, help='New test output directory; existing paths are refused')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    pack = args.output / 'pack'
    pack.mkdir()
    whisper = args.models / 'sherpa-onnx-whisper-tiny.en'
    piper = args.models / 'vits-piper-en_US-lessac-medium'
    for source, target in [(whisper / 'tiny.en-encoder.int8.onnx', 'encoder.onnx'),
                           (whisper / 'tiny.en-decoder.int8.onnx', 'decoder.onnx'),
                           (whisper / 'tiny.en-tokens.txt', 'tokens.txt'),
                           (piper / 'en_US-lessac-medium.onnx', 'voice.onnx'),
                           (piper / 'tokens.txt', 'voice-tokens.txt')]:
        shutil.copyfile(source, pack / target)
    shutil.copytree(piper / 'espeak-ng-data', pack / 'espeak-ng-data')
    runtime = {'asr': {'type': 'whisper', 'tokens': 'tokens.txt', 'encoder': 'encoder.onnx', 'decoder': 'decoder.onnx'},
               'tts': {'type': 'vits', 'model': 'voice.onnx', 'tokens': 'voice-tokens.txt', 'dataDir': 'espeak-ng-data'}}
    key = Ed25519PrivateKey.generate()
    with tempfile.TemporaryDirectory(prefix='vaachak-smoke-key-') as tmp:
        key_file = Path(tmp) / 'test.pem'
        key_file.touch(mode=0o600)
        key_file.write_bytes(key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
        runtime_file = Path(tmp) / 'runtime.json'
        runtime_file.write_text(json.dumps(runtime))
        sign(pack, pack / 'manifest.json', key_file, 'local-smoke-only', 'test.speech', '1.0.0', 'speech', 'C', runtime_file)
    (args.output / 'test-public-key.txt').write_text(base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode())
    (args.output / 'README.txt').write_text('Local development inference fixture. The ephemeral signing key was destroyed. This key/model is not trusted by release builds. No curriculum or model calibration approval is implied. Source: official k2-fsa/sherpa-onnx Whisper tiny.en and Piper en_US-lessac-medium release archives.\n')
    print(f'Test-only signed pack prepared at {pack}')

if __name__ == '__main__':
    main()
