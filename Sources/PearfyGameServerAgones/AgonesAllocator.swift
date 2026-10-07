import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix

public enum AgonesAllocatorError: Error, Sendable, Equatable {
    case invalidConfiguration
    case invalidRequest
    case unavailable
    case noServerAvailable
    case invalidResponse
    case responseTooLarge
}

private enum AgonesAddressValidation {
    static func isEndpointHost(_ value: String) -> Bool {
        isIPv4(value) || isIPv6(value) || isDNSName(value)
    }

    static func isDNSName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.utf8.first.map(isAlphaNumeric) == true &&
                label.utf8.last.map(isAlphaNumeric) == true &&
                label.utf8.allSatisfy({ isAlphaNumeric($0) || $0 == 45 })
        }
    }

    static func isIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy({ (48...57).contains($0) }) &&
                Int(part).map { (0...255).contains($0) } == true
        }
    }

    private static func isIPv6(_ value: String) -> Bool {
        guard value.contains(":"), !value.contains(":::"), value.components(separatedBy: "::").count <= 2,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 58 || $0 == 46 }) else {
            return false
        }
        var components = value.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        var groupCount = components.count
        if let last = components.last, last.contains(".") {
            guard isIPv4(last) else { return false }
            components.removeLast()
            groupCount += 1
        }
        let compressed = value.contains("::")
        guard groupCount <= 8, compressed ? groupCount < 8 : groupCount == 8 else { return false }
        return components.allSatisfy { part in
            part.count <= 4 && part.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

/// TLS and mTLS material for the out-of-cluster Agones Allocator Service.
@available(macOS 15, iOS 18, *)
public struct AgonesAllocatorConfiguration: Sendable, Equatable {
    public let host: String
    public let serverName: String
    public let port: Int
    public let namespace: String
    public let clientCertificatePath: String
    public let clientPrivateKeyPath: String
    public let serverCAPath: String
    public let timeoutSeconds: Int
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int

    public init(
        host: String,
        port: Int = 443,
        namespace: String,
        serverName: String? = nil,
        clientCertificatePath: String,
        clientPrivateKeyPath: String,
        serverCAPath: String,
        timeoutSeconds: Int = 5,
        maximumRequestBytes: Int = 65_536,
        maximumResponseBytes: Int = 65_536
    ) throws {
        let normalizedHost = host.lowercased()
        let validHost = AgonesAddressValidation.isEndpointHost(normalizedHost)
        let selectedServerName = (serverName ?? (Self.isIPAddress(normalizedHost) ? "" : normalizedHost)).lowercased()
        let validServerName = AgonesAddressValidation.isDNSName(selectedServerName) && !AgonesAddressValidation.isIPv4(selectedServerName)
        let validNamespace = namespace.utf8.count <= 63 && !namespace.isEmpty &&
            namespace.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 } &&
            namespace.utf8.first.map({ (97...122).contains($0) || (48...57).contains($0) }) == true &&
            namespace.utf8.last.map({ (97...122).contains($0) || (48...57).contains($0) }) == true
        guard validHost, validServerName, (1...65_535).contains(port), validNamespace,
              Self.readablePEM(clientCertificatePath), Self.readablePEM(clientPrivateKeyPath), Self.readablePEM(serverCAPath),
              (1...60).contains(timeoutSeconds), (1_024...1_048_576).contains(maximumRequestBytes),
              (1_024...1_048_576).contains(maximumResponseBytes) else {
            throw AgonesAllocatorError.invalidConfiguration
        }
        self.host = normalizedHost
        self.serverName = selectedServerName
        self.port = port
        self.namespace = namespace
        self.clientCertificatePath = clientCertificatePath
        self.clientPrivateKeyPath = clientPrivateKeyPath
        self.serverCAPath = serverCAPath
        self.timeoutSeconds = timeoutSeconds
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    private static func readablePEM(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && FileManager.default.isReadableFile(atPath: path)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        AgonesAddressValidation.isIPv4(host) || host.contains(":")
    }
}

/// An allocation request constrained to current Agones selector and metadata fields.
@available(macOS 15, iOS 18, *)
public struct AgonesAllocationRequest: Sendable, Equatable {
    public enum Scheduling: Sendable, Equatable { case packed, distributed }
    public let matchLabels: [String: String]
    public let metadataLabels: [String: String]
    public let metadataAnnotations: [String: String]
    public let scheduling: Scheduling

    public init(
        matchLabels: [String: String] = [:],
        metadataLabels: [String: String] = [:],
        metadataAnnotations: [String: String] = [:],
        scheduling: Scheduling = .packed
    ) throws {
        guard matchLabels.count <= 64, metadataLabels.count <= 64, metadataAnnotations.count <= 64,
              Self.validLabels(matchLabels), Self.validLabels(metadataLabels),
              Self.validAnnotations(metadataAnnotations) else { throw AgonesAllocatorError.invalidRequest }
        self.matchLabels = matchLabels
        self.metadataLabels = metadataLabels
        self.metadataAnnotations = metadataAnnotations
        self.scheduling = scheduling
    }

    fileprivate func proto(namespace: String) -> Allocation_AllocationRequest {
        var message = Allocation_AllocationRequest()
        message.namespace = namespace
        message.scheduling = scheduling == .distributed ? .distributed : .packed
        message.metadata.labels = metadataLabels
        message.metadata.annotations = metadataAnnotations
        var selector = Allocation_GameServerSelector()
        selector.matchLabels = matchLabels
        selector.gameServerState = .ready
        message.gameServerSelectors = matchLabels.isEmpty ? [] : [selector]
        return message
    }

    private static func validLabels(_ values: [String: String]) -> Bool {
        values.allSatisfy { key, value in
            validLabelKey(key) && value.utf8.count <= 63 &&
                (value.isEmpty || (value.utf8.allSatisfy(labelByte) && value.utf8.first.map(isAlphaNumeric) == true && value.utf8.last.map(isAlphaNumeric) == true))
        }
    }

    private static func validAnnotations(_ values: [String: String]) -> Bool {
        values.allSatisfy { key, value in
            validLabelKey(key) && value.utf8.count <= 256 && value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 })
        }
    }

    private static func validLabelKey(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        let name = parts.last!
        guard (1...63).contains(name.utf8.count), name.utf8.allSatisfy(labelByte),
              name.utf8.first.map(isAlphaNumeric) == true, name.utf8.last.map(isAlphaNumeric) == true else { return false }
        guard parts.count == 2 else { return true }
        let prefix = String(parts[0])
        guard prefix.utf8.count <= 253 else { return false }
        return prefix.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.utf8.first.map(isAlphaNumeric) == true &&
                label.utf8.last.map(isAlphaNumeric) == true && label.utf8.allSatisfy({ isAlphaNumeric($0) || $0 == 45 })
        }
    }

    private static func labelByte(_ byte: UInt8) -> Bool {
        isAlphaNumeric(byte) || byte == 45 || byte == 46 || byte == 95
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

@available(macOS 15, iOS 18, *)
public struct AgonesAllocatedGameServer: Sendable, Equatable {
    public struct Port: Sendable, Equatable {
        public let name: String
        public let number: Int
        public init(name: String, number: Int) { self.name = name; self.number = number }
    }
    public let name: String
    public let address: String
    public let ports: [Port]
    public let nodeName: String?
}

/// Single-attempt, deadline-bounded client for Agones' mTLS Allocator gRPC API.
/// An allocation is not retried automatically because the outcome may be ambiguous after a timeout.
@available(macOS 15, iOS 18, *)
public struct AgonesAllocatorClient: Sendable {
    private let configuration: AgonesAllocatorConfiguration

    public init(configuration: AgonesAllocatorConfiguration) { self.configuration = configuration }

    public func allocate() async throws -> AgonesAllocatedGameServer {
        try await allocate(AgonesAllocationRequest())
    }

    public func allocate(_ request: AgonesAllocationRequest) async throws -> AgonesAllocatedGameServer {
        let protoRequest = request.proto(namespace: configuration.namespace)
        guard try protoRequest.serializedData().count <= configuration.maximumRequestBytes else { throw AgonesAllocatorError.invalidRequest }
        let clientTLS = HTTP2ClientTransport.Posix.TransportSecurity.mTLS(
            certificateChain: [.file(path: configuration.clientCertificatePath, format: .pem)],
            privateKey: .file(path: configuration.clientPrivateKeyPath, format: .pem)
        ) {
            $0.serverCertificateVerification = .fullVerification
            $0.trustRoots = .certificates([.file(path: configuration.serverCAPath, format: .pem)])
        }
        var transportConfig = HTTP2ClientTransport.Posix.Config.defaults
        transportConfig.http2.authority = "\(configuration.serverName):\(configuration.port)"
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: configuration.host, port: configuration.port),
            transportSecurity: clientTLS,
            config: transportConfig
        )
        do {
            return try await withGRPCClient(transport: transport) { client in
                let service = Allocation_AllocationService.Client(wrapping: client)
                var options = CallOptions.defaults
                options.timeout = .seconds(Int64(configuration.timeoutSeconds))
                options.maxRequestMessageBytes = configuration.maximumRequestBytes
                options.maxResponseMessageBytes = configuration.maximumResponseBytes
                let response = try await service.allocate(protoRequest, options: options)
                guard try response.serializedData().count <= configuration.maximumResponseBytes else {
                    throw AgonesAllocatorError.responseTooLarge
                }
                return try Self.project(response)
            }
        } catch let error as RPCError where error.code == .resourceExhausted {
            if error.message.localizedCaseInsensitiveContains("message larger than max") {
                throw AgonesAllocatorError.responseTooLarge
            }
            throw AgonesAllocatorError.noServerAvailable
        } catch is RPCError {
            throw AgonesAllocatorError.unavailable
        } catch let error as AgonesAllocatorError {
            throw error
        } catch {
            throw AgonesAllocatorError.unavailable
        }
    }

    private static func project(_ response: Allocation_AllocationResponse) throws -> AgonesAllocatedGameServer {
        guard AgonesAddressValidation.isDNSName(response.gameServerName),
              AgonesAddressValidation.isEndpointHost(response.address),
              (1...64).contains(response.ports.count) else { throw AgonesAllocatorError.invalidResponse }
        let ports = response.ports.map { AgonesAllocatedGameServer.Port(name: $0.name, number: Int($0.port)) }
        guard ports.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 63 && (1...65_535).contains($0.number) }) else {
            throw AgonesAllocatorError.invalidResponse
        }
        guard response.nodeName.isEmpty || AgonesAddressValidation.isDNSName(response.nodeName) else {
            throw AgonesAllocatorError.invalidResponse
        }
        return AgonesAllocatedGameServer(
            name: response.gameServerName,
            address: response.address,
            ports: ports,
            nodeName: response.nodeName.isEmpty ? nil : response.nodeName
        )
    }
}
