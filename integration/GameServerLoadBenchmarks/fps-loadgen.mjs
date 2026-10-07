import crypto from "node:crypto";
import dgram from "node:dgram";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, all) => {
  if (value.startsWith("--") && all[index + 1]) pairs.push([value.slice(2), all[index + 1]]);
  return pairs;
}, []));
const config = JSON.parse(fs.readFileSync(args.config, "utf8"));

function delay(milliseconds) { return new Promise(resolve => setTimeout(resolve, milliseconds)); }
function uuidBytes(value) { return Buffer.from(value.replaceAll("-", ""), "hex"); }
function makeNonce(sequence) {
  const nonce = Buffer.alloc(12);
  nonce.writeBigUInt64BE(sequence, 4);
  return nonce;
}
function makeHeader(channelID, direction, sequence) {
  const header = Buffer.alloc(32);
  header.write("PFSU", 0, "ascii");
  header[4] = 1;
  header[5] = direction;
  channelID.copy(header, 8);
  header.writeBigUInt64BE(sequence, 24);
  return header;
}

function makeState(player) {
  const channelID = uuidBytes(player.channelID);
  const secret = Buffer.from(player.secret, "base64");
  return {
    player,
    channelID,
    channelHex: channelID.toString("hex"),
    clientToServerKey: Buffer.from(crypto.hkdfSync("sha256", secret, channelID, Buffer.from("pearfy-gameserver-udp-v1/client-to-server"), 32)),
    serverToClientKey: Buffer.from(crypto.hkdfSync("sha256", secret, channelID, Buffer.from("pearfy-gameserver-udp-v1/server-to-client"), 32)),
    outboundSequence: 0n,
    lastServerSequence: 0n,
    pending: new Map()
  };
}

function makeGameplayInput(sequence, player) {
  const payload = Buffer.alloc(config.payloadBytes);
  payload.writeBigUInt64BE(sequence, 0);
  const slot = player.playerSlot;
  const matchSize = config.matchPlayerCounts[player.matchIndex];
  const movementPhase = Number(sequence % 240n);
  const moveX = movementPhase < 60 ? 1 : movementPhase < 120 ? 0 : movementPhase < 180 ? -1 : 0;
  const moveY = movementPhase < 60 ? 0 : movementPhase < 120 ? 1 : movementPhase < 180 ? 0 : -1;
  const target = (slot + 4 + (slot % 3)) % matchSize;
  let flags = 0;
  if (sequence % 8n === 0n) flags |= 0x01; // Fire on a 7.5 Hz cadence.
  if (sequence % 240n === 1n) flags |= 0x02; // Search the spawn cache once per four-second movement cycle.
  payload[9] = flags;
  payload.writeInt8(moveX, 10);
  payload.writeInt8(moveY, 11);
  payload.writeUInt16LE((slot * 13 + Number(sequence % 97n)) % 160, 12);
  payload.writeUInt16LE(target, 14);
  payload[16] = slot % 3; // weapon archetype placeholder for the benchmark ruleset.
  payload.writeUInt32LE(player.matchIndex, 17);
  payload.writeUInt32LE(slot, 21);
  payload.writeBigUInt64LE(sequence, 25);
  return payload;
}

function seal(state, payload) {
  state.outboundSequence += 1n;
  const header = makeHeader(state.channelID, 0, state.outboundSequence);
  const cipher = crypto.createCipheriv("chacha20-poly1305", state.clientToServerKey, makeNonce(state.outboundSequence), { authTagLength: 16 });
  cipher.setAAD(header, { plaintextLength: payload.length });
  return Buffer.concat([header, cipher.update(payload), cipher.final(), cipher.getAuthTag()]);
}

function openReply(packet, byChannel) {
  if (packet.length < 57 || packet.toString("ascii", 0, 4) !== "PFSU" || packet[4] !== 1 || packet[5] !== 1) return null;
  const state = byChannel.get(packet.subarray(8, 24).toString("hex"));
  if (!state) return null;
  const serverSequence = packet.readBigUInt64BE(24);
  if (serverSequence <= state.lastServerSequence) return null;
  const header = packet.subarray(0, 32);
  const ciphertext = packet.subarray(32, packet.length - 16);
  const decipher = crypto.createDecipheriv("chacha20-poly1305", state.serverToClientKey, makeNonce(serverSequence), { authTagLength: 16 });
  decipher.setAAD(header, { plaintextLength: ciphertext.length });
  decipher.setAuthTag(packet.subarray(packet.length - 16));
  try {
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    state.lastServerSequence = serverSequence;
    return { state, plaintext };
  } catch {
    return null;
  }
}

