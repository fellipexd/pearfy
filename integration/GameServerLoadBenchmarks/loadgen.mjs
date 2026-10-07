import crypto from "node:crypto";
import dgram from "node:dgram";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import tls from "node:tls";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, all) => {
  if (value.startsWith("--") && all[index + 1]) pairs.push([value.slice(2), all[index + 1]]);
  return pairs;
}, []));
const config = JSON.parse(fs.readFileSync(args.config, "utf8"));
const startedCPU = process.cpuUsage();
const startedMemory = process.memoryUsage();
const rtts = [];
const handshakes = [];
const errors = [];
let sentPackets = 0;
let receivedPackets = 0;
let acceptedResponses = 0;
let rejectedResponses = 0;
let sentBytes = 0;
let receivedBytes = 0;
let lateResponses = 0;
let socketSendErrors = 0;
let websocketConnectionsRejected = 0;
let actualSendDurationMs = 0;

async function runWebSocket() {
  const tokens = config.tickets ?? [];
  const connections = [];
  const batchSize = 64;
  for (let start = 0; start < config.offeredPlayers; start += batchSize) {
    const batch = [];
    for (let index = start; index < Math.min(config.offeredPlayers, start + batchSize); index += 1) {
      const ticket = tokens[index] ?? tokens[0];
      batch.push(openWebSocket(ticket).then(connection => {
        connections.push(connection);
        handshakes.push(connection.handshakeMilliseconds);
      }).catch(error => {
        websocketConnectionsRejected += 1;
        if (errors.length < 32) errors.push(`websocket connection: ${error.message}`);
      }));
    }
    await Promise.all(batch);
  }

  const interval = 1_000 / config.rateHz;
  const durationMs = config.durationSeconds * 1_000;
  let sequence = 0;
  const measureStart = performance.now();
  let nextTick = measureStart;
  while (performance.now() - measureStart < durationMs) {
    const now = performance.now();
    if (now >= nextTick) {
      for (const connection of connections) {
        sequence += 1;
        const message = makeJSONInput(sequence, config.payloadBytes);
        connection.send(message, sequence);
        sentPackets += 1;
        sentBytes += message.length;
      }
      nextTick += interval;
    } else {
      await delay(Math.max(0, Math.min(2, nextTick - now)));
    }
  }
  actualSendDurationMs = performance.now() - measureStart;
  await delay(1_000);
  for (const connection of connections) {
    lateResponses += connection.pending.size;
    connection.close();
  }
  return {
    activePlayers: connections.length,
    acceptedConnections: connections.length,
    rejectedConnections: websocketConnectionsRejected
  };
}

