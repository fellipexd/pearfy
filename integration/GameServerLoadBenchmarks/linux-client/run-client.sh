#!/bin/sh
set -eu
umask 077

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
config_path="$package_dir/client-config.json"
if [ ! -r "$config_path" ]; then
    printf '%s\n' "client-config.json is missing; extract the complete archive first" >&2
    exit 2
fi
if ! command -v node >/dev/null 2>&1; then
    printf '%s\n' "Node.js is missing; run ./install-deps.sh first" >&2
    exit 2
fi
node_major=$(node -p 'Number(process.versions.node.split(".")[0])')
if [ "$node_major" -lt 18 ]; then
    printf '%s\n' "Node.js 18 or newer is required" >&2
    exit 2
fi
chmod 600 "$config_path"

duration_seconds=${DURATION_SECONDS:-10}
generator_workers=${GENERATOR_WORKERS:-8}
case "$duration_seconds:$generator_workers" in
    *[!0-9:]*|:*|*:) printf '%s\n' "DURATION_SECONDS and GENERATOR_WORKERS must be positive integers" >&2; exit 2 ;;
esac
if [ "$duration_seconds" -lt 1 ] || [ "$generator_workers" -lt 1 ]; then
    printf '%s\n' "DURATION_SECONDS and GENERATOR_WORKERS must be positive integers" >&2
    exit 2
fi

run_id=$(date -u '+%Y%m%dT%H%M%SZ')
results_dir=${OUTPUT_DIR:-"$package_dir/results/$run_id"}
mkdir -p "$results_dir"
chmod 700 "$results_dir"
if FPS_GENERATOR_WORKERS="$generator_workers" FPS_DURATION_SECONDS="$duration_seconds" \
    FPS_CLIENT_BIND_HOST="${CLIENT_BIND_HOST:-0.0.0.0}" \
    node "$package_dir/fps-loadgen.mjs" --config "$config_path" --report "$results_dir/client-result.json" \
    > "$results_dir/client.log" 2>&1; then
    cat "$results_dir/client.log"
    printf 'Client results: %s\n' "$results_dir"
else
    client_status=$?
    cat "$results_dir/client.log" >&2
    printf 'Client failed with status %s; logs: %s\n' "$client_status" "$results_dir" >&2
    exit "$client_status"
fi