async function runWorker() {
  const players = config.players.map(makeState);
  const byChannel = new Map(players.map(player => [player.channelHex, player]));
  const socket = dgram.createSocket("udp4");
  const rtts = [];
  const errors = [];
  let receivedResponses = 0;
  let acceptedResponses = 0;
  let rejectedResponses = 0;
  let responseBytes = 0;
  let requestBytes = 0;
  let sentMessages = 0;
  let probeMessagesSent = 0;
  let sendErrors = 0;
  let lateOrLostResponses = 0;
  let measurementDurationMilliseconds = 0;
  const startedCPU = process.cpuUsage();
  const startedMemory = process.memoryUsage();
  socket.on("error", error => {
    sendErrors += 1;
    if (errors.length < 16) errors.push(error.message);
  });
  socket.on("message", packet => {
    responseBytes += packet.length;
    const opened = openReply(packet, byChannel);
    if (!opened || opened.plaintext.length < 9) return;
    const { state, plaintext } = opened;
    const sequence = plaintext.readBigUInt64BE(1);
    const sentAt = state.pending.get(sequence);
    if (sentAt !== undefined) {
      state.pending.delete(sequence);
      rtts.push(performance.now() - sentAt);
    }
    receivedResponses += 1;
    if (plaintext[0] === 1) acceptedResponses += 1;
    else rejectedResponses += 1;
  });
  await new Promise((resolve, reject) => {
    socket.once("error", reject);
  socket.bind(0, process.env.FPS_CLIENT_BIND_HOST ?? "0.0.0.0", resolve);
  });

  const interval = 1_000 / config.rateHz;
  const durationSeconds = Number(process.env.FPS_DURATION_SECONDS ?? config.durationSeconds);
  const durationMs = durationSeconds * 1_000;
  const inputSequences = players.map(() => 0n);
  const measureStart = performance.now();
  let nextTick = measureStart;
  while (performance.now() - measureStart < durationMs) {
    const now = performance.now();
    if (now >= nextTick) {
      for (let playerIndex = 0; playerIndex < players.length; playerIndex += 1) {
        const state = players[playerIndex];
        inputSequences[playerIndex] += 1n;
        const packetSequence = state.outboundSequence + 1n;
        const isProbe = packetSequence === 1n || packetSequence % BigInt(config.rateHz) === 1n;
        const payload = makeGameplayInput(inputSequences[playerIndex], state.player);
        payload[8] = isProbe ? 1 : 0;
        const packet = seal(state, payload);
        if (isProbe) {
          state.pending.set(inputSequences[playerIndex], performance.now());
          probeMessagesSent += 1;
        }
        socket.send(packet, config.port, config.host);
        sentMessages += 1;
        requestBytes += packet.length;
      }
      nextTick += interval;
    } else {
      await delay(Math.max(0, Math.min(1, nextTick - now)));
    }
  }
  measurementDurationMilliseconds = performance.now() - measureStart;
  await delay(1_000);
  lateOrLostResponses = players.reduce((total, player) => total + player.pending.size, 0);
  socket.close();
  const elapsedCPU = process.cpuUsage(startedCPU);
  const endedMemory = process.memoryUsage();
  return {
    scenario: config.scenario,
    offeredPlayers: config.offeredPlayers,
    activePlayers: players.length,
    matchCount: config.matchCount,
    sentMessages,
    probeMessagesSent,
    receivedResponses,
    acceptedResponses,
    rejectedResponses,
    requestBytes,
    responseBytes,
    sendErrors,
    lateOrLostResponses,
    measurementDurationMilliseconds,
    rttValues: rtts,
    loadGenerator: {
      nodeVersion: process.version,
      workerCount: 1,
      cpuUserMicroseconds: elapsedCPU.user,
      cpuSystemMicroseconds: elapsedCPU.system,
      rssBeforeBytes: startedMemory.rss,
      rssAfterBytes: endedMemory.rss,
      errors
    }
  };
}

