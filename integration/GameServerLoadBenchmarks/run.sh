#!/bin/sh
set -eu
umask 077

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$package_dir/../.." && pwd)
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
results_dir=${OUTPUT_DIR:-"$package_dir/results/$run_id"}
mkdir -p "$results_dir"
chmod 700 "$results_dir"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/pearfy-loadbench.XXXXXX")
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

if ! command -v swift >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    printf '%s\n' "swift, node and openssl are required" >&2
    exit 2
fi

printf '%s\n' "run_id=$run_id" "os=$(sw_vers -productVersion 2>/dev/null || uname -sr)" "architecture=$(uname -m)" "swift=$(swift --version | head -1)" "node=$(node --version)" "node_count=$(sysctl -n hw.ncpu 2>/dev/null || printf unknown)" "memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || printf unknown)" "loopback=true" "server_and_loadgen_same_host=true" > "$results_dir/host.txt"

swift build --package-path "$repo_dir" --product pearfy > /dev/null 2> "$results_dir/pearfy-cli-build.log"
swift build --package-path "$package_dir" > /dev/null 2> "$results_dir/loadbench-build.log"
server_binary="$package_dir/.build/debug/pearfy-gameserver-loadbench-server"

run_case() {
    scenario_name=$1
    mode=$2
    transport=$3
    offered_players=$4
    rate_hz=$5
    payload_bytes=$6
    duration_seconds=$7
    if [ -n "${DURATION_SECONDS:-}" ]; then duration_seconds=$DURATION_SECONDS; fi
    if [ -n "${PLAYER_LIMIT:-}" ]; then offered_players=$PLAYER_LIMIT; fi

    scenario_dir="$results_dir/$scenario_name"
    private_dir="$tmp_root/$scenario_name"
    mkdir -p "$scenario_dir" "$private_dir"
    chmod 700 "$private_dir"

    printf '%s\n' "Running $scenario_name: $offered_players offered players, $mode/$transport, ${duration_seconds}s"
    swift run --package-path "$repo_dir" pearfy gameserver template --mode "$mode" \
        > "$scenario_dir/template.json" 2> "$scenario_dir/template-cli.log"

    certificate="$private_dir/certificate.pem"
    private_key="$private_dir/private-key.pem"
    if [ "$transport" = websocket ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
            -keyout "$private_key" -out "$certificate" \
            -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
            > /dev/null 2>&1
    else
        certificate=-
        private_key=-
    fi

    client_config="$private_dir/client-config.json"
    endpoint="$private_dir/endpoint.json"
    server_stats="$scenario_dir/server-stats.json"
    control_pipe="$private_dir/control.pipe"
    mkfifo "$control_pipe"
    "$server_binary" \
        --scenario "$scenario_name" \
        --mode "$mode" \
        --transport "$transport" \
        --players "$offered_players" \
        --rate "$rate_hz" \
        --payload "$payload_bytes" \
        --duration "$duration_seconds" \
        --template "$scenario_dir/template.json" \
        --endpoint "$endpoint" \
        --client-config "$client_config" \
        --stats "$server_stats" \
        --certificate "$certificate" \
        --private-key "$private_key" \
        < "$control_pipe" > "$scenario_dir/server.log" 2>&1 &
    current_server_pid=$!
    exec 3> "$control_pipe"

    attempt=0
    while [ ! -s "$client_config" ]; do
        if ! kill -0 "$current_server_pid" 2>/dev/null; then
            cat "$scenario_dir/server.log" >&2
            return 1
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -gt 300 ]; then
            printf '%s\n' "timed out waiting for $scenario_name server startup" >&2
            return 1
        fi
        sleep 0.1
    done
    chmod 600 "$client_config" "$endpoint"

    printf '%s\n' 'elapsed_seconds,cpu_percent,rss_kib' > "$scenario_dir/resource-samples.csv"
    sampled_server_pid=$current_server_pid
    (
        start_epoch=$(date +%s)
        while kill -0 "$sampled_server_pid" 2>/dev/null; do
            sample_epoch=$(date +%s)
            elapsed=$((sample_epoch - start_epoch))
            ps -p "$sampled_server_pid" -o %cpu=,rss= 2>/dev/null | awk -v elapsed="$elapsed" '{gsub(/^[ \t]+|[ \t]+$/, ""); if (NF >= 2) print elapsed "," $1 "," $2}'
            sleep 1
        done
    ) >> "$scenario_dir/resource-samples.csv" &
    current_sampler_pid=$!

    client_status=0
    if node "$package_dir/loadgen.mjs" --config "$client_config" --report "$scenario_dir/client-result.json" \
        > "$scenario_dir/client.log" 2>&1; then
        client_status=0
    else
        client_status=$?
    fi
    printf '%s\n' stop >&3
    exec 3>&-
    if wait "$current_server_pid"; then
        server_status=0
    else
        server_status=$?
    fi
    current_server_pid=
    wait "$current_sampler_pid" 2>/dev/null || true
    current_sampler_pid=
    python3 "$package_dir/report.py" --scenario-dir "$scenario_dir"
    if [ "$client_status" -ne 0 ] || [ "$server_status" -ne 0 ]; then
        printf '%s\n' "scenario failed: $scenario_name (client=$client_status server=$server_status)" >&2
        return 1
    fi
}

case "${ONLY_SCENARIO:-all}" in
    all)
        run_case light-pointclick light websocket 1000 1 128 10
        run_case medium-mmorpg medium websocket 2000 10 256 10
        run_case high-fps high udp 5000 60 64 5
        run_case high-mmorpg-complex high udp 5000 20 900 5
        ;;
    light-pointclick) run_case light-pointclick light websocket 1000 1 128 10 ;;
    medium-mmorpg) run_case medium-mmorpg medium websocket 2000 10 256 10 ;;
    high-fps) run_case high-fps high udp 5000 60 64 5 ;;
    high-mmorpg-complex) run_case high-mmorpg-complex high udp 5000 20 900 5 ;;
    *) printf '%s\n' "unknown ONLY_SCENARIO: $ONLY_SCENARIO" >&2; exit 2 ;;
esac

python3 "$package_dir/report.py" --results-dir "$results_dir"
printf 'Reports and logs: %s\n' "$results_dir"
