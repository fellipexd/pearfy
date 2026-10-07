#!/usr/bin/env python3
import argparse
import csv
import json
import math
from pathlib import Path


def load_json(path):
    return json.loads(path.read_text())


def round_value(value, places=2):
    if value is None:
        return None
    return round(value, places)


def read_resources(path):
    samples = []
    if not path.exists():
        return samples
    with path.open(newline="") as source:
        for row in csv.DictReader(source):
            try:
                samples.append({"elapsedSeconds": int(row["elapsed_seconds"]),
                                "cpuPercent": float(row["cpu_percent"]),
                                "rssKiB": int(float(row["rss_kib"]))})
            except (KeyError, ValueError):
                continue
    return samples


def create_case_report(directory):
    server = load_json(directory / "server-stats.json")
    client = load_json(directory / "client-result.json")
    resources = read_resources(directory / "resource-samples.csv")
    rtt = client.get("rttMilliseconds", {})
    matches = server.get("matches", [])
    total = lambda field: sum(match.get(field, 0) for match in matches)
    active = server.get("activePlayers", 0)
    seconds = max(client.get("measurementDurationMilliseconds", 0) / 1000, 0.001)
    sent = client.get("sentMessages", 0)
    received = server.get("inputsReceived", 0)
    probes_sent = client.get("probeMessagesSent", client.get("receivedResponses", 0) + client.get("lateOrLostResponses", 0))
    probe_coverage = client.get("receivedResponses", 0) / probes_sent if probes_sent else 0
    server_uptime_seconds = server.get("uptimeMilliseconds", 0) / 1000
    shots = total("shots")
    hits = total("hits")
    summary = {
        "scenario": server.get("scenario"),
        "templateMode": server.get("templateMode"),
        "transport": server.get("transport"),
        "offeredPlayers": server.get("offeredPlayers"),
        "activePlayers": active,
        "matchSize": server.get("matchSize"),
        "matchCount": server.get("matchCount"),
        "matchPlayerCounts": server.get("matchPlayerCounts"),
        "templateSessionLimit": server.get("templateSessionLimit"),
        "benchmarkSessionLimit": server.get("benchmarkSessionLimit"),
        "benchmarkCapacityOverride": server.get("benchmarkCapacityOverride"),
        "listenerMaximumPacketsPerSecond": server.get("listenerMaximumPacketsPerSecond"),
        "tickRateHz": server.get("tickRateHz"),
        "measurementDurationSeconds": round_value(seconds, 3),
        "serverUptimeSeconds": round_value(server_uptime_seconds, 3),
        "setupMilliseconds": round_value(server.get("setupMilliseconds", 0)),
        "uptimeMilliseconds": round_value(server.get("uptimeMilliseconds", 0)),
        "inputMessagesSent": sent,
        "inputMessagesReceived": received,
        "inputReceiveRatePerSecond": round_value(received / seconds),
        "inputAcceptanceRatePercent": round_value(server.get("inputsAccepted", 0) * 100 / received if received else 0),
        "senderDeliveryPercent": round_value(received * 100 / sent if sent else 0),
        "probeResponses": client.get("receivedResponses", 0),
        "probeMessagesSent": probes_sent,
        "unansweredProbesAfterDrain": client.get("lateOrLostResponses", 0),
        "probeResponseCoveragePercent": round_value(min(100, probe_coverage * 100)),
        "rttMilliseconds": rtt,
        "serverCpuPercentAverage": round_value(sum(sample["cpuPercent"] for sample in resources) / len(resources) if resources else None),
        "serverCpuPercentPeak": round_value(max((sample["cpuPercent"] for sample in resources), default=None)),
        "serverRSSMiBPeak": round_value(max((sample["rssKiB"] for sample in resources), default=0) / 1024),
        "generatorWorkerProcesses": client.get("loadGenerator", {}).get("workerCount", 0),
        "generatorCpuSeconds": round_value(client.get("loadGenerator", {}).get("cpuTotalMicroseconds", 0) / 1_000_000),
        "generatorWorkerRSSMiBSum": round_value(client.get("loadGenerator", {}).get("rssAfterBytes", 0) / (1024 * 1024)),
        "simulationTickCount": server.get("ticksTotal", 0),
        "effectiveSimulationTickRateHzPerMatch": round_value(server.get("ticksTotal", 0) / server.get("matchCount", 1) / server_uptime_seconds if server_uptime_seconds else 0),
        "simulationOverruns": server.get("tickOverruns", 0),
        "simulationOverrunPercent": round_value(server.get("tickOverruns", 0) * 100 / server.get("ticksTotal", 1)),
        "simulationAverageTickMilliseconds": round_value(server.get("averageTickMilliseconds", 0)),
        "simulationMaximumTickMilliseconds": round_value(server.get("maxTickMilliseconds", 0)),
        "simulationWorkerThreadCount": server.get("workerThreadCount", 0),
        "shots": shots,
        "hits": hits,
        "hitRatePercent": round_value(hits * 100 / shots if shots else 0),
        "damage": total("damage"),
        "eliminations": total("eliminations"),
        "wallCollisionBlocks": total("wallCollisionBlocks"),
        "safeZoneDamageEvents": total("zoneDamageEvents"),
        "lootPickups": total("lootPickups"),
        "aoisBuilt": total("aoisBuilt"),
        "averageVisibleEntitiesPerAOI": round_value(total("visibleEntitiesTotal") / total("aoisBuilt") if total("aoisBuilt") else 0),
        "replicatedStateMiB": round_value(total("replicatedStateBytes") / (1024 * 1024)),
        "resourceSamples": resources,
    }
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    lines = [
        f"# FPS High benchmark — {active:,} players",
        "",
        f"- Matches: {summary['matchCount']} × up to {summary['matchSize']} players; last match size {summary['matchPlayerCounts'][-1]}.",
        f"- Template: `{summary['templateMode']}`; transport: `{summary['transport']}`; tick: {summary['tickRateHz']} Hz.",
        f"- Session limit: template {summary['templateSessionLimit']:,}; benchmark listener {summary['benchmarkSessionLimit']:,}; capacity override: `{summary['benchmarkCapacityOverride']}`.",
        f"- Benchmark UDP ceiling: {summary['listenerMaximumPacketsPerSecond']:,} packets/s at the listener.",
        f"- Input load: {sent:,} datagrams offered, {received:,} authenticated gameplay inputs received ({summary['inputReceiveRatePerSecond']:,.0f}/s; {summary['senderDeliveryPercent']:.1f}% of offered). Queue accepted {server.get('inputsAccepted', 0):,} ({summary['inputAcceptanceRatePercent']:.1f}% of received).",
        f"- Probe RTT: {rtt.get('samples', 0):,}/{probes_sent:,} responses/probes sent ({summary['probeResponseCoveragePercent']:.2f}% coverage); p50 {rtt.get('p50', 'n/a')} ms, p95 {rtt.get('p95', 'n/a')} ms, p99 {rtt.get('p99', 'n/a')} ms; {summary['unansweredProbesAfterDrain']:,} unanswered after a 1 s drain.",
        f"- Server: sampled CPU avg/peak {summary['serverCpuPercentAverage'] if summary['serverCpuPercentAverage'] is not None else 'n/a'}%/{summary['serverCpuPercentPeak'] if summary['serverCpuPercentPeak'] is not None else 'n/a'}%, sampled peak RSS {summary['serverRSSMiBPeak']:.1f} MiB; simulation {summary['simulationWorkerThreadCount']} distinct Swift worker thread IDs observed across match ticks.",
        f"- Tick loop: {summary['simulationTickCount']:,} ticks over {summary['serverUptimeSeconds']:.2f} s; {summary['effectiveSimulationTickRateHzPerMatch']:.1f} effective ticks/s per match; {summary['simulationOverruns']:,} overruns ({summary['simulationOverrunPercent']:.2f}%); average/max measured loop work, including scheduled AOI, {summary['simulationAverageTickMilliseconds']:.3f}/{summary['simulationMaximumTickMilliseconds']:.3f} ms.",
        f"- Combat/map: {shots:,} shots, {hits:,} hits ({summary['hitRatePercent']:.1f}% hit rate), {summary['damage']:,} damage, {summary['eliminations']:,} eliminations; {summary['wallCollisionBlocks']:,} wall blocks, {summary['safeZoneDamageEvents']:,} safe-zone damage events, {summary['lootPickups']:,} loot pickups.",
        f"- AOI: {summary['aoisBuilt']:,} snapshots; average {summary['averageVisibleEntitiesPerAOI']:.1f} visible entities; {summary['replicatedStateMiB']:.2f} MiB of projected entity state read.",
        f"- Generator: {summary['generatorWorkerProcesses']} child processes; {summary['generatorCpuSeconds']:.2f} CPU seconds; sum of child RSS {summary['generatorWorkerRSSMiBSum']:.1f} MiB.",
        "",
        "This is a synthetic, same-host loopback stress workload. It measures the checked-in Pearfy UDP transport, bounded realtime input queue, AOI index, and benchmark-only combat/map rules. It is not a Warzone/CS clone, internet ping result, production capacity claim, or optimized server implementation.",
        "",
    ]
    (directory / "REPORT.md").write_text("\n".join(lines))
    return summary


