#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

case "$(uname -s)" in
  Darwin) plugin_extension="dylib" ;;
  Linux) plugin_extension="so" ;;
  *) printf 'Unsupported host for Swift Testing macro lookup\n' >&2; exit 1 ;;
esac

runtime_root="$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')"
testing_plugin="$runtime_root/host/plugins/testing/libTestingMacros.$plugin_extension"
if [[ ! -f "$testing_plugin" ]]; then
  printf 'Testing macro plugin not found: %s\n' "$testing_plugin" >&2
  exit 1
fi

swift test "$@" \
  -Xswiftc -load-plugin-library \
  -Xswiftc "$testing_plugin"
