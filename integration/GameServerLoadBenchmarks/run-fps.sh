#!/bin/sh
set -eu
umask 077

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$package_dir/../.." && pwd)
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
results_dir=${OUTPUT_DIR:-"$package_dir/results/fps-high-$run_id"}
duration_seconds=${DURATION_SECONDS:-10}
generator_workers=${GENERATOR_WORKERS:-8}
player_counts=${PLAYER_COUNTS:-"120 480 960 1920 3000 5000"}
mkdir -p "$results_dir"
chmod 700 "$results_dir"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/pearfy-fpsbench.XXXXXX")
current_server_pid=
current_sampler_pid=

cleanup() {
    if [ -n "$current_server_pid" ] && kill -0 "$current_server_pid" 2>/dev/null; then
        kill "$current_server_pid" 2>/dev/null || true
        wait "$current_server_pid" 2>/dev/null || true
    fi
    if [ -n "$current_sampler_pid" ]; then
        kill "$current_sampler_pid" 2>/dev/null || true
        wait "$current_sampler_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_root"
}
trap cleanup EXIT HUP INT TERM

if ! command -v swift >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "swift, node and python3 are required" >&2
    exit 2
fi
case "$duration_seconds:$generator_workers" in
    *[!0-9:]*|:*|*:) printf '%s\n' "DURATION_SECONDS and GENERATOR_WORKERS must be positive integers" >&2; exit 2 ;;
esac
if [ "$duration_seconds" -lt 1 ] || [ "$generator_workers" -lt 1 ]; then
    printf '%s\n' "DURATION_SECONDS and GENERATOR_WORKERS must be positive integers" >&2
    exit 2
fi

printf '%s\n' \
    "run_id=$run_id" \
    "focus=fps-high-combat-map" \
    "os=$(sw_vers -productVersion 2>/dev/null || uname -sr)" \
    "architecture=$(uname -m)" \
    "swift=$(swift --version | head -1)" \
    "node=$(node --version)" \
    "node_count=$(sysctl -n hw.ncpu 2>/dev/null || printf unknown)" \
    "memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || printf unknown)" \
    "loopback=true" \
    "server_and_loadgen_same_host=true" \
    "match_size=120" \
    "requested_player_counts=$player_counts" \
    "duration_seconds=$duration_seconds" \
    "generator_workers=$generator_workers" > "$results_dir/host.txt"

swift run --package-path "$repo_dir" pearfy gameserver template --mode high \
    > "$results_dir/template-high.json" 2> "$results_dir/template-cli.log"
chmod 600 "$results_dir/template-high.json"
swift build --package-path "$package_dir" --product pearfy-gameserver-fps-bench-server \
    > /dev/null 2> "$results_dir/fps-bench-build.log"
server_binary="$package_dir/.build/debug/pearfy-gameserver-fps-bench-server"

run_case() {
    offered_players=$1
    case_dir="$results_dir/players-$offered_players"
    private_dir="$tmp_root/players-$offered_players"
    mkdir -p "$case_dir" "$private_dir"
    chmod 700 "$private_dir"
    control_pipe="$private_dir/control.pipe"
    client_config="$private_dir/client-config.json"
    endpoint="$private_dir/endpoint.json"
    mkfifo "$control_pipe"

    printf '%s\n' "Running FPS High: $offered_players players in 120-player matches, ${duration_seconds}s, ${generator_workers} client workers"
    "$server_binary" \
        --players "$offered_players" \
        --match-size 120 \
        --duration "$duration_seconds" \
        --template "$results_dir/template-high.json" \
        --endpoint "$endpoint" \
        --client-config "$client_config" \
        --stats "$case_dir/server-stats.json" \
        < "$control_pipe" > "$case_dir/server.log" 2>&1 &
    current_server_pid=$!
    exec 3> "$control_pipe"

    attempt=0
    while [ ! -s "$client_config" ]; do
        if ! kill -0 "$current_server_pid" 2>/dev/null; then
            cat "$case_dir/server.log" >&2
            return 1
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -gt 900 ]; then
            printf '%s\n' "timed out waiting for $offered_players-player server setup" >&2
            return 1
        fi
        sleep 0.1
    done
    chmod 600 "$client_config" "$endpoint"

    printf '%s\n' 'elapsed_seconds,cpu_percent,rss_kib' > "$case_dir/resource-samples.csv"
    sampled_server_pid=$current_server_pid
    (
        start_epoch=$(date +%s)
        while kill -0 "$sampled_server_pid" 2>/dev/null; do
            sample_epoch=$(date +%s)
            elapsed=$((sample_epoch - start_epoch))
            ps -p "$sampled_server_pid" -o %cpu=,rss= 2>/dev/null | awk -v elapsed="$elapsed" '{gsub(/^[ \t]+|[ \t]+$/, ""); if (NF >= 2) print elapsed "," $1 "," $2}'
            sleep 1
        done
    ) >> "$case_dir/resource-samples.csv" &
    current_sampler_pid=$!

    client_status=0
    if FPS_GENERATOR_WORKERS="$generator_workers" node "$package_dir/fps-loadgen.mjs" \
        --config "$client_config" --report "$case_dir/client-result.json" \
        > "$case_dir/client.log" 2>&1; then
        client_status=0
    else
        client_status=$?
    fi
    printf '%s\n' stop >&3 || true
    exec 3>&-
    if wait "$current_server_pid"; then server_status=0; else server_status=$?; fi
    current_server_pid=
    wait "$current_sampler_pid" 2>/dev/null || true
    current_sampler_pid=

    if [ -s "$case_dir/client-result.json" ] && [ -s "$case_dir/server-stats.json" ]; then
        python3 "$package_dir/fps-report.py" --scenario-dir "$case_dir"
    else
        printf '%s\n' "FPS report skipped because client or server result is missing; see $case_dir/*.log" >&2
    fi
    if [ "$client_status" -ne 0 ] || [ "$server_status" -ne 0 ]; then
        printf '%s\n' "FPS scenario failed at $offered_players players (client=$client_status server=$server_status)" >&2
        return 1
    fi
}

for offered_players in $player_counts; do
    case "$offered_players" in
        *[!0-9]*|'') printf '%s\n' "PLAYER_COUNTS must be positive integers separated by spaces" >&2; exit 2 ;;
    esac
    if [ "$offered_players" -lt 1 ] || [ "$offered_players" -gt 5000 ]; then
        printf '%s\n' "FPS benchmark supports 1 through 5000 players" >&2
        exit 2
    fi
    run_case "$offered_players"
done

python3 "$package_dir/fps-report.py" --results-dir "$results_dir"
printf 'FPS High reports and logs: %s\n' "$results_dir"
