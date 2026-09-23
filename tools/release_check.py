#!/usr/bin/env python3
"""Fail closed before preparing a production Android release. Does not publish."""
import argparse
import base64
import json
from pathlib import Path
from urllib.parse import urlsplit
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent / 'content_pipeline'))
from pipeline import validate


def configuration_errors(config, schema_migration=False, play_priority=0):
    errors = []
    if config.get('VAACHAK_ENV') != 'prod':
        errors.append('Production releases must select VAACHAK_ENV=prod')
    for name in ('SUPABASE_URL', 'PACK_CATALOG_URL'):
        url = urlsplit(config.get(name, ''))
        if url.scheme != 'https' or not url.hostname or url.username or url.fragment:
            errors.append(f'{name} must be an HTTPS URL without embedded credentials')
    if not config.get('SUPABASE_ANON_KEY'):
        errors.append('A public Supabase key is required')
    if any(config.get(name) for name in ('LOCAL_TEST_ACCESS_TOKEN', 'PHASE3_TEST_CONFIG', 'SUPABASE_SERVICE_ROLE_KEY')):
        errors.append('Test tokens and service-role credentials are forbidden in releases')
    key = config.get('SUPABASE_ANON_KEY', '')
    if key.startswith('sb_secret_'):
        errors.append('A secret key cannot be embedded in the app')
    if key.count('.') == 2:
        try:
            body = key.split('.')[1]
            claims = json.loads(base64.urlsafe_b64decode(body + '=' * (-len(body) % 4)))
            if claims.get('role') != 'anon':
                errors.append('Only the public anon JWT may be embedded')
        except (ValueError, UnicodeError):
            errors.append('Invalid public JWT key')
    try:
        keys = json.loads(config.get('PACK_PUBLIC_KEYS', '{}'))
        if config.get('PACK_KEY_ID') and config.get('PACK_PUBLIC_KEY'):
            keys[config['PACK_KEY_ID']] = config['PACK_PUBLIC_KEY']
        if not 1 <= len(keys) <= 8 or any(not name or len(base64.b64decode(value, validate=True)) != 32 for name, value in keys.items()):
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        errors.append('One to eight valid Ed25519 pack trust anchors are required')
    if not config.get('SCHOOL_PRIVACY_CONTACT', '').strip():
        errors.append('School privacy contact is required')
    if not 0 <= play_priority <= 5 or schema_migration and play_priority < 4:
        errors.append('Schema-changing releases require Play update priority 4 or 5')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--defines', type=Path, required=True)
    parser.add_argument('--schema-migration', action='store_true')
    parser.add_argument('--play-priority', type=int, default=0)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    errors = configuration_errors(json.loads(args.defines.read_text()), args.schema_migration, args.play_priority)
    if not (root/'apps/vaachak_app/android/key.properties').is_file():
        errors.append('Android release signing configuration is missing')
    content_errors = validate(root/'apps/vaachak_app/assets', True)
    if content_errors:
        errors.append(f'Curriculum release approval has {len(content_errors)} unresolved checks')
    print(json.dumps({'readyForReleaseBuild':not errors, 'errors':errors,
                      'scope':'Configuration/content gate only. Play rollout, legal sign-off and physical-device acceptance remain separate.'}, indent=2))
    return 1 if errors else 0


if __name__ == '__main__':
    raise SystemExit(main())
