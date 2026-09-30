#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

case "$(uname -s)" in
  Darwin) plugin_extension="dylib" ;;
  Linux) plugin_extension="so" ;;
  *) printf 'Unsupported host for Swift Testing macro lookup\n' >&2; exit 1 ;;
esac

runtime_root="$(swift -print-target-info | sed -n 's/^[[:space:]]*"runtimeResourcePath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
plugins="$runtime_root/host/plugins"
testing_plugin=""
for candidate in \
  "$plugins/testing/libTestingMacros.$plugin_extension" \
  "$plugins/libTestingMacros.$plugin_extension"; do
  if [[ -f "$candidate" ]]; then
    testing_plugin="$candidate"
    break
  fi
done
if [[ -z "$testing_plugin" && -d "$plugins" ]]; then
  testing_plugin="$(find "$plugins" -type f -name "*TestingMacros*.$plugin_extension" -print -quit)"
fi
if [[ -n "$testing_plugin" ]]; then
  swift test "$@" \
    -Xswiftc -load-plugin-library \
    -Xswiftc "$testing_plugin"
else
  printf 'Testing macro plugin not found under %s/host/plugins; trying SwiftPM plugin discovery\n' "$runtime_root" >&2
  swift test "$@"
fi
