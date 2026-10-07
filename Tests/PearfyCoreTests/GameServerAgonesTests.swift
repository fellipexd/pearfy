import Foundation
import PearfyCloud
import PearfyGameServerAgones
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import Testing

@Test func agonesConfigurationUsesDynamicPortAndRejectsRemoteSDKHosts() throws {
    let configuration = try AgonesSDKConfiguration.fromEnvironment(["AGONES_SDK_HTTP_PORT": "19358"])
    #expect(configuration.port == 19_358)
    #expect(throws: AgonesSDKError.invalidConfiguration) {
        try AgonesSDKConfiguration.fromEnvironment(["AGONES_SDK_HTTP_PORT": "http://example.test"])
    }
    #expect(throws: AgonesSDKError.invalidConfiguration) {
        try AgonesSDKConfiguration(host: "127.attacker.test", port: 9358)
    }
    #expect(throws: AgonesSDKError.invalidConfiguration) {
        try AgonesSDKConfiguration(host: "10.0.0.7", port: 9358)
    }
}

@Test func agonesLifecycleHeartbeatsReadyAllocationSnapshotAndShutdown() async throws {
    let transport = AgonesStubTransport()
    let lifecycle = AgonesSDKLifecycle(
        configuration: try AgonesSDKConfiguration(port: 9358, healthIntervalSeconds: 300),
        transport: transport
    )
    try await lifecycle.start()
    #expect(await lifecycle.state == .starting)
    try await lifecycle.ready()
    #expect(await lifecycle.state == .ready)
    let server = try await lifecycle.gameServer()
    #expect(server.status.state == "Ready")
    #expect(server.status.address == "127.0.0.1")
    #expect(server.status.ports?.first?.port == 7777)
    try await lifecycle.allocate()
    #expect(await lifecycle.state == .allocated)
    try await lifecycle.shutdown()
    #expect(await lifecycle.state == .shutdown)
    try await lifecycle.shutdown()
    let requests = await transport.requests
    #expect(requests.map(\.path) == ["/health", "/ready", "/gameserver", "/allocate", "/shutdown"])
    #expect(requests.map(\.method) == ["POST", "POST", "GET", "POST", "POST"])
}

@Test func agonesLifecycleRejectsTransitionsThatWouldLieAboutReadiness() async throws {
    let lifecycle = AgonesSDKLifecycle(
        configuration: try AgonesSDKConfiguration(port: 9358),
        transport: AgonesStubTransport()
    )
    do {
        try await lifecycle.ready()
        Issue.record("ready must only be announced after the lifecycle starts")
    } catch {
        #expect(error as? AgonesSDKError == .invalidLifecycleTransition)
    }
    do {
        try await lifecycle.allocate()
        Issue.record("allocation must not precede readiness")
    } catch {
        #expect(error as? AgonesSDKError == .invalidLifecycleTransition)
    }
}

private actor AgonesStubTransport: CloudHTTPTransport {
    struct Request: Sendable, Equatable { let method: String; let path: String }
    private(set) var requests: [Request] = []

    func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
        requests.append(Request(method: request.httpMethod ?? "GET", path: request.url?.path ?? ""))
        let body: Data
        if request.url?.path == "/gameserver" {
            body = Data(#"{"object_meta":{"name":"local","namespace":"default"},"status":{"state":"Ready","address":"127.0.0.1","ports":[{"name":"default","port":7777}]}}"#.utf8)
        } else {
            body = Data()
        }
        return CloudHTTPResponse(statusCode: 200, body: body)
    }
}

