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
testing_plugin="$runtime_root/host/plugins/testing/libTestingMacros.$plugin_extension"
if [[ ! -f "$testing_plugin" ]]; then
  printf 'Testing macro plugin not found: %s\n' "$testing_plugin" >&2
  exit 1
fi

swift test "$@" \
  -Xswiftc -load-plugin-library \
  -Xswiftc "$testing_plugin"
