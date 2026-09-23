#!/usr/bin/env python3
"""Measure cold startup and idle process PSS; never equate emulator results with phone acceptance."""
import argparse
import json
import re
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--serial', required=True)
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 3 <= args.runs <= 20:
        parser.error('runs must be between 3 and 20')
    def adb(*commands):
        return subprocess.run([args.adb, '-s', args.serial, *commands], check=True,
                              capture_output=True, text=True, timeout=60).stdout.strip()
    package = 'ai.vaachak.vaachak_app'
    times = []
    for _ in range(args.runs):
        adb('shell', 'am', 'force-stop', package)
        output = adb('shell', 'am', 'start', '-W', '-n', package+'/.MainActivity')
        match = re.search(r'TotalTime:\s*(\d+)', output)
        if 'Status: ok' not in output or not match:
            raise RuntimeError('App did not complete a measured cold launch')
        times.append(int(match.group(1)))
    memory = adb('shell', 'dumpsys', 'meminfo', package)
    match = re.search(r'TOTAL PSS:\s*(\d+)', memory)
    report = {'measuredAt': datetime.now(timezone.utc).isoformat(),
              'model': adb('shell', 'getprop', 'ro.product.model'),
              'sdk': adb('shell', 'getprop', 'ro.build.version.sdk'),
              'emulator': adb('shell', 'getprop', 'ro.kernel.qemu') == '1',
              'coldStartMs': times, 'medianColdStartMs': statistics.median(times),
              'p95ColdStartMs': sorted(times)[min(len(times)-1, int(len(times)*.95))],
              'idlePssKb': int(match.group(1)) if match else None,
              'scope': 'Startup and idle process only; no speech, thermal, battery or physical-phone acceptance.'}
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
