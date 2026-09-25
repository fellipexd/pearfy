import Foundation

/// One reviewable, format-versioned migration artifact. SQL values remain
/// parameterized in the artifact and are included in the migration checksum.
public struct SQLMigrationArtifact: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let id: String
    public let up: SQLMigrationCommand
    public let down: SQLMigrationCommand?

    public init(
        formatVersion: Int = 1,
        id: String,
        up: SQLMigrationCommand,
        down: SQLMigrationCommand? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.up = up
        self.down = down
    }

    public var migration: SQLMigration {
        SQLMigration(id: id, up: up.query, down: down?.query)
    }

    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data([0x0a])
    }
}

public struct SQLMigrationCommand: Codable, Equatable, Sendable {
    public let sql: String
    public let parameters: [SQLValue]

    public init(sql: String, parameters: [SQLValue] = []) {
        self.sql = sql
        self.parameters = parameters
    }

    fileprivate var query: SQLQuery {
        SQLQuery(unsafeSQL: sql, parameters: parameters)
    }
}

public enum SQLMigrationCatalogError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidDirectory(String)
    case noArtifacts(String)
    case invalidArtifact(path: String, reason: String)
    case unsupportedFormatVersion(path: String, version: Int)
    case filenameDoesNotMatch(path: String, id: String)
    case symbolicLinkNotAllowed(String)

    public var description: String {
        switch self {
        case .invalidDirectory(let path): "PEARFY_DATA_009: migration catalog directory is invalid: \(path)"
        case .noArtifacts(let path): "PEARFY_DATA_010: no migration artifacts found in '\(path)'"
        case .invalidArtifact(let path, let reason): "PEARFY_DATA_011: invalid migration artifact '\(path)': \(reason)"
        case .unsupportedFormatVersion(let path, let version):
            "PEARFY_DATA_012: unsupported migration artifact version \(version) in '\(path)'"
        case .filenameDoesNotMatch(let path, let id):
            "PEARFY_DATA_013: migration artifact filename '\(path)' does not match id '\(id)'"
        case .symbolicLinkNotAllowed(let path): "PEARFY_DATA_014: migration catalog does not follow symbolic links: \(path)"
        }
    }
}

/// Loads immutable SQL migration artifacts from a project-owned directory.
/// A catalog contains the complete ordered source list for one migration scope.
public struct SQLMigrationCatalog: Sendable {
    public let migrations: [SQLMigration]

    public init(directory: URL) throws {
        let directoryValues: URLResourceValues
        do {
            directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw SQLMigrationCatalogError.invalidDirectory(directory.path)
        }
        guard directoryValues.isDirectory == true else {
            throw SQLMigrationCatalogError.invalidDirectory(directory.path)
        }
        guard directoryValues.isSymbolicLink != true else {
            throw SQLMigrationCatalogError.symbolicLinkNotAllowed(directory.path)
        }

        let artifactURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !artifactURLs.isEmpty else {
            throw SQLMigrationCatalogError.noArtifacts(directory.path)
        }

        var migrations: [SQLMigration] = []
        let decoder = JSONDecoder()
        for artifactURL in artifactURLs {
            let path = artifactURL.path
            let values = try artifactURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw SQLMigrationCatalogError.symbolicLinkNotAllowed(path)
            }
            guard values.isRegularFile == true else {
                throw SQLMigrationCatalogError.invalidArtifact(path: path, reason: "not a regular file")
            }

            let artifact: SQLMigrationArtifact
            do {
                artifact = try decoder.decode(SQLMigrationArtifact.self, from: Data(contentsOf: artifactURL))
            } catch {
                throw SQLMigrationCatalogError.invalidArtifact(path: path, reason: String(describing: error))
            }
            guard artifact.formatVersion == 1 else {
                throw SQLMigrationCatalogError.unsupportedFormatVersion(path: path, version: artifact.formatVersion)
            }
            guard artifactURL.deletingPathExtension().lastPathComponent == artifact.id else {
                throw SQLMigrationCatalogError.filenameDoesNotMatch(path: path, id: artifact.id)
            }
            guard Self.isValidSQL(artifact.up.sql), artifact.down.map({ Self.isValidSQL($0.sql) }) ?? true else {
                throw SQLMigrationCatalogError.invalidArtifact(path: path, reason: "SQL statements must be non-empty and cannot contain NUL")
            }
            migrations.append(artifact.migration)
        }

        self.migrations = try SQLMigrationRunner.ordered(migrations)
    }

    private static func isValidSQL(_ sql: String) -> Bool {
        !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sql.unicodeScalars.contains(where: { $0.value == 0 })
    }
}
