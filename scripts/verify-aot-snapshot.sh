#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build --target HelloPearfy

generated="$root/.build/plugins/outputs/pearfy/HelloPearfy/destination/PearfyDiscoveryPlugin/PearfyGeneratedRegistry.swift"
snapshot="$root/Benchmarks/Baselines/AOT-HELLOPEARFY-REGISTRY.swift"

if [[ ! -f "$generated" ]]; then
  printf 'Generated registry not found: %s\n' "$generated" >&2
  exit 1
fi

diff -u \
  <(python3 -c 'import pathlib,sys; sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\n"))' "$snapshot") \
  <(python3 -c 'import pathlib,sys; sys.stdout.buffer.write(pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\n"))' "$generated")
printf 'AOT registry snapshot matches generated output.\n'