async function runSharded() {
  const shardCount = Math.max(1, Math.min(Number(process.env.FPS_GENERATOR_WORKERS ?? config.generatorWorkers ?? 8), config.players.length));
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "pearfy-fps-loadgen."));
  fs.chmodSync(temporaryDirectory, 0o700);
  const workerPromises = [];
  let workers = [];
  try {
    for (let shardIndex = 0; shardIndex < shardCount; shardIndex += 1) {
      const players = config.players.filter((_, index) => index % shardCount === shardIndex);
      const workerConfig = { ...config, players };
      const configPath = path.join(temporaryDirectory, `worker-${shardIndex}.json`);
      const reportPath = path.join(temporaryDirectory, `worker-${shardIndex}-report.json`);
      fs.writeFileSync(configPath, JSON.stringify(workerConfig), { mode: 0o600 });
      workerPromises.push(new Promise((resolve, reject) => {
        const child = spawn(process.execPath, [fileURLToPath(import.meta.url), "--config", configPath, "--report", reportPath, "--worker", "true"], {
          stdio: ["ignore", "ignore", "pipe"]
        });
        let stderr = "";
        child.stderr.on("data", data => { stderr += data.toString(); });
        child.once("error", reject);
        child.once("exit", code => {
          if (code !== 0 || !fs.existsSync(reportPath)) {
            reject(new Error(`FPS UDP load worker ${shardIndex} failed (${code}): ${stderr.slice(0, 500)}`));
            return;
          }
          resolve(JSON.parse(fs.readFileSync(reportPath, "utf8")));
        });
      }));
    }
    workers = await Promise.all(workerPromises);
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
  const sum = key => workers.reduce((total, worker) => total + (worker[key] ?? 0), 0);
  const sumGenerator = key => workers.reduce((total, worker) => total + (worker.loadGenerator[key] ?? 0), 0);
  const rttValues = workers.flatMap(worker => worker.rttValues ?? []);
  const maxDuration = Math.max(...workers.map(worker => worker.measurementDurationMilliseconds ?? 0));
  return {
    scenario: config.scenario,
    mode: config.mode,
    transport: "authenticated-encrypted-udp-binary",
    offeredPlayers: config.offeredPlayers,
    activePlayers: sum("activePlayers"),
    matchSize: config.matchSize,
    matchCount: config.matchCount,
    matchPlayerCounts: config.matchPlayerCounts,
    offeredRateHzPerPlayer: config.rateHz,
    payloadBytes: config.payloadBytes,
    measurementDurationMilliseconds: maxDuration,
    sentMessages: sum("sentMessages"),
    probeMessagesSent: sum("probeMessagesSent"),
    receivedResponses: sum("receivedResponses"),
    acceptedResponses: sum("acceptedResponses"),
    rejectedResponses: sum("rejectedResponses"),
    requestBytes: sum("requestBytes"),
    responseBytes: sum("responseBytes"),
    sendErrors: sum("sendErrors"),
    lateOrLostResponses: sum("lateOrLostResponses"),
    rttValues,
    loadGenerator: {
      nodeVersion: process.version,
      workerCount: shardCount,
      cpuUserMicroseconds: sumGenerator("cpuUserMicroseconds"),
      cpuSystemMicroseconds: sumGenerator("cpuSystemMicroseconds"),
      rssBeforeBytes: sumGenerator("rssBeforeBytes"),
      rssAfterBytes: sumGenerator("rssAfterBytes"),
      errors: workers.flatMap(worker => worker.loadGenerator.errors).slice(0, 32)
    }
  };
}

function round(value) { return Math.round(value * 1_000) / 1_000; }
function summarize(values) {
  if (values.length === 0) return { samples: 0, average: null, p50: null, p95: null, p99: null, max: null };
  const sorted = [...values].sort((a, b) => a - b);
  const percentile = rank => round(sorted[Math.max(0, Math.ceil(rank * sorted.length) - 1)]);
  return {
    samples: values.length,
    average: round(values.reduce((total, value) => total + value, 0) / values.length),
    p50: percentile(0.5),
    p95: percentile(0.95),
    p99: percentile(0.99),
    max: round(sorted.at(-1))
  };
}

const workerMode = args.worker === "true";
const startedCPU = process.cpuUsage();
const result = workerMode ? await runWorker() : await runSharded();
if (workerMode) {
  const cpu = process.cpuUsage(startedCPU);
  const memory = process.memoryUsage();
  result.loadGenerator.cpuUserMicroseconds = cpu.user;
  result.loadGenerator.cpuSystemMicroseconds = cpu.system;
  result.loadGenerator.rssAfterBytes = memory.rss;
  fs.writeFileSync(args.report, `${JSON.stringify(result, null, 2)}\n`, { mode: 0o600 });
} else {
  const report = {
    ...result,
    requestRatePerSecond: round(result.sentMessages * 1_000 / result.measurementDurationMilliseconds),
    responseRatePerSecond: round(result.receivedResponses * 1_000 / result.measurementDurationMilliseconds),
    rttMilliseconds: summarize(result.rttValues),
    loadGenerator: {
      ...result.loadGenerator,
      cpuTotalMicroseconds: result.loadGenerator.cpuUserMicroseconds + result.loadGenerator.cpuSystemMicroseconds
    }
  };
  const csv = `rtt_ms\n${result.rttValues.map(round).join("\n")}\n`;
  fs.writeFileSync(args.report.replace(/client-result\.json$/, "rtt-samples.csv"), csv, { mode: 0o600 });
  const { rttValues, ...publicReport } = report;
  fs.writeFileSync(args.report, `${JSON.stringify(publicReport, null, 2)}\n`, { mode: 0o600 });
  process.stdout.write(`${JSON.stringify({ players: report.activePlayers, matches: report.matchCount, sent: report.sentMessages, serverResponses: report.receivedResponses, rttSamples: report.rttMilliseconds.samples, sendsPerSecond: report.requestRatePerSecond })}\n`);
}
