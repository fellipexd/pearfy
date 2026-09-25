#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

{
  printf 'timestamp_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'commit='
  if commit="$(git rev-parse HEAD 2>/dev/null)"; then
    printf '%s\n' "$commit"
  else
    printf '%s\n' 'unversioned-worktree'
  fi
  printf 'host='
  uname -a
  printf 'toolchain:\n'
  swift --version
  printf 'build_configuration=release\n'
  printf 'external_services=none; outbound HTTP uses an in-process stub\n'
  printf '\n'
} >&2

swift run -c release pearfy-bench --module-baselines-only "$@"
