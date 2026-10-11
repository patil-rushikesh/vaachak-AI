#!/usr/bin/env python3
"""Run the bounded draft worker; no draft is published automatically."""

import argparse
import logging
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "classroom_web/server"))
import main
import db
import ai
from generation_jobs import work_once


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    ai.load_env_file()
    db.init()
    while True:
        worked = work_once()
        if args.once:
            return
        if not worked:
            time.sleep(5)


if __name__ == "__main__":
    run()
