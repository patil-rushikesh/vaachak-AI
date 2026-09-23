#!/usr/bin/env python3
"""Sign an immutable CDN catalog using an owner-only Ed25519 key.
Input: JSON object with sequence, issuedAt, expiresAt and packs (manifest/baseUrl).
"""
import argparse
import base64
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from pipeline import canonical


def sign_catalog(source: Path, output: Path, key_file: Path, key_id: str) -> None:
    if output.exists():
        raise ValueError('Catalog versions are immutable; use a new output path')
    if key_file.stat().st_mode & 0o077:
        raise ValueError('Signing key must be owner-only (chmod 600)')
    key = load_pem_private_key(key_file.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey) or not key_id:
        raise ValueError('An Ed25519 key and key ID are required')
    data = json.loads(source.read_text())
    if 'signature' in data:
        raise ValueError('Input must be unsigned')
    data.update(schemaVersion=1, keyId=key_id)
    issued = datetime.fromisoformat(data['issuedAt'].replace('Z', '+00:00'))
    expires = datetime.fromisoformat(data['expiresAt'].replace('Z', '+00:00'))
    if (issued.tzinfo is None or expires.tzinfo is None or
            not timedelta(0) < expires-issued <= timedelta(days=90) or
            expires <= datetime.now(timezone.utc) or
            type(data['sequence']) is not int or data['sequence'] < 1 or
            not isinstance(data['packs'], list) or len(data['packs']) > 100):
        raise ValueError('Invalid catalog sequence, dates or pack count')
    seen = set()
    for entry in data['packs']:
        url = urlsplit(entry['baseUrl'])
        manifest = entry['manifest']
        if (url.scheme != 'https' or not url.hostname or url.username or
                url.query or url.fragment or not url.path.endswith('/') or
                manifest['packId'] in seen or not manifest.get('signature')):
            raise ValueError('Invalid catalog entry')
        seen.add(manifest['packId'])
    data['signature'] = base64.b64encode(key.sign(canonical(data))).decode()
    encoded = canonical(data)
    if len(encoded) > 1048576:
        raise ValueError('Catalog exceeds 1 MiB')
    with output.open('x') as target:
        target.write(encoded.decode() + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--key-id', required=True)
    args = parser.parse_args()
    sign_catalog(args.source, args.output, args.key, args.key_id)