def create_combined_report(results_dir):
    scenarios = sorted(results_dir.glob("players-*/summary.json"), key=lambda path: int(path.parent.name.split("-")[-1]))
    summaries = [load_json(path) for path in scenarios]
    (results_dir / "summary.json").write_text(json.dumps({"focus": "fps-high-combat-map", "scenarios": summaries}, indent=2) + "\n")
    host = (results_dir / "host.txt").read_text().strip() if (results_dir / "host.txt").exists() else "host metadata unavailable"
    lines = [
        "# FPS High load report",
        "",
        "Synthetic combat-and-map workload using 120-player matches, the Pearfy high CLI profile, encrypted binary UDP, a 60 Hz fixed-step simulation, and bounded realtime AOI snapshots.",
        "",
        "| Players | Matches | Server inputs/s | Input delivery | RTT p95 (ms) | Probe coverage | Sampled CPU avg/peak | Sampled RSS peak (MiB) | Effective ticks/s/match | Overruns | Swift threads | Shots | Hits | Eliminations | AOI snapshots |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for item in summaries:
        rtt = item["rttMilliseconds"]
        lines.append(
            f"| {item['activePlayers']:,} | {item['matchCount']} | {item['inputReceiveRatePerSecond']:,.0f} | {item['senderDeliveryPercent']:.1f}% | {rtt.get('p95', 'n/a')} | {item['probeResponseCoveragePercent']:.2f}% | {item['serverCpuPercentAverage'] if item['serverCpuPercentAverage'] is not None else 'n/a'}% / {item['serverCpuPercentPeak'] if item['serverCpuPercentPeak'] is not None else 'n/a'}% | {item['serverRSSMiBPeak']:.1f} | {item['effectiveSimulationTickRateHzPerMatch']:.1f} | {item['simulationOverruns']:,} ({item['simulationOverrunPercent']:.2f}%) | {item['simulationWorkerThreadCount']} | {item['shots']:,} | {item['hits']:,} | {item['eliminations']:,} | {item['aoisBuilt']:,} |"
        )
    lines.extend([
        "",
        "## Benchmark configuration",
        "",
        "```text",
        host,
        "```",
        "",
        "The CLI high template remains unchanged. The benchmark listener temporarily raises its session admission ceiling when needed (up to 5,000) and sets a bounded listener packet-rate ceiling for this test; each scenario records both. Runs use local loopback and include load-generator CPU contention.",
        "",
        "The simulation uses task-group tasks to run one isolated match actor per 120-player match. The distinct-thread count is observed from actual tick executions; Swift concurrency schedules tasks on a shared cooperative pool, so it is not a promise of one OS thread per match. UDP ingress also follows the configured Pearfy transport event loop.",
        "",
        "Gameplay is a deterministic benchmark fixture: teams of four, movement and wall collision against a 4,096-unit map, line-of-sight hitscan, armor/health/ammo/reload, nearby loot interaction, a shrinking safe zone, and 5-cell AOI snapshots after every third tick's state update. AOI page reads happen outside the tick body. It is intended to generate measurable work, not reproduce a commercial game's rules or networking stack.",
        "",
        "Probe coverage is answered latency probes divided by probes offered; missing responses include datagrams dropped before the server callback and probes that did not return during the 1 s drain. Effective tick rate divides total match ticks by match count and server uptime, including shutdown drain. The first and last seconds include startup and drain effects; compare equivalent runs on the same host.",
        "",
        "At the upper end, the load generator and server share a 10-core Mac. The traffic source itself does not reach the configured 60 packets/player/s for all 5,000 clients, and client/server CPU competes for the same machine. Treat the high-load result as observed local saturation, not a hardware-independent Pearfy capacity number.",
        "",
    ])
    (results_dir / "FPS-HIGH-REPORT.md").write_text("\n".join(lines))


parser = argparse.ArgumentParser()
parser.add_argument("--scenario-dir", type=Path)
parser.add_argument("--results-dir", type=Path)
args = parser.parse_args()
if args.scenario_dir:
    create_case_report(args.scenario_dir)
elif args.results_dir:
    create_combined_report(args.results_dir)
else:
    parser.error("one of --scenario-dir or --results-dir is required")
