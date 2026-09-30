import Foundation
import Logging
import PearfyObservability
import PostgresNIO

public enum PearfyPostgresTLSMode: Sendable, Equatable {
    case disabled
    case prefer
    case required
}

public enum PearfyPostgresSettingsError: Error, Sendable, Equatable {
    case invalidHost
    case invalidPort
    case invalidMaximumConnections
    case invalidConnectTimeout
}

/// Application-facing PostgreSQL settings. Consumers configure the Pearfy
/// adapter without depending on PostgresNIO's driver configuration types.
public struct PearfyPostgresConnectionSettings: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String?
    public let database: String?
    public let tls: PearfyPostgresTLSMode
    public let maximumConnections: Int
    public let connectTimeout: Duration

    public init(
        host: String,
        port: Int = 5432,
        username: String,
        password: String? = nil,
        database: String? = nil,
        tls: PearfyPostgresTLSMode = .prefer,
        maximumConnections: Int = 10,
        connectTimeout: Duration = .seconds(5)
    ) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PearfyPostgresSettingsError.invalidHost
        }
        guard (1...65535).contains(port) else { throw PearfyPostgresSettingsError.invalidPort }
        guard (1...1000).contains(maximumConnections) else {
            throw PearfyPostgresSettingsError.invalidMaximumConnections
        }
        guard connectTimeout > .zero else { throw PearfyPostgresSettingsError.invalidConnectTimeout }
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tls = tls
        self.maximumConnections = maximumConnections
        self.connectTimeout = connectTimeout
    }

    fileprivate func makeDriverConfiguration() -> PostgresClient.Configuration {
        let tlsConfiguration: PostgresClient.Configuration.TLS
        switch tls {
        case .disabled:
            tlsConfiguration = .disable
        case .prefer:
            tlsConfiguration = .prefer(.makeClientConfiguration())
        case .required:
            tlsConfiguration = .require(.makeClientConfiguration())
        }
        var configuration = PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: tlsConfiguration
        )
        configuration.options.maximumConnections = maximumConnections
        configuration.options.minimumConnections = 0
        configuration.options.connectTimeout = connectTimeout
        return configuration
    }
}

public extension PearfyPostgresDatabase {
    init(
        settings: PearfyPostgresConnectionSettings,
        logger: Logger = Logger(label: "Pearfy.Postgres"),
        metrics: MetricsRegistry? = nil,
        telemetry: InProcessTelemetryStore? = nil
    ) {
        self.init(
            configuration: settings.makeDriverConfiguration(),
            logger: logger,
            metrics: metrics,
            telemetry: telemetry
        )
    }
}
