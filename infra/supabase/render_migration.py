"""Render isolated environment schemas from the reviewed migration template."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[2]
template = (Path(__file__).parent / 'templates/environment.sql').read_text()
header = 'CREATE SCHEMA IF NOT EXISTS extensions;\nCREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;\n'
nodes = json.loads((root / 'apps/vaachak_app/assets/skill_graph.json').read_text())
parts = [header]
for environment in ('dev', 'qa', 'prod'):
    parts.append(template.replace('__ENV__', environment))
    values = ',\n'.join("('%s','%s')" % (n['id'], n['skill']) for n in nodes)
    parts.append(f'INSERT INTO {environment}.skill_nodes(id,skill) VALUES\n{values};\n')
(Path(__file__).parent / 'migrations/202609230001_platform.sql').write_text('\n'.join(parts))

phase3 = (Path(__file__).parent / 'templates/phase3.sql').read_text()
(Path(__file__).parent / 'migrations/202609230002_phase3.sql').write_text('\n'.join(phase3.replace('__ENV__', e) for e in ('dev', 'qa', 'prod')) + "\nNOTIFY pgrst, 'reload schema';\n")
