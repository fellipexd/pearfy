# Pearfy GameServer load benchmarks

The original four-case harness measures the existing Pearfy WSS and authenticated UDP transport plus the bounded `GameRealtimeSimulation` queue. Its callbacks are synthetic acknowledgements. The focused FPS High runner below adds a benchmark-only 60 Hz combat/map workload. Neither runner changes the Pearfy runtime or CLI templates.

## Four workloads

| Scenario | CLI mode | Offered players | Transport | Offered rate | Input bytes |
|---|---:|---:|---|---:|---:|
| `light-pointclick` | light | 1,000 | WSS/TLS, JSON | 1 action/s | 128 |
| `medium-mmorpg` | medium | 2,000 | WSS/TLS, JSON | 10 updates/s | 256 |
| `high-fps` | high | 5,000 | secure UDP, binary | 60 inputs/s | 64 |
| `high-mmorpg-complex` | high | 5,000 | secure UDP, binary | 20 updates/s | 900 |

The runner gets mode JSON directly from `pearfy gameserver template`. It keeps preset admission limits unchanged: 32 light sessions, 256 medium sessions and 2,048 high sessions. The offered population is intentionally larger, so reports include accepted/rejected capacity and overload behavior. High mode's template still says `udpEnabled: false`; the test server enables the already implemented secure UDP adapter only for this isolated local run and uses ephemeral test keys.

## Run

Run all four in sequence:

```sh
integration/GameServerLoadBenchmarks/run.sh
```

By default the WSS cases run for 10 seconds and UDP cases for 5 seconds. Set `DURATION_SECONDS=3` for a shorter smoke run. Set `OUTPUT_DIR=/path/to/results` to choose an output directory. Results are written under `results/<UTC timestamp>/`; the runner preserves generated reports and logs but deletes its temporary tickets, UDP keys and TLS keys on exit.

To check the harness wiring without running the requested population, set both `PLAYER_LIMIT=2` and `DURATION_SECONDS=1` and use a temporary `OUTPUT_DIR`. Those results are only a wiring smoke test, not performance data.

To rerun one scenario while iterating on the harness, set `ONLY_SCENARIO` to one of the four table names; the default `all` runs every case.

Each case records loopback echo RTT percentiles, handshake time (WSS), offered input rate and response/probe rate, bytes, connection/admission outcomes, input queue/tick counters, server process CPU/RSS samples, and client generator CPU/RSS. For UDP, capacity-rejected players make one unregistered admission attempt; admitted players send their full configured input rate. The server echoes only a one-per-second-per-player latency probe to avoid turning the load generator into an acknowledgment-flood bottleneck. The combined `LOAD-REPORT.md` records OS, architecture and tool versions.

## Focused FPS High combat and map run

Run the FPS High workload across the default player-count ladder, including the requested 5,000 players:

```sh
integration/GameServerLoadBenchmarks/run-fps.sh
```

The default ladder is `120 480 960 1920 3000 5000`, split into simultaneous 120-player matches (the 5,000-player case has 41 full matches and one match with 80 players). Each scenario runs for 10 seconds by default. Change `DURATION_SECONDS`, `GENERATOR_WORKERS`, `PLAYER_COUNTS`, or `OUTPUT_DIR` to adjust a run. For example, `PLAYER_COUNTS="120 5000" DURATION_SECONDS=2` measures a short low/high comparison.

The runner generates its high profile from `pearfy gameserver template --mode high`, then uses a benchmark-only UDP listener ceiling of up to 5,000 sessions and a bounded packet-rate limit; the CLI template remains at 2,048 sessions with UDP disabled. Match input queues and byte budgets are divided from the template limits. Private client tickets and session keys are kept in a mode-0700 temporary directory and deleted when the run exits.

The load generator shards encrypted binary UDP clients across child Node processes. The Swift server runs one structured-concurrency task and match actor per 120-player match. Each tick simulates movement, wall collision, team combat, line-of-sight hitscan, armor, health, ammunition/reload, loot interaction, a shrinking safe zone and AOI snapshots. The report records tick overruns, observed Swift thread IDs, RTT probes, input delivery/admission, combat events, AOI work, CPU and RSS.

### Run the generator from a Linux PC

On a Mac that can be reached from the Linux PC, start the waiting server and create a one-run client ZIP:

```sh
integration/GameServerLoadBenchmarks/run-remote-fps-server.sh
```

The default run offers 5,000 players for 10 seconds on UDP port `49317`. The server binds to the Mac's `en0` address; set `SERVER_BIND_HOST` if that is not the reachable interface. Copy the printed ZIP path to the Linux PC, extract it, then install Node.js 18+ and run the generator:

```sh
unzip pearfy-fps-high-linux-client.zip -d pearfy-fps-high-client
cd pearfy-fps-high-client
./install-deps.sh
./run-client.sh
```

The client configuration contains one-run session credentials, so keep the ZIP private and discard it after the benchmark. Both machines need a network path that permits UDP to the Mac's printed address and port. Type `status` in the Mac terminal to inspect the waiting server; type `stop` after the client run to write final server stats. The server pauses its simulated match ticks until the first valid client input arrives.

These are synthetic same-host loopback results, not internet ping, a Warzone/CS rules implementation, a production capacity guarantee or a performance optimization. The transport event loop still handles UDP ingress, while Swift task-group work runs match simulation actors on the cooperative concurrency pool; the report counts observed threads rather than claiming one thread per match. `FPS-HIGH-REPORT.md` summarizes the ladder and each `players-N/REPORT.md` has detailed metrics and links to raw logs/JSON/CSV in the same directory.

## Limits of interpretation

- Server and load generator run on the same Mac. RTT is local request/response time, not internet ping; client encryption, CPU contention, and loopback scheduling affect results.
- The original four acknowledgement cases leave preset admission caps unchanged, so their offered counts are not admitted-player counts. The focused FPS runner overrides the benchmark listener session cap and records admitted benchmark sessions separately from inputs actually processed; it does not claim sustainable production capacity.
- The focused FPS fixture adds combat, map collision, loot, zone damage and AOI work. It is not a complete FPS implementation and does not exercise MMO persistence, matchmaking, Agones scheduling or production deployment.
- High-mode UDP is test-only here. This harness does not alter the CLI template, enable UDP in production, or certify target hardware.
- Do not compare runs unless the host, OS load, duration, profile JSON, offered rates and payload sizes match.
