#!/usr/bin/env bash
set -euo pipefail
package=ai.vaachak.vaachak_app
output=${1:-benchmark-device.txt}
adb get-state >/dev/null
{
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  adb shell getprop ro.product.model
  adb shell getprop ro.build.version.sdk
  adb shell cat /proc/meminfo
  adb shell dumpsys battery
  adb shell am force-stop "$package"
  adb shell am start -W -n "$package/.MainActivity"
  adb shell dumpsys meminfo "$package"
  adb shell dumpsys thermalservice
} > "$output"
printf 'Device measurements written to %s\n' "$output"
