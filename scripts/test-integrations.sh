#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

export PEARFY_TEST_POSTGRES_HOST="${PEARFY_TEST_POSTGRES_HOST:-127.0.0.1}"
export PEARFY_TEST_POSTGRES_PORT="${PEARFY_TEST_POSTGRES_PORT:-5432}"
export PEARFY_TEST_POSTGRES_USER="${PEARFY_TEST_POSTGRES_USER:-$(id -un)}"
export PEARFY_TEST_POSTGRES_DATABASE="${PEARFY_TEST_POSTGRES_DATABASE:-postgres}"
export PEARFY_TEST_REDIS_HOST="${PEARFY_TEST_REDIS_HOST:-127.0.0.1}"
export PEARFY_TEST_REDIS_PORT="${PEARFY_TEST_REDIS_PORT:-6379}"

case "$(uname -s)" in
  Darwin) plugin_extension="dylib" ;;
  Linux) plugin_extension="so" ;;
  *) printf 'Unsupported host for Swift Testing macro lookup\n' >&2; exit 1 ;;
esac

runtime_root="$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')"
testing_plugin="$(python3 -c '
import pathlib
import sys

plugins = pathlib.Path(sys.argv[1]) / "host" / "plugins"
extension = sys.argv[2]
candidates = [
    plugins / "testing" / f"libTestingMacros.{extension}",
    plugins / f"libTestingMacros.{extension}",
]
if plugins.is_dir():
    candidates.extend(sorted(plugins.rglob(f"*TestingMacros*.{extension}")))
match = next((candidate for candidate in candidates if candidate.is_file()), None)
print(match or "")
' "$runtime_root" "$plugin_extension")"
if [[ -n "$testing_plugin" ]]; then
  swift test "$@" \
    -Xswiftc -load-plugin-library \
    -Xswiftc "$testing_plugin"
else
  printf 'Testing macro plugin not found under %s/host/plugins; trying SwiftPM plugin discovery\n' "$runtime_root" >&2
  swift test "$@"
fi
