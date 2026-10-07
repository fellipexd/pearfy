#!/bin/sh
set -eu
umask 077

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$package_dir/../.." && pwd)
run_id=$(date -u '+%Y%m%dT%H%M%SZ')
player_count=${PLAYER_COUNT:-5000}
duration_seconds=${DURATION_SECONDS:-10}
generator_workers=${GENERATOR_WORKERS:-8}
server_host=${SERVER_BIND_HOST:-$(ipconfig getifaddr en0 2>/dev/null || true)}
client_host=${CLIENT_HOST:-$server_host}
server_port=${SERVER_PORT:-49317}
results_dir=${OUTPUT_DIR:-"$package_dir/results/fps-high-remote-$run_id"}
bundle_dir="$results_dir/linux-client"
control_pipe="$results_dir/control.pipe"
server_binary="$package_dir/.build/debug/pearfy-gameserver-fps-bench-server"
server_pid=

case "$player_count:$duration_seconds:$generator_workers:$server_port" in
    *[!0-9:]*|:*|*:) printf '%s\n' "PLAYER_COUNT, DURATION_SECONDS, GENERATOR_WORKERS and SERVER_PORT must be positive integers" >&2; exit 2 ;;
esac
if [ "$player_count" -lt 1 ] || [ "$player_count" -gt 5000 ] || \
   [ "$duration_seconds" -lt 1 ] || [ "$generator_workers" -lt 1 ] || \
   [ "$server_port" -lt 1 ] || [ "$server_port" -gt 65535 ] || [ -z "$server_host" ] || [ -z "$client_host" ]; then
    printf '%s\n' "Invalid player count, duration, worker count, port, or LAN address" >&2
    printf '%s\n' "Set SERVER_BIND_HOST and CLIENT_HOST if the active LAN interface is not en0." >&2
    exit 2
fi

cleanup() {
    if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
        printf '%s\n' stop >&3 2>/dev/null || true
        exec 3>&- 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$results_dir" "$bundle_dir"
chmod 700 "$results_dir" "$bundle_dir"
if lsof -nP -iUDP:"$server_port" > "$results_dir/port-check.txt" 2>&1; then
    printf 'UDP port %s is already in use:\n' "$server_port" >&2
    cat "$results_dir/port-check.txt" >&2
    exit 2
fi

swift run --package-path "$repo_dir" pearfy gameserver template --mode high \
    > "$results_dir/template-high.json" 2> "$results_dir/template-cli.log"
chmod 600 "$results_dir/template-high.json"
swift build --package-path "$package_dir" --product pearfy-gameserver-fps-bench-server \
    > /dev/null 2> "$results_dir/fps-bench-build.log"
if [ ! -x "$server_binary" ]; then
    printf '%s\n' "FPS benchmark server binary was not produced" >&2
    exit 2
fi

cp "$package_dir/fps-loadgen.mjs" "$bundle_dir/fps-loadgen.mjs"
cp "$package_dir/linux-client/install-deps.sh" "$bundle_dir/install-deps.sh"
cp "$package_dir/linux-client/run-client.sh" "$bundle_dir/run-client.sh"
cp "$package_dir/linux-client/README.md" "$bundle_dir/README.md"
chmod 700 "$bundle_dir/install-deps.sh" "$bundle_dir/run-client.sh"
chmod 600 "$bundle_dir/fps-loadgen.mjs" "$bundle_dir/README.md"
cat > "$bundle_dir/connection-info.txt" <<EOF
server_address=$client_host
udp_port=$server_port
players=$player_count
match_size=120
matches=$(((player_count + 119) / 120))
duration_seconds=$duration_seconds
generator_workers=$generator_workers
EOF
chmod 600 "$bundle_dir/connection-info.txt"

mkfifo "$control_pipe"
"$server_binary" \
    --players "$player_count" \
    --match-size 120 \
    --duration "$duration_seconds" \
    --template "$results_dir/template-high.json" \
    --endpoint "$bundle_dir/client-config.json" \
    --client-config "$bundle_dir/client-config.json" \
    --stats "$results_dir/server-stats.json" \
    --bind-host "$server_host" \
    --client-host "$client_host" \
    --port "$server_port" \
    < "$control_pipe" > "$results_dir/server.log" 2>&1 &
server_pid=$!
exec 3> "$control_pipe"

attempt=0
while [ ! -s "$bundle_dir/client-config.json" ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$results_dir/server.log" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 900 ]; then
        printf '%s\n' "Timed out waiting for server setup" >&2
        exit 1
    fi
    sleep 0.1
done
chmod 600 "$bundle_dir/client-config.json"
zip_path="$results_dir/pearfy-fps-high-linux-client.zip"
zip -9 -q -j "$zip_path" \
    "$bundle_dir/README.md" \
    "$bundle_dir/connection-info.txt" \
    "$bundle_dir/client-config.json" \
    "$bundle_dir/fps-loadgen.mjs" \
    "$bundle_dir/install-deps.sh" \
    "$bundle_dir/run-client.sh"
chmod 600 "$zip_path"
printf '%s\n' "$server_pid" > "$results_dir/server.pid"
chmod 600 "$results_dir/server.pid"

printf 'SERVER_READY address=%s port=%s players=%s matches=%s\n' \
    "$server_host" "$server_port" "$player_count" "$(((player_count + 119) / 120))"
printf 'LINUX_CLIENT_ZIP=%s\n' "$zip_path"
printf 'SERVER_LOG=%s\n' "$results_dir/server.log"
printf '%s\n' "Type stop in this terminal after the remote client run to write final server stats."

while IFS= read -r command; do
    case "$command" in
        stop)
            printf '%s\n' stop >&3
            break
            ;;
        status)
            if kill -0 "$server_pid" 2>/dev/null; then
                printf '%s\n' "server process is running"
                tail -n 2 "$results_dir/server.log"
            else
                printf '%s\n' "server process has exited"
            fi
            ;;
        *)
            printf '%s\n' "commands: status, stop"
            ;;
    esac
done
exec 3>&-

if wait "$server_pid"; then
    server_status=0
else
    server_status=$?
fi
server_pid=
printf 'SERVER_STOPPED status=%s stats=%s\n' "$server_status" "$results_dir/server-stats.json"
exit "$server_status"
