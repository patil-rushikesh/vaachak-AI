"""Start Vaachak Classroom.   python run.py [--seed] [--port 8000]

--seed   reset the database and load demo teacher / student / self-learner accounts
"""
import argparse, os, sys
from pathlib import Path

ROOT = Path(__file__).parent
sys.path.insert(0, str(ROOT / "server"))
os.environ.setdefault("VAACHAK_DATA", str(ROOT / "data"))

ap = argparse.ArgumentParser()
ap.add_argument("--seed", action="store_true")
ap.add_argument("--port", type=int, default=8000)
ap.add_argument("--host", default="127.0.0.1")
a = ap.parse_args()

if a.seed:
    import seed
    seed.seed(reset=True)

import uvicorn
print(f"\nAPI documentation: http://localhost:{a.port}/api/docs\n")
uvicorn.run("main:app", host=a.host, port=a.port, log_level="warning")