@available(macOS 15, iOS 18, *)
@Test func agonesAllocatorUsesMutualTLSBoundsAndSingleAttemptAllocation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pearfy-agones-allocator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let serverCertificate = directory.appendingPathComponent("server.crt")
    let serverKey = directory.appendingPathComponent("server.key")
    let clientCertificate = directory.appendingPathComponent("client.crt")
    let clientKey = directory.appendingPathComponent("client.key")
    let authorityCertificate = directory.appendingPathComponent("ca.crt")
    let authorityKey = directory.appendingPathComponent("ca.key")
    try makeCertificateAuthority(certificate: authorityCertificate, key: authorityKey)
    try makeIssuedCertificate(certificate: serverCertificate, key: serverKey, commonName: "localhost", authorityCertificate: authorityCertificate, authorityKey: authorityKey, san: "DNS:localhost", usage: "serverAuth", directory: directory)
    try makeIssuedCertificate(certificate: clientCertificate, key: clientKey, commonName: "allocator-client", authorityCertificate: authorityCertificate, authorityKey: authorityKey, san: "DNS:allocator-client", usage: "clientAuth", directory: directory)

    let requestLog = AgonesAllocationRequestLog()
    let serverTransport = HTTP2ServerTransport.Posix(
        address: .ipv4(host: "127.0.0.1", port: 0),
        transportSecurity: .mTLS(
            certificateChain: [.file(path: serverCertificate.path, format: .pem)],
            privateKey: .file(path: serverKey.path, format: .pem)
        ) {
            $0.clientCertificateVerification = .noHostnameVerification
            $0.trustRoots = .certificates([.file(path: authorityCertificate.path, format: .pem)])
            $0.requireALPN = true
        }
    )
    let server = GRPCServer(transport: serverTransport, services: [StubAgonesAllocatorService(requestLog: requestLog)])
    let serverTask = Task { try await server.serve() }
    defer {
        server.beginGracefulShutdown()
        Task { try? await serverTask.value }
    }
    let endpoint = try await serverTransport.listeningAddress
    let port = try #require(endpoint.description.split(separator: ":").last.flatMap { Int($0) })

    let configuration = try AgonesAllocatorConfiguration(
        host: "127.0.0.1", port: port, namespace: "game-prod", serverName: "localhost",
        clientCertificatePath: clientCertificate.path,
        clientPrivateKeyPath: clientKey.path,
        serverCAPath: authorityCertificate.path,
        timeoutSeconds: 2
    )
    let client = AgonesAllocatorClient(configuration: configuration)
    let allocationRequest = try AgonesAllocationRequest(
        matchLabels: ["agones.dev/fleet": "match-prod"],
        metadataLabels: ["match": "match-123"],
        metadataAnnotations: ["region": "sa-east-1"],
        scheduling: .distributed
    )
    let allocated = try await client.allocate(allocationRequest)
    #expect(allocated.name == "match-prod-abc12")
    #expect(allocated.address == "127.0.0.1")
    #expect(allocated.ports == [AgonesAllocatedGameServer.Port(name: "game", number: 7777)])
    let recorded = await requestLog.last
    #expect(recorded?.namespace == "game-prod")
    #expect(recorded?.scheduling == .distributed)
    #expect(recorded?.metadata.labels == ["match": "match-123"])
    #expect(recorded?.metadata.annotations == ["region": "sa-east-1"])
    #expect(recorded?.gameServerSelectors.first?.matchLabels == ["agones.dev/fleet": "match-prod"])

    await requestLog.rejectNextAllocation()
    do {
        _ = try await client.allocate()
        Issue.record("an unavailable Fleet must produce a typed no-server error")
    } catch {
        #expect(error as? AgonesAllocatorError == .noServerAvailable)
    }
    #expect(await requestLog.callCount == 2)
    let boundedConfiguration = try AgonesAllocatorConfiguration(
        host: "127.0.0.1", port: port, namespace: "game-prod", serverName: "localhost",
        clientCertificatePath: clientCertificate.path, clientPrivateKeyPath: clientKey.path,
        serverCAPath: authorityCertificate.path, timeoutSeconds: 2, maximumResponseBytes: 1_024
    )
    await requestLog.returnOversizedResponseNext()
    do {
        _ = try await AgonesAllocatorClient(configuration: boundedConfiguration).allocate()
        Issue.record("oversized gRPC responses must be reported separately from unavailable capacity")
    } catch {
        #expect(error as? AgonesAllocatorError == .responseTooLarge)
    }
    #expect(await requestLog.callCount == 3)
    server.beginGracefulShutdown()
    try await serverTask.value
}