function openWebSocket(ticket) {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString("base64");
    const started = performance.now();
    const socket = tls.connect({
      host: config.host,
      port: config.port,
      servername: "localhost",
      rejectUnauthorized: false,
      ALPNProtocols: ["http/1.1"]
    });
    let input = Buffer.alloc(0);
    let upgraded = false;
    let settled = false;
    const timer = setTimeout(() => fail(new Error("TLS/WebSocket handshake timeout")), 8_000);
    const fail = error => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      reject(error);
    };
    socket.once("secureConnect", () => {
      socket.write([
        "GET /gameserver HTTP/1.1",
        `Host: localhost:${config.port}`,
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Key: ${key}`,
        "Sec-WebSocket-Version: 13",
        `Authorization: Bearer ${ticket}`,
        "\r\n"
      ].join("\r\n"));
    });
    socket.on("error", error => {
      if (!upgraded) fail(error);
    });
    const handshakeReader = chunk => {
      if (upgraded) return;
      input = Buffer.concat([input, chunk]);
      const end = input.indexOf("\r\n\r\n");
      if (end < 0) return;
      const header = input.subarray(0, end).toString("utf8");
      const rest = input.subarray(end + 4);
      const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
      if (!header.startsWith("HTTP/1.1 101 ") || !header.toLowerCase().includes(`sec-websocket-accept: ${accept.toLowerCase()}`)) {
        fail(new Error("connection was refused by the WebSocket listener"));
        return;
      }
      upgraded = true;
      settled = true;
      clearTimeout(timer);
      socket.removeListener("data", handshakeReader);
      const connection = new WebSocketConnection(socket, performance.now() - started);
      if (rest.length > 0) connection.consume(rest);
      resolve(connection);
    };
    socket.on("data", handshakeReader);
  });
}

class WebSocketConnection {
  constructor(socket, handshakeMilliseconds) {
    this.socket = socket;
    this.handshakeMilliseconds = handshakeMilliseconds;
    this.pending = new Map();
    this.input = Buffer.alloc(0);
    this.closed = false;
    this.socket.on("data", bytes => this.consume(bytes));
    this.socket.on("error", () => { this.closed = true; });
    this.socket.on("close", () => { this.closed = true; });
  }

  send(message, sequence) {
    if (this.closed) return;
    this.pending.set(sequence, performance.now());
    const payload = Buffer.from(message);
    const mask = crypto.randomBytes(4);
    let header;
    if (payload.length < 126) {
      header = Buffer.from([0x81, 0x80 | payload.length]);
    } else if (payload.length <= 65_535) {
      header = Buffer.alloc(4);
      header[0] = 0x81;
      header[1] = 0xfe;
      header.writeUInt16BE(payload.length, 2);
    } else {
      throw new Error("benchmark frame too large");
    }
    const masked = Buffer.allocUnsafe(payload.length);
    for (let index = 0; index < payload.length; index += 1) masked[index] = payload[index] ^ mask[index % 4];
    this.socket.write(Buffer.concat([header, mask, masked]));
  }

  consume(bytes) {
    this.input = Buffer.concat([this.input, bytes]);
    while (this.input.length >= 2) {
      const first = this.input[0];
      const second = this.input[1];
      const opcode = first & 0x0f;
      const masked = (second & 0x80) !== 0;
      let length = second & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.input.length < 4) return;
        length = this.input.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.input.length < 10) return;
        const wideLength = this.input.readBigUInt64BE(2);
        if (wideLength > 1_048_576n) { this.close(); return; }
        length = Number(wideLength);
        offset = 10;
      }
      if (masked) offset += 4;
      if (this.input.length < offset + length) return;
      let payload = this.input.subarray(offset, offset + length);
      if (masked) {
        const keyOffset = offset - 4;
        const maskKey = this.input.subarray(keyOffset, offset);
        payload = Buffer.from(payload);
        for (let index = 0; index < payload.length; index += 1) payload[index] ^= maskKey[index % 4];
      }
      this.input = this.input.subarray(offset + length);
      if (opcode === 0x8) { this.close(); return; }
      if (opcode === 0x9) { this.sendControl(0x0a, payload); continue; }
      if (opcode !== 0x1 && opcode !== 0x2) continue;
      try {
        const acknowledgement = JSON.parse(payload.toString("utf8"));
        const sentAt = this.pending.get(acknowledgement.sequence);
        if (sentAt !== undefined) {
          this.pending.delete(acknowledgement.sequence);
          rtts.push(performance.now() - sentAt);
          receivedPackets += 1;
          receivedBytes += payload.length;
          if (acknowledgement.accepted) acceptedResponses += 1;
          else rejectedResponses += 1;
        }
      } catch {
        if (errors.length < 32) errors.push("invalid WebSocket acknowledgement");
      }
    }
  }

  sendControl(opcode, payload) {
    const mask = crypto.randomBytes(4);
    const header = Buffer.from([0x80 | opcode, 0x80 | payload.length]);
    const masked = Buffer.from(payload);
    for (let index = 0; index < masked.length; index += 1) masked[index] ^= mask[index % 4];
    this.socket.write(Buffer.concat([header, mask, masked]));
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.socket.end();
  }
}

async function runUDPSharded() {
  const shardCount = 4;
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "pearfy-udp-loadgen."));
  fs.chmodSync(temporaryDirectory, 0o700);
  const credentials = config.datagramPlayers ?? [];
  const workerPromises = [];
  let workers = [];
  try {
    for (let shardIndex = 0; shardIndex < shardCount; shardIndex += 1) {
      const shardPlayers = credentials.filter((_, index) => index % shardCount === shardIndex);
      const shardOffered = Math.max(0, Math.ceil((config.offeredPlayers - shardIndex) / shardCount));
      const shardConfig = {
        ...config,
        offeredPlayers: shardOffered,
        admittedPlayers: shardPlayers.length,
        datagramPlayers: shardPlayers
      };
      const configPath = path.join(temporaryDirectory, `worker-${shardIndex}.json`);
      const reportPath = path.join(temporaryDirectory, `worker-${shardIndex}-report.json`);
      fs.writeFileSync(configPath, JSON.stringify(shardConfig), { mode: 0o600 });
      workerPromises.push(new Promise((resolve, reject) => {
        const child = spawn(process.execPath, [
          fileURLToPath(import.meta.url),
          "--config", configPath,
          "--report", reportPath,
          "--worker", "true"
        ], { stdio: ["ignore", "pipe", "pipe"] });
        let stdout = "";
        let stderr = "";
        child.stdout.on("data", data => { stdout += data.toString(); });
        child.stderr.on("data", data => { stderr += data.toString(); });
        child.once("error", reject);
        child.once("exit", code => {
          if (code !== 0 || !fs.existsSync(reportPath)) {
            reject(new Error(`UDP load worker ${shardIndex} failed (${code}): ${stderr.slice(0, 500)}`));
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
  const sampleValues = workers.flatMap(worker => worker.rttSampleValues ?? []);
  rtts.push(...sampleValues);
  sentPackets = sum("sentMessages");
  receivedPackets = sum("receivedResponses");
  acceptedResponses = sum("acceptedResponses");
  rejectedResponses = sum("rejectedResponses");
  sentBytes = sum("requestBytes");
  receivedBytes = sum("responseBytes");
  lateResponses = sum("lateOrLostResponses");
  socketSendErrors = sum("sendErrors");
  actualSendDurationMs = Math.max(...workers.map(worker => worker.measurementDurationMilliseconds ?? 0));
  const workerCPU = workers.reduce((total, worker) => total + worker.loadGenerator.cpuUserMicroseconds + worker.loadGenerator.cpuSystemMicroseconds, 0);
  return {
    activePlayers: sum("activePlayers"),
    acceptedConnections: null,
    rejectedConnections: sum("rejectedConnections"),
    invalidDatagrams: sum("unregisteredPlayerDatagramsSent"),
    loadGenerator: {
      nodeVersion: process.version,
      workerCount: shardCount,
      cpuUserMicroseconds: workers.reduce((total, worker) => total + worker.loadGenerator.cpuUserMicroseconds, 0),
      cpuSystemMicroseconds: workers.reduce((total, worker) => total + worker.loadGenerator.cpuSystemMicroseconds, 0),
      cpuTotalMicroseconds: workerCPU,
      rssBeforeBytes: workers.reduce((total, worker) => total + worker.loadGenerator.rssBeforeBytes, 0),
      rssAfterBytes: workers.reduce((total, worker) => total + worker.loadGenerator.rssAfterBytes, 0),
      heapUsedAfterBytes: workers.reduce((total, worker) => total + worker.loadGenerator.heapUsedAfterBytes, 0),
      errors: workers.flatMap(worker => worker.loadGenerator.errors).slice(0, 32)
    }
  };
}

async function runUDP() {
  const admitted = config.datagramPlayers ?? [];
  const players = admitted.map(player => createDatagramState(player));
  const byChannelID = new Map(players.map(player => [player.channelHex, player]));
  const socket = dgram.createSocket("udp4");
  socket.on("error", error => {
    socketSendErrors += 1;
    if (errors.length < 32) errors.push(`UDP socket: ${error.message}`);
  });
  socket.on("message", (packet) => {
    receivedBytes += packet.length;
    const state = decodeServerPacket(packet, byChannelID);
    if (!state) return;
    const responseSequence = packet.readBigUInt64BE(24);
    if (state.lastServerSequence >= responseSequence) return;
    state.lastServerSequence = responseSequence;
    const payload = state.lastPlaintext;
    if (!payload || payload.length < 9) return;
    const requestSequence = payload.readBigUInt64BE(1);
    const sentAt = state.pending.get(requestSequence);
    if (sentAt !== undefined) {
      state.pending.delete(requestSequence);
      rtts.push(performance.now() - sentAt);
    }
    receivedPackets += 1;
    if (payload[0] === 1) acceptedResponses += 1;
    else rejectedResponses += 1;
  });
  await new Promise((resolve, reject) => {
    socket.once("error", reject);
    socket.bind(0, config.host, resolve);
  });

  const invalidIDs = Array.from({ length: Math.max(0, config.offeredPlayers - players.length) }, () => crypto.randomUUID());
  const invalidPackets = invalidIDs.map(id => makeUnknownPacket(id));
  const interval = 1_000 / config.rateHz;
  const durationMs = config.durationSeconds * 1_000;
  let sequence = 0n;
  let invalidCursor = 0;
  const measureStart = performance.now();
  let nextTick = measureStart;
  while (performance.now() - measureStart < durationMs) {
    const now = performance.now();
    if (now >= nextTick) {
      for (const state of players) {
        sequence += 1n;
        const payload = Buffer.alloc(config.payloadBytes);
        payload.writeBigUInt64BE(sequence, 0);
        const nextDatagramSequence = state.outboundSequence + 1n;
        const isLatencyProbe = nextDatagramSequence === 1n || nextDatagramSequence % BigInt(config.rateHz) === 1n;
        if (isLatencyProbe) payload[8] = 1;
        const packet = sealClientPacket(state, payload);
        if (isLatencyProbe) state.pending.set(sequence, performance.now());
        socket.send(packet, config.port, config.host);
        sentPackets += 1;
        sentBytes += packet.length;
      }
      if (invalidCursor === 0) {
        for (const packet of invalidPackets) {
          socket.send(packet, config.port, config.host);
          sentPackets += 1;
          sentBytes += packet.length;
          invalidCursor += 1;
        }
      }
      nextTick += interval;
    } else {
      await delay(Math.max(0, Math.min(1, nextTick - now)));
    }
  }
  actualSendDurationMs = performance.now() - measureStart;
  await delay(1_000);
  lateResponses = players.reduce((sum, player) => sum + player.pending.size, 0);
  socket.close();
  return { activePlayers: players.length, acceptedConnections: null, rejectedConnections: invalidIDs.length, invalidDatagrams: invalidCursor, rttSampleValues: rtts.slice() };
}

function createDatagramState(player) {
  const channelID = uuidBytes(player.channelID);
  const secret = Buffer.from(player.secret, "base64");
  const clientToServerKey = Buffer.from(crypto.hkdfSync("sha256", secret, channelID, Buffer.from("pearfy-gameserver-udp-v1/client-to-server"), 32));
  const serverToClientKey = Buffer.from(crypto.hkdfSync("sha256", secret, channelID, Buffer.from("pearfy-gameserver-udp-v1/server-to-client"), 32));
  return {
    playerID: player.playerID,
    channelID,
    channelHex: channelID.toString("hex"),
    clientToServerKey,
    serverToClientKey,
    outboundSequence: 0n,
    lastServerSequence: 0n,
    pending: new Map(),
    lastPlaintext: null
  };
}

function sealClientPacket(state, plaintext) {
  state.outboundSequence += 1n;
  const header = makeHeader(state.channelID, 0, state.outboundSequence);
  const nonce = makeNonce(state.outboundSequence);
  const cipher = crypto.createCipheriv("chacha20-poly1305", state.clientToServerKey, nonce, { authTagLength: 16 });
  cipher.setAAD(header, { plaintextLength: plaintext.length });
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([header, ciphertext, cipher.getAuthTag()]);
}

function decodeServerPacket(packet, byChannelID) {
  if (packet.length < 48 || packet.toString("ascii", 0, 4) !== "PFSU" || packet[4] !== 1 || packet[5] !== 1) return null;
  const state = byChannelID.get(packet.subarray(8, 24).toString("hex"));
  if (!state) return null;
  const header = packet.subarray(0, 32);
  const ciphertext = packet.subarray(32, packet.length - 16);
  const tag = packet.subarray(packet.length - 16);
  const sequence = packet.readBigUInt64BE(24);
  const decipher = crypto.createDecipheriv("chacha20-poly1305", state.serverToClientKey, makeNonce(sequence), { authTagLength: 16 });
  decipher.setAAD(header, { plaintextLength: ciphertext.length });
  decipher.setAuthTag(tag);
  try {
    state.lastPlaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    return state;
  } catch {
    if (errors.length < 32) errors.push("UDP response authentication failed");
    return null;
  }
}

function makeUnknownPacket(uuid) {
  const channelID = uuidBytes(uuid);
  const header = makeHeader(channelID, 0, 1n);
  return Buffer.concat([header, Buffer.alloc(16)]);
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

function makeNonce(sequence) {
  const nonce = Buffer.alloc(12);
  nonce.writeBigUInt64BE(sequence, 4);
  return nonce;
}

function uuidBytes(value) {
  return Buffer.from(value.replaceAll("-", ""), "hex");
}

function makeJSONInput(sequence, requestedBytes) {
  const base = JSON.stringify({ sequence, padding: "" });
  const padding = "x".repeat(Math.max(0, requestedBytes - Buffer.byteLength(base)));
  return JSON.stringify({ sequence, padding });
}

function summarize(values) {
  if (values.length === 0) return { samples: 0, min: null, average: null, p50: null, p90: null, p95: null, p99: null, max: null };
  const sorted = [...values].sort((left, right) => left - right);
  const percentile = rank => round(sorted[Math.max(0, Math.ceil(rank * sorted.length) - 1)]);
  return {
    samples: values.length,
    min: round(sorted[0]),
    average: round(values.reduce((sum, value) => sum + value, 0) / values.length),
    p50: percentile(0.50),
    p90: percentile(0.90),
    p95: percentile(0.95),
    p99: percentile(0.99),
    max: round(sorted.at(-1))
  };
}

function round(value) { return Math.round(value * 1000) / 1000; }
function delay(milliseconds) { return new Promise(resolve => setTimeout(resolve, milliseconds)); }

const isWorker = args.worker === "true";
const client = config.transport === "websocket"
  ? await runWebSocket()
  : (isWorker ? await runUDP() : await runUDPSharded());
const endedCPU = process.cpuUsage(startedCPU);
const endedMemory = process.memoryUsage();
const report = {
  scenario: config.name,
  mode: config.mode,
  transport: config.transport,
  offeredPlayers: config.offeredPlayers,
  templateAdmissionLimit: config.admittedPlayers,
  configuredRejections: Math.max(0, config.offeredPlayers - config.admittedPlayers),
  activePlayers: client.activePlayers ?? config.admittedPlayers,
  acceptedConnections: client.acceptedConnections ?? null,
  rejectedConnections: client.rejectedConnections ?? websocketConnectionsRejected,
  connectionAcceptanceRate: client.acceptedConnections == null
    ? null
    : round(client.acceptedConnections / config.offeredPlayers),
  offeredRateHzPerPlayer: config.rateHz,
  payloadBytes: config.payloadBytes,
  measurementDurationMilliseconds: round(actualSendDurationMs),
  sentMessages: sentPackets,
  receivedResponses: receivedPackets,
  acceptedResponses,
  rejectedResponses,
  sendErrors: socketSendErrors,
  unregisteredPlayerDatagramsSent: client.invalidDatagrams ?? 0,
  lateOrLostResponses: lateResponses,
  responseRatePerSecond: actualSendDurationMs > 0 ? round(receivedPackets * 1_000 / actualSendDurationMs) : 0,
  requestRatePerSecond: actualSendDurationMs > 0 ? round(sentPackets * 1_000 / actualSendDurationMs) : 0,
  requestBytes: sentBytes,
  responseBytes: receivedBytes,
  rttMilliseconds: summarize(rtts),
  rttSampleValues: rtts,
  connectionHandshakeMilliseconds: summarize(handshakes),
  loadGenerator: client.loadGenerator ?? {
    nodeVersion: process.version,
    cpuUserMicroseconds: endedCPU.user,
    cpuSystemMicroseconds: endedCPU.system,
    rssBeforeBytes: startedMemory.rss,
    rssAfterBytes: endedMemory.rss,
    heapUsedAfterBytes: endedMemory.heapUsed,
    errors: errors.slice(0, 32)
  }
};
if (!isWorker && args.report.endsWith("client-result.json")) {
  fs.writeFileSync(args.report.replace(/client-result\.json$/, "rtt-samples.csv"), `rtt_ms\n${rtts.map(value => round(value)).join("\n")}\n`, { mode: 0o600 });
}
if (isWorker) {
  fs.writeFileSync(args.report, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
} else {
  const { rttSampleValues, ...publicReport } = report;
  fs.writeFileSync(args.report, `${JSON.stringify(publicReport, null, 2)}\n`, { mode: 0o600 });
}
process.stdout.write(`${JSON.stringify({ scenario: config.name, offeredPlayers: config.offeredPlayers, activePlayers: report.activePlayers, sentMessages: sentPackets, receivedResponses: receivedPackets, rttSamples: rtts.length, requestRatePerSecond: report.requestRatePerSecond })}\n`);
