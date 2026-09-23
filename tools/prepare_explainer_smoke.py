#!/usr/bin/env python3
"""Sign an already-authorized LiteRT-LM file for local development tests only."""
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
    parser.add_argument('model', type=Path, help='Existing licensed .litertlm model; this tool never downloads or accepts terms')
    parser.add_argument('output', type=Path, help='New output directory')
    args = parser.parse_args()
    if args.model.suffix != '.litertlm' or not args.model.is_file():
        parser.error('Supply an existing authorized .litertlm model')
    args.output.mkdir(parents=True, exist_ok=False)
    pack = args.output / 'pack'; pack.mkdir()
    shutil.copyfile(args.model, pack / 'model.litertlm')
    key = Ed25519PrivateKey.generate()
    with tempfile.TemporaryDirectory(prefix='vaachak-explainer-key-') as temp:
        key_file = Path(temp) / 'test.pem'; key_file.touch(mode=0o600)
        key_file.write_bytes(key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))
        runtime = Path(temp) / 'runtime.json'
        runtime.write_text(json.dumps({'explainer': {'type': 'litertlm', 'model': 'model.litertlm'}}))
        sign(pack, pack / 'manifest.json', key_file, 'local-smoke-only', 'test.explainer', '1.0.0', 'explainer', 'A', runtime)
    (args.output / 'test-public-key.txt').write_text(base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode())
    (args.output / 'README.txt').write_text('Development-only model fixture; ephemeral private key destroyed. Never configure this public key as a school release trust anchor. Original model rights and license still apply.\n')
    print(f'Test-only signed explainer prepared at {pack}')

if __name__ == '__main__': main()
