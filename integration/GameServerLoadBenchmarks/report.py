#!/usr/bin/env python3
import argparse
import csv
import json
import statistics
from pathlib import Path


def read_json(path):
    return json.loads(path.read_text()) if path.exists() else {}


def resource_summary(path):
    if not path.exists():
        return {"samples": 0, "cpu_avg": None, "cpu_max": None, "rss_avg_kib": None, "rss_max_kib": None}
    with path.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    cpus = [float(row["cpu_percent"]) for row in rows if row.get("cpu_percent")]
    rss = [int(row["rss_kib"]) for row in rows if row.get("rss_kib")]
    return {
        "samples": len(rows),
        "cpu_avg": round(statistics.mean(cpus), 2) if cpus else None,
        "cpu_max": round(max(cpus), 2) if cpus else None,
        "rss_avg_kib": round(statistics.mean(rss)) if rss else None,
        "rss_max_kib": max(rss) if rss else None,
    }


def report_scenario(directory):
    client = read_json(directory / "client-result.json")
    server = read_json(directory / "server-stats.json")
    profile = read_json(directory / "template.json")
    resources = resource_summary(directory / "resource-samples.csv")
    duration_seconds = client.get("measurementDurationMilliseconds", 0) / 1_000
    expected_admitted_inputs = client.get("activePlayers", 0) * client.get("offeredRateHzPerPlayer", 0) * duration_seconds
    server_ingress_rate = server.get("messagesReceived", 0) / duration_seconds if duration_seconds else 0
    server_input_delivery = server.get("messagesReceived", 0) / expected_admitted_inputs if expected_admitted_inputs else 0
    expected_probes = client.get("receivedResponses", 0) + client.get("lateOrLostResponses", 0)
    probe_loss_rate = client.get("lateOrLostResponses", 0) / expected_probes if expected_probes else 0
    average_request_bytes = client.get("requestBytes", 0) / client.get("sentMessages", 1) if client.get("sentMessages", 0) else 0
    merged = {
        "scenario": directory.name,
        "client": client,
        "server": server,
        "profile": profile,
        "resources": resources,
        "measured": {
            "durationSeconds": round(duration_seconds, 3),
            "expectedAdmittedInputs": round(expected_admitted_inputs),
            "serverIngressInputsPerSecond": round(server_ingress_rate, 2),
            "serverInputDeliveryRate": round(server_input_delivery, 4),
            "probeLossRate": round(probe_loss_rate, 4),
            "averageClientRequestBytes": round(average_request_bytes, 2),
        },
    }
    (directory / "report.json").write_text(json.dumps(merged, indent=2) + "\n")

    rtt = client.get("rttMilliseconds", {})
    setup_ms = server.get("setupMilliseconds")
    uptime_ms = server.get("uptimeMilliseconds")
    generator = client.get("loadGenerator", {})
    generator_cpu_ms = round((generator.get("cpuUserMicroseconds", 0) + generator.get("cpuSystemMicroseconds", 0)) / 1_000, 1)
    generator_rss_mib = round((generator.get("rssAfterBytes", 0)) / (1024 * 1024), 1)
    lines = [
        f"# {directory.name}",
        "",
        f"- Configuração CLI: `{client.get('mode', 'unknown')}` / `{client.get('transport', 'unknown')}`.",
        f"- Jogadores ofertados: {client.get('offeredPlayers', 0)}; sessões liberadas pelo template: {client.get('templateAdmissionLimit', 0)}; rejeitadas por limite: {client.get('configuredRejections', 0)}.",
        f"- Sessões ativas no teste: {client.get('activePlayers', 0)}.",
        f"- Janela de carga medida: {duration_seconds:.2f} s.",
        f"- RTT de eco/probe: amostras {rtt.get('samples', 0)}, média {rtt.get('average')} ms, p50 {rtt.get('p50')} ms, p95 {rtt.get('p95')} ms, p99 {rtt.get('p99')} ms, máximo {rtt.get('max')} ms.",
        f"- Taxa observada: {client.get('requestRatePerSecond', 0)} mensagens/s ofertadas; {client.get('responseRatePerSecond', 0)} respostas/s recebidas.",
        f"- Ingresso processado pelo servidor: {server.get('messagesReceived', 0)} inputs ({server_ingress_rate:.2f}/s), {server_input_delivery * 100:.1f}% do volume esperado dos jogadores admitidos; aceitos pela fila {server.get('acceptedInputs', 0)}, rejeitados {server.get('rejectedInputs', 0)}.",
        f"- Perda de respostas de RTT: {client.get('lateOrLostResponses', 0)} de {expected_probes} probes ({probe_loss_rate * 100:.1f}%); média {average_request_bytes:.1f} bytes por envio contabilizados pelo gerador. WSS conta o payload JSON; UDP inclui o datagrama Pearfy criptografado. TCP/IP e TLS não são contabilizados.",
        f"- Mensagens: enviadas {client.get('sentMessages', 0)}, respostas {client.get('receivedResponses', 0)}, erros de envio {client.get('sendErrors', 0)}, sem resposta até o fim {client.get('lateOrLostResponses', 0)}.",
        f"- CPU do processo servidor: média {resources['cpu_avg']}%, pico {resources['cpu_max']}%; RSS médio {resources['rss_avg_kib']} KiB, pico {resources['rss_max_kib']} KiB.",
        f"- Gerador de carga: CPU acumulada {generator_cpu_ms} ms; RSS somado após a medição {generator_rss_mib} MiB em {generator.get('workerCount', 1)} processo(s).",
        f"- Inicialização até listener pronto: {setup_ms} ms; janela do processo servidor: {uptime_ms} ms.",
        f"- Simulação: ticks {server.get('driver', {}).get('completedTicks', 0)}, overruns {server.get('driver', {}).get('overrunCount', 0)}, inputs processados {server.get('simulation', {}).get('acceptedInputCount', 0)}, recusas de fila {server.get('simulation', {}).get('capacityRejectionCount', 0)}.",
        "",
        "Os valores são de loopback no mesmo Mac para um serviço sintético de transporte + fila de input. Eles não representam ping de internet nem simulação de gameplay de um gênero completo.",
    ]
    (directory / "REPORT.md").write_text("\n".join(lines) + "\n")
    return merged


