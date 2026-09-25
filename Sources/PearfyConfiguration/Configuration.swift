import Foundation
import PearfyCore

public enum ConfigurationSource: String, Sendable, Equatable {
    case defaults
    case file
    case profile
    case environment
    case commandLine
}

public enum ConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingKey(String)
    case invalidValue(key: String, value: String, expected: String)
    case malformedArgument(String)

    public var code: String {
        switch self {
        case .missingKey: "PEARFY_CONFIG_001"
        case .invalidValue: "PEARFY_CONFIG_002"
        case .malformedArgument: "PEARFY_CONFIG_003"
        }
    }

    public var description: String {
        switch self {
        case .missingKey(let key): return "PEARFY_CONFIG_001: missing configuration key '\(key)'"
        case .invalidValue(let key, let value, let expected):
            let safeValue = isSensitiveConfigurationKey(key) ? "[REDACTED]" : value
            return "PEARFY_CONFIG_002: invalid value '\(safeValue)' for '\(key)' (expected \(expected))"
        case .malformedArgument(let argument): return "PEARFY_CONFIG_003: malformed argument '\(argument)'"
        }
    }

    public var diagnostic: PearfyDiagnostic {
        let prefix = "\(code): "
        let message = description.hasPrefix(prefix) ? String(description.dropFirst(prefix.count)) : description
        return PearfyDiagnostic(code: code, message: message)
    }
}

/// Immutable, typed configuration snapshot captured at application bootstrap.
public struct Configuration: Sendable {
    fileprivate struct Entry: Sendable {
        let value: String
        let source: ConfigurationSource
    }

    private let entries: [String: Entry]
    public let profiles: [String]

    fileprivate init(entries: [String: Entry], profiles: [String]) {
        self.entries = entries
        self.profiles = profiles
    }

    public func string(forKey key: String) throws -> String {
        guard let entry = entries[key] else { throw ConfigurationError.missingKey(key) }
        return entry.value
    }

    public func value<Value: LosslessStringConvertible & Sendable>(
        forKey key: String,
        as type: Value.Type = Value.self
    ) throws -> Value {
        let rawValue = try string(forKey: key)
        guard let value = Value(rawValue) else {
            throw ConfigurationError.invalidValue(
                key: key,
                value: rawValue,
                expected: String(reflecting: type)
            )
        }
        return value
    }

    public func bool(forKey key: String) throws -> Bool {
        let rawValue = try string(forKey: key).lowercased()
        return switch rawValue {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off": false
        default: throw ConfigurationError.invalidValue(key: key, value: rawValue, expected: "Bool")
        }
    }

    public func source(forKey key: String) -> ConfigurationSource? {
        entries[key]?.source
    }

    /// Safe for startup diagnostics: values whose keys look sensitive are redacted.
    public var redactedValues: [String: String] {
        Dictionary(uniqueKeysWithValues: entries.map { key, entry in
            (key, isSensitive(key: key) ? "[REDACTED]" : entry.value)
        })
    }

    private func isSensitive(key: String) -> Bool {
        isSensitiveConfigurationKey(key)
    }
}

private func isSensitiveConfigurationKey(_ key: String) -> Bool {
    let normalized = key.lowercased().replacingOccurrences(of: "-", with: ".")
    return ["password", "passwd", "secret", "token", "api.key", "apikey", "private.key", "credential"]
        .contains(where: normalized.contains)
}

/// Loads values in increasing precedence: defaults, file, active profiles,
/// environment, then command-line arguments.
public enum ConfigurationLoader {
    public static func load(
        defaults: [String: String] = [:],
        fileContents: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = [],
        activeProfiles: [String] = [],
        environmentPrefix: String = "PEARFY_"
    ) throws -> Configuration {
        var entries = defaults.mapValues { Configuration.Entry(value: $0, source: .defaults) }
        var fileValues: [String: String] = [:]
        var profileValues: [String: [String: String]] = [:]

        if let fileContents {
            for (lineNumber, rawLine) in fileContents.split(whereSeparator: \.isNewline).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
                guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else {
                    throw ConfigurationError.malformedArgument("file line \(lineNumber + 1)")
                }
                let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw ConfigurationError.malformedArgument("file line \(lineNumber + 1)") }

                if key.hasPrefix("profile."), let profileKeySeparator = key.dropFirst("profile.".count).firstIndex(of: ".") {
                    let profileStart = key.index(key.startIndex, offsetBy: "profile.".count)
                    let profile = String(key[profileStart..<profileKeySeparator])
                    let configKey = String(key[key.index(after: profileKeySeparator)...])
                    profileValues[profile, default: [:]][configKey] = value
                } else {
                    fileValues[key] = value
                }
            }
        }

        apply(fileValues, source: .file, to: &entries)

        let envProfiles = environment["\(environmentPrefix)PROFILES"]?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let (argumentValues, argumentProfiles) = try parseArguments(arguments)
        var profiles = activeProfiles + envProfiles + argumentProfiles
        var seenProfiles: Set<String> = []
        profiles = profiles.filter { !$0.isEmpty && seenProfiles.insert($0).inserted }

        for profile in profiles {
            apply(profileValues[profile, default: [:]], source: .profile, to: &entries)
        }

        var environmentValues: [String: String] = [:]
        for (name, value) in environment where name.hasPrefix(environmentPrefix) {
            let suffix = String(name.dropFirst(environmentPrefix.count))
            guard !suffix.isEmpty, suffix != "PROFILES" else { continue }
            let key = suffix.lowercased().replacingOccurrences(of: "_", with: ".")
            environmentValues[key] = value
        }
        apply(environmentValues, source: .environment, to: &entries)
        apply(argumentValues, source: .commandLine, to: &entries)
        return Configuration(entries: entries, profiles: profiles)
    }

    private static func apply(
        _ values: [String: String],
        source: ConfigurationSource,
        to entries: inout [String: Configuration.Entry]
    ) {
        for (key, value) in values {
            entries[key] = Configuration.Entry(value: value, source: source)
        }
    }

    private static func parseArguments(_ arguments: [String]) throws -> ([String: String], [String]) {
        var values: [String: String] = [:]
        var profiles: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { throw ConfigurationError.malformedArgument(argument) }
            let option = String(argument.dropFirst(2))
            let key: String
            let value: String
            if let separator = option.firstIndex(of: "=") {
                key = String(option[..<separator])
                value = String(option[option.index(after: separator)...])
            } else {
                key = option
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ConfigurationError.malformedArgument(argument)
                }
                value = arguments[index]
            }

            guard !key.isEmpty else { throw ConfigurationError.malformedArgument(argument) }
            if key == "profile" || key == "profiles" {
                profiles += value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            } else {
                values[key] = value
            }
            index += 1
        }
        return (values, profiles)
    }
}