@available(macOS 15, iOS 18, *)
@Test func agonesAllocatorRejectsInvalidConfigurationAndUnboundedMetadata() throws {
    let readable = "/etc/hosts"
    #expect(throws: AgonesAllocatorError.invalidConfiguration) {
        try AgonesAllocatorConfiguration(host: "https://allocator.invalid", namespace: "default", serverName: "allocator.invalid", clientCertificatePath: readable, clientPrivateKeyPath: readable, serverCAPath: readable)
    }
    #expect(throws: AgonesAllocatorError.invalidConfiguration) {
        try AgonesAllocatorConfiguration(host: "allocator.invalid", namespace: "Default", clientCertificatePath: readable, clientPrivateKeyPath: readable, serverCAPath: readable)
    }
    #expect(throws: AgonesAllocatorError.invalidConfiguration) {
        try AgonesAllocatorConfiguration(host: "127.0.0.1", namespace: "default", clientCertificatePath: readable, clientPrivateKeyPath: readable, serverCAPath: readable)
    }
    #expect(throws: AgonesAllocatorError.invalidRequest) {
        try AgonesAllocationRequest(metadataAnnotations: ["unsafe": String(repeating: "x", count: 257)])
    }
    #expect(throws: AgonesAllocatorError.invalidRequest) {
        try AgonesAllocationRequest(matchLabels: ["invalid\nheader": "value"])
    }
    #expect(throws: AgonesAllocatorError.invalidRequest) {
        try AgonesAllocationRequest(matchLabels: ["not a label": "value"])
    }
}

@available(macOS 15, iOS 18, *)
private actor AgonesAllocationRequestLog {
    private(set) var last: Allocation_AllocationRequest?
    private(set) var callCount = 0
    private var rejectsNext = false
    private var oversizedNext = false

    func record(_ request: Allocation_AllocationRequest) throws -> Allocation_AllocationResponse {
        last = request
        callCount += 1
        if rejectsNext {
            rejectsNext = false
            throw RPCError(code: .resourceExhausted, message: "unallocated")
        }
        var response = Allocation_AllocationResponse()
        response.gameServerName = oversizedNext ? String(repeating: "a", count: 2_048) : "match-prod-abc12"
        oversizedNext = false
        response.address = "127.0.0.1"
        var port = Allocation_AllocationResponse.GameServerStatusPort()
        port.name = "game"
        port.port = 7_777
        response.ports = [port]
        return response
    }

    func rejectNextAllocation() { rejectsNext = true }
    func returnOversizedResponseNext() { oversizedNext = true }
}

@available(macOS 15, iOS 18, *)
private struct StubAgonesAllocatorService: Allocation_AllocationService.SimpleServiceProtocol {
    let requestLog: AgonesAllocationRequestLog
    func allocate(request: Allocation_AllocationRequest, context: ServerContext) async throws -> Allocation_AllocationResponse {
        try await requestLog.record(request)
    }
}

private func makeCertificateAuthority(certificate: URL, key: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-keyout", key.path,
                        "-out", certificate.path, "-subj", "/CN=PearfyTestCA", "-addext", "basicConstraints=critical,CA:TRUE",
                        "-addext", "keyUsage=critical,keyCertSign,cRLSign"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw AgonesSDKError.invalidConfiguration }
}

private func makeIssuedCertificate(certificate: URL, key: URL, commonName: String, authorityCertificate: URL,
                                   authorityKey: URL, san: String, usage: String, directory: URL) throws {
    let request = directory.appendingPathComponent("\(commonName).csr")
    let extensions = directory.appendingPathComponent("\(commonName).ext")
    try "subjectAltName=\(san)\nextendedKeyUsage=\(usage)\nbasicConstraints=critical,CA:FALSE\n".write(to: extensions, atomically: true, encoding: .utf8)
    let createRequest = Process()
    createRequest.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    createRequest.arguments = ["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path,
                              "-out", request.path, "-subj", "/CN=\(commonName)"]
    createRequest.standardOutput = FileHandle.nullDevice
    createRequest.standardError = FileHandle.nullDevice
    try createRequest.run()
    createRequest.waitUntilExit()
    guard createRequest.terminationStatus == 0 else { throw AgonesSDKError.invalidConfiguration }

    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    sign.arguments = ["openssl", "x509", "-req", "-in", request.path, "-CA", authorityCertificate.path,
                      "-CAkey", authorityKey.path, "-CAcreateserial", "-out", certificate.path, "-days", "1", "-extfile", extensions.path]
    sign.standardOutput = FileHandle.nullDevice
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    guard sign.terminationStatus == 0 else { throw AgonesSDKError.invalidConfiguration }
}