def report_run(directory):
    host = (directory / "host.txt").read_text().strip().splitlines() if (directory / "host.txt").exists() else []
    scenarios = []
    for item in sorted(directory.iterdir()):
        if item.is_dir() and (item / "client-result.json").exists():
            scenarios.append(report_scenario(item))
    overload_note = (
        "The offered populations exceed at least one CLI preset admission limit. Rejections are part of the stress result; preset limits were not changed."
        if any(item["client"].get("configuredRejections", 0) > 0 for item in scenarios)
        else "This wiring smoke run stays below each CLI preset admission limit; it is not the requested capacity run."
    )
    lines = [
        "# Pearfy GameServer load test report",
        "",
        "## Host and measurement setup",
        "",
        *[f"- `{line}`" for line in host],
        "- WSS uses a temporary self-signed localhost certificate; UDP uses the Pearfy authenticated encrypted datagram codec with ephemeral per-session keys.",
        "- High-mode UDP is enabled only inside this benchmark process. The emitted high CLI template remains `udpEnabled: false`.",
        "- These runs measure a synthetic transport echo and bounded realtime input queue; they do not simulate point-and-click rules, FPS combat, MMO world persistence, AOI replication, or a frontend.",
        f"- {overload_note}",
        "",
        "## Results",
        "",
        "| Scenario | Mode / transport | Offered | Active | RTT p50 / p95 / p99 (ms) | Client sends/s | Server inputs/s | RTT replies/s | Server CPU avg / peak | Server RSS peak MiB | Tick overruns |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for item in scenarios:
        client = item["client"]
        server = item["server"]
        rtt = client.get("rttMilliseconds", {})
        resources = item["resources"]
        measured = item["measured"]
        rtt_text = f"{rtt.get('p50')} / {rtt.get('p95')} / {rtt.get('p99')}" if rtt.get("samples") else "n/a"
        lines.append(
            f"| {client.get('scenario')} | {client.get('mode')} / {client.get('transport')} | {client.get('offeredPlayers')} | {client.get('activePlayers')} | {rtt_text} | {client.get('requestRatePerSecond')} | {measured.get('serverIngressInputsPerSecond')} ({measured.get('serverInputDeliveryRate', 0) * 100:.1f}%) | {client.get('responseRatePerSecond')} | {resources.get('cpu_avg')}% / {resources.get('cpu_max')}% | {round((resources.get('rss_max_kib') or 0) / 1024, 1)} | {server.get('driver', {}).get('overrunCount', 0)} |"
        )
    lines.extend([
        "",
        "## Per-scenario artifacts",
        "",
        "Each scenario folder contains its generated CLI template, `client-result.json`, `rtt-samples.csv`, `server-stats.json`, `resource-samples.csv`, server/client logs, `report.json`, and a short `REPORT.md`.",
        "",
        "Interpret RTT as local request/response time from this load generator, not ICMP or public-network ping. UDP workloads echo only one latency probe per admitted simulated player per second. `Server inputs/s` comes from authenticated inputs processed by the transport callback; the percentage is relative to the admitted players' configured rate. The server and generator share one Mac, so client CPU and loopback scheduling affect results. The per-scenario byte count is WSS JSON payload bytes or encrypted UDP datagram bytes; neither includes TCP/IP, and WSS also excludes TLS overhead.",
    ])
    (directory / "LOAD-REPORT.md").write_text("\n".join(lines) + "\n")
    (directory / "summary.json").write_text(json.dumps({"host": host, "scenarios": scenarios}, indent=2) + "\n")


parser = argparse.ArgumentParser()
parser.add_argument("--scenario-dir", type=Path)
parser.add_argument("--results-dir", type=Path)
options = parser.parse_args()
if options.scenario_dir:
    report_scenario(options.scenario_dir)
if options.results_dir:
    report_run(options.results_dir)
