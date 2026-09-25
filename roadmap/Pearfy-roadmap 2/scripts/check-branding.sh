#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Comparative references are documentation-only.
pattern="$(printf '%s[[:space:]_-]*%s|%s%s' spr''ing bo''ot swi''ft bo''ot)"
if grep -RinE --exclude='*.md' --exclude='*.zip' --exclude-dir='.build' --exclude-dir='.git' "$pattern" Package.swift Sources Tests scripts .gitignore 2>/dev/null; then
  printf '%s\n' 'Branding check failed: reference found outside Markdown.' >&2
  exit 1
fi
printf '%s\n' 'Branding check passed.'
