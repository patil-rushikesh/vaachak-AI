#!/usr/bin/env python3
"""Validate educator-reviewed content and produce signed, immutable pack manifests."""
from __future__ import annotations
import argparse
import base64
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def load(path: Path) -> object:
    return json.loads(path.read_text(encoding='utf-8'))


def validate(directory: Path, release: bool) -> list[str]:
    graph = load(directory / 'skill_graph.json')
    rules = load(directory / 'grammar_rules.json')
    items = load(directory / 'items.json')
    passages = load(directory / 'passages.json') if (directory / 'passages.json').exists() else []
    errors: list[str] = []
    nodes = {node['id']: node for node in graph}
    if len(nodes) != len(graph) or not 60 <= len(graph) <= 80:
        errors.append('Skill graph must contain 60–80 distinct nodes')
    visiting, visited = set(), set()

    def visit(node_id: str) -> None:
        if node_id in visiting:
            raise ValueError(f'Cycle at {node_id}')
        if node_id in visited:
            return
        if node_id not in nodes:
            raise ValueError(f'Unknown prerequisite {node_id}')
        visiting.add(node_id)
        for parent in nodes[node_id]['prerequisites']:
            visit(parent)
        visiting.remove(node_id)
        visited.add(node_id)

    for node_id in nodes:
        visit(node_id)
    if len({r['id'] for r in rules}) != len(rules) or len(rules) < 40:
        errors.append('At least 40 distinct grammar rules are required')
    for rule in rules:
        if rule['nodeId'] not in nodes:
            errors.append(f"Rule {rule['id']} has unknown node")
        re.compile(rule['pattern'])
        if release and (rule.get('reviewStatus') != 'approved' or not rule.get('reviewer') or not rule.get('reviewedAt')):
            errors.append(f"Rule {rule['id']} is not signed off by an educator")
    ids = set()
    for item in items:
        key = (item['id'], item['version'])
        if key in ids or item['nodeId'] not in nodes:
            errors.append(f'Invalid or duplicate item {key}')
        ids.add(key)
        if item['type'] != 'choice' or not 0 <= item['difficulty'] <= 4 or not 0 <= item['answer'] < len(item['options']):
            errors.append(f'Invalid choice item {key}')
        if len(set(item['options'])) != len(item['options']) or not item['prompt'].strip():
            errors.append(f'Empty prompt or repeated options in {key}')
        if release and (item.get('reviewStatus') != 'approved' or not item.get('reviewer') or not item.get('reviewedAt')):
            errors.append(f'Item {key} needs educator sign-off')
    passage_ids = set()
    for passage in passages:
        key = (passage['id'], passage['version'])
        node = nodes.get(passage['nodeId'], {})
        target = passage['targetWcpm']
        models = passage['assessmentModelIds']
        if key in passage_ids or key in ids or node.get('skill') != 'reading':
            errors.append(f'Invalid or duplicate reading passage {key}')
        passage_ids.add(key)
        if (not passage['id'] or not isinstance(passage['version'], int) or passage['version'] < 1
                or not isinstance(passage['difficulty'], int) or not 0 <= passage['difficulty'] <= 4
                or not passage['title'].strip() or not passage['text'].strip()
                or len(passage['text']) > 10000 or not 1 <= len(re.findall(r"[a-z]+", passage['text'].lower())) <= 500
                or passage['cefr'] not in ('Pre-A1', 'A1', 'A2', 'B1', 'B2')
                or not passage['ageBands'] or not set(passage['ageBands']) <= {'child', 'student', 'adult'}
                or passage['reviewStatus'] not in ('draft', 'approved', 'rejected')
                or not isinstance(target, (float, int)) or isinstance(target, bool) or not math.isfinite(target) or not 0 < target <= 300
                or not isinstance(models, list) or any(not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,99}@\d+\.\d+\.\d+', model) for model in models)):
            errors.append(f'Invalid reading passage or rubric {key}')
        if passage['reviewStatus'] == 'approved' and not models:
            errors.append(f'Reading passage {key} needs approved model versions')
        if release and (passage['reviewStatus'] != 'approved' or not passage.get('reviewer', '').strip() or not passage.get('reviewedAt')):
            errors.append(f'Reading passage {key} needs educator sign-off')
    if release:
        for node in graph:
            for rung in range(5):
                for age in node['ageBands']:
                    pool = passages if node['skill'] == 'reading' else items
                    count = sum(i['nodeId'] == node['id'] and i['difficulty'] == rung and age in i['ageBands'] and i.get('reviewStatus') == 'approved' for i in pool)
                    if count < 3:
                        errors.append(f"{node['id']}: rung {rung}, {age} needs 3 approved items (has {count})")
    return errors


def review_text(record: dict, kind: str) -> str:
    if kind == 'passage':
        # Review includes the scoring rubric, model versions and age eligibility,
        # not only the prose. A change to any of these invalidates the review.
        return canonical({key: value for key, value in record.items()
                          if key not in ('reviewStatus', 'reviewer', 'reviewedAt')}).decode()
    return record.get('prompt', record.get('explanation', ''))


def review_export(directory: Path, output: Path) -> None:
    with output.open('w', newline='', encoding='utf-8') as target:
        writer = csv.DictWriter(target, fieldnames=['kind', 'id', 'version', 'text', 'decision', 'reviewer', 'reviewedAt'])
        writer.writeheader()
        for kind, filename in [('item', 'items.json'), ('rule', 'grammar_rules.json'), ('passage', 'passages.json')]:
            if not (directory / filename).exists(): continue
            for row in load(directory / filename):
                writer.writerow({'kind': kind, 'id': row['id'], 'version': row.get('version', 1), 'text': review_text(row, kind), 'decision': 'draft', 'reviewer': '', 'reviewedAt': ''})


def review_import(directory: Path, source: Path) -> None:
    with source.open(newline='', encoding='utf-8') as handle:
        reviews = list(csv.DictReader(handle))
    for kind, filename in [('item', 'items.json'), ('rule', 'grammar_rules.json'), ('passage', 'passages.json')]:
        path = directory / filename
        if not path.exists(): continue
        records = load(path)
        index = {(r['id'], str(r.get('version', 1))): r for r in records}
        for review in reviews:
            if review['kind'] != kind:
                continue
            key = (review['id'], review['version'])
            if key not in index or review['decision'] not in ('approved', 'rejected', 'draft'):
                raise ValueError(f'Invalid review record {key}')
            if review['decision'] == 'approved' and (not review['reviewer'].strip() or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', review['reviewedAt'])):
                raise ValueError(f'Approval requires reviewer and ISO review date: {key}')
            record = index[key]
            expected = review_text(record, kind)
            if review['text'] != expected:
                raise ValueError(f'Content changed after export: {key}; create a new version and review it')
            record.update(reviewStatus=review['decision'], reviewer=review['reviewer'], reviewedAt=review['reviewedAt'])
        temp = path.with_suffix('.new')
        temp.write_bytes(canonical(records) + b'\n')
        temp.replace(path)


def validate_runtime(runtime: object, files: list[dict], kind: str, tier: str) -> None:
    """Match the app's signed runtime contract before producing a signature."""
    paths = {entry['path'] for entry in files}
    if not isinstance(runtime, dict) or not runtime or not set(runtime) <= {'asr', 'tts', 'explainer'}:
        raise ValueError('Invalid model runtime descriptor')

    def descriptor(name: str, required: set[str], optional: set[str] = set()) -> dict:
        value = runtime.get(name)
        if not isinstance(value, dict) or not required <= set(value) or not set(value) <= required | optional:
            raise ValueError(f'Invalid {name} runtime fields')
        return value

    def signed(value: object) -> None:
        if not isinstance(value, str) or value not in paths:
            raise ValueError('Runtime references an unsigned model file')

    if 'asr' in runtime or 'tts' in runtime:
        if kind not in ('core', 'speech') or 'explainer' in runtime:
            raise ValueError('Speech runtime requires a core or speech pack')
        asr = descriptor('asr', {'type', 'tokens', 'encoder', 'decoder'}, {'joiner'})
        if asr['type'] not in ('whisper', 'zipformer'):
            raise ValueError('Unsupported ASR type')
        if (asr['type'] == 'zipformer') != ('joiner' in asr):
            raise ValueError('Only Zipformer requires a joiner')
        for name, value in asr.items():
            if name != 'type': signed(value)
        tts = descriptor('tts', {'model', 'tokens', 'dataDir'}, {'type'})
        if tts.get('type', 'vits') != 'vits':
            raise ValueError('Unsupported TTS type')
        signed(tts['model']); signed(tts['tokens'])
        data = tts['dataDir']
        if not isinstance(data, str) or not re.fullmatch(r'[A-Za-z0-9_-]+', data) or not any(p.startswith(data + '/') for p in paths):
            raise ValueError('Unsigned TTS data directory')
    if 'explainer' in runtime:
        if kind != 'explainer' or tier != 'A':
            raise ValueError('Explainer runtime requires a Tier A explainer pack')
        model = descriptor('explainer', {'type', 'model'})
        if model['type'] != 'litertlm' or not isinstance(model['model'], str) or not model['model'].endswith('.litertlm'):
            raise ValueError('Unsupported explanation model format')
        signed(model['model'])
    if kind == 'speech' and not {'asr', 'tts'} <= set(runtime):
        raise ValueError('Speech pack requires ASR and TTS')


def sign(directory: Path, output: Path, key_file: Path, key_id: str, pack_id: str, version: str, kind: str, tier: str, runtime_file: Path | None = None) -> None:
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    if kind not in ('core', 'speech', 'content', 'pronunciation', 'explainer') or tier not in ('A', 'B', 'C'):
        raise ValueError('Invalid pack kind or tier')
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,99}', pack_id) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid pack ID or semantic version')
    if kind in ('core', 'content'):
        errors = validate(directory, release=True)
        if errors:
            raise ValueError(f'Content release blocked: {len(errors)} validation issues; first: {errors[0]}')
    if output.exists():
        raise ValueError('Refusing to overwrite an immutable manifest')
    if key_file.stat().st_mode & 0o077:
        raise ValueError('Signing key must be private to its owner (chmod 600)')
    key = load_pem_private_key(key_file.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError('An Ed25519 release key is required')
    files = []
    root = directory.resolve()
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError(f'Symlink not permitted: {path}')
        if path.is_file():
            if path.resolve() == key_file.resolve():
                raise ValueError('Never place a signing key inside a pack')
            relative = path.relative_to(root).as_posix()
            if relative == 'manifest.json' or not re.fullmatch(r'[A-Za-z0-9_! ./-]+', relative):
                raise ValueError(f'Invalid pack filename: {relative}')
            digest = hashlib.sha256()
            with path.open('rb') as handle:
                while chunk := handle.read(1024 * 1024):
                    digest.update(chunk)
            files.append({'path': relative, 'sizeBytes': path.stat().st_size, 'sha256': digest.hexdigest()})
    total = sum(f['sizeBytes'] for f in files)
    if not files or any(f['sizeBytes'] == 0 for f in files) or total > (350_000_000 if kind in ('core', 'speech') else 2_000_000_000):
        raise ValueError('Pack is empty or exceeds its size budget')
    manifest = {'packId': pack_id, 'version': version, 'kind': kind, 'minTier': tier, 'keyId': key_id, 'appVersionRange': '>=0.1.0 <1.0.0', 'sizeBytes': total, 'files': files}
    if runtime_file:
        runtime = load(runtime_file)
        validate_runtime(runtime, files, kind, tier)
        manifest['runtime'] = runtime
    elif kind in ('speech', 'explainer'):
        raise ValueError('Speech and explainer packs require a runtime descriptor')
    manifest['signature'] = base64.b64encode(key.sign(canonical(manifest))).decode()
    with output.open('xb') as handle:
        handle.write(canonical(manifest) + b'\n')
        handle.flush()
        os.fsync(handle.fileno())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('validate'); check.add_argument('directory', type=Path); check.add_argument('--release', action='store_true')
    for name in ('review-export', 'review-import'):
        command = commands.add_parser(name); command.add_argument('directory', type=Path); command.add_argument('csv', type=Path)
    command = commands.add_parser('sign')
    command.add_argument('directory', type=Path); command.add_argument('output', type=Path)
    command.add_argument('--key', type=Path, required=True); command.add_argument('--key-id', required=True)
    command.add_argument('--pack-id', required=True); command.add_argument('--version', required=True)
    command.add_argument('--kind', choices=['core', 'speech', 'content', 'pronunciation', 'explainer'], required=True)
    command.add_argument('--tier', choices=['A', 'B', 'C'], required=True)
    command.add_argument('--runtime', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'validate':
            errors = validate(args.directory, args.release)
            for error in errors[:30]: print(error, file=sys.stderr)
            print(f'{len(errors)} validation issues' if errors else 'Content structure validated')
            return int(bool(errors))
        if args.command == 'review-export': review_export(args.directory, args.csv)
        elif args.command == 'review-import': review_import(args.directory, args.csv)
        else: sign(args.directory.resolve(), args.output, args.key, args.key_id, args.pack_id, args.version, args.kind, args.tier, args.runtime)
        return 0
    except (ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
