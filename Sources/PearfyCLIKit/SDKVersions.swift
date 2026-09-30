import Foundation
import PearfyDevKitUI

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// CLI view of the SDK releases recorded in the Module Registry.
public enum PearfySDKVersionCommand {
    public static func run(_ arguments: [String]) throws -> Int32 {
        guard arguments.count == 1, (arguments[0] == "versions" || arguments[0] == "list") else {
            throw PearfySDKVersionError.usage
        }
        let releases = try PearfyModuleManager().sdkReleases()
        print("Pearfy SDK capability milestones available in this checkout")
        for release in releases {
            print("\(release.version)\t\(release.name) — \(release.summary)")
            print("  modules: \(release.modules.joined(separator: ", "))")
            for command in release.commands { print("  \(command)") }
        }
        return 0
    }
}

private enum PearfySDKVersionError: Error, CustomStringConvertible {
    case usage

    var description: String {
        "Usage: pearfy sdk <versions|list>"
    }
}

public enum PearfyDevKitCLICommand {
    private static let defaultDashboardURL = "http://127.0.0.1:8080/__pearfy/devkit"
    private static let maximumResponseBytes = 1_048_576

    public static func run(_ arguments: [String], projectRoot: URL) async throws -> Int32 {
        guard let action = arguments.first,
              ["start", "open", "doctor", "export"].contains(action) else {
            throw PearfyDevKitCLIError.usage
        }
        let options = try Options(arguments: Array(arguments.dropFirst()), action: action)
        let dashboardURL = try safeDashboardURL(options.url)

        switch action {
        case "open":
            try openBrowser(at: dashboardURL)
            print("Opened Pearfy DevKit at \(dashboardURL.absoluteString)")
        case "start":
            try requireManagedModule(projectRoot: projectRoot)
            try await waitForDashboard(at: dashboardURL, timeoutSeconds: options.waitSeconds)
            try openBrowser(at: dashboardURL)
            print("Opened Pearfy DevKit at \(dashboardURL.absoluteString)")
        case "doctor":
            try requireManagedModule(projectRoot: projectRoot)
            try await checkDashboard(at: dashboardURL)
            print("Pearfy DevKit is installed and responding at \(dashboardURL.absoluteString)")
        case "export":
            try requireManagedModule(projectRoot: projectRoot)
            let token = try accessToken()
            try await exportSnapshot(
                from: dashboardURL,
                token: token,
                query: options.query,
                outputPath: options.outputPath
            )
        default:
            throw PearfyDevKitCLIError.usage
        }
        return 0
    }

    public static func dashboardURL(from value: String?) throws -> URL {
        let raw = value ?? defaultDashboardURL
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw PearfyDevKitCLIError.invalidURL
        }
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let loopback = normalizedHost == "localhost"
            || normalizedHost == "::1"
            || normalizedHost.hasPrefix("127.")
        if !loopback {
            let token = ProcessInfo.processInfo.environment["PEARFY_DEVKIT_TOKEN"] ?? ""
            guard scheme == "https", (16...256).contains(token.utf8.count) else {
                throw PearfyDevKitCLIError.remoteAccessRequiresTLSAndToken
            }
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components?.path = "/__pearfy/devkit"
        } else if path == "__pearfy/devkit" {
            components?.path = "/__pearfy/devkit"
        } else if path.hasSuffix("/__pearfy/devkit") {
            components?.path = "/" + path
        } else {
            throw PearfyDevKitCLIError.invalidURL
        }
        guard let result = components?.url else { throw PearfyDevKitCLIError.invalidURL }
        return result
    }

    private struct Options {
        let url: String?
        let waitSeconds: Int
        let query: DevKitExportQuery
        let outputPath: String?

        init(arguments: [String], action: String) throws {
            var url: String?
            var waitSeconds = 30
            var window = "15m"
            var instance: String?
            var outputPath: String?
            var seen: Set<String> = []
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                guard ["--url", "--wait-seconds", "--window", "--instance", "--output"].contains(flag) else {
                    throw PearfyDevKitCLIError.unknownOption(flag)
                }
                guard seen.insert(flag).inserted else { throw PearfyDevKitCLIError.duplicateOption(flag) }
                guard index + 1 < arguments.count else { throw PearfyDevKitCLIError.missingValue(flag) }
                let value = arguments[index + 1]
                switch flag {
                case "--url": url = value
                case "--wait-seconds":
                    guard let parsed = Int(value), (1...120).contains(parsed) else {
                        throw PearfyDevKitCLIError.invalidWaitTime
                    }
                    waitSeconds = parsed
                case "--window": window = value
                case "--instance": instance = value
                case "--output": outputPath = value
                default: throw PearfyDevKitCLIError.usage
                }
                index += 2
            }
            let allowed: Set<String>
            switch action {
            case "start": allowed = ["--url", "--wait-seconds"]
            case "open", "doctor": allowed = ["--url"]
            case "export": allowed = ["--url", "--window", "--instance", "--output"]
            default: allowed = []
            }
            guard seen.isSubset(of: allowed) else { throw PearfyDevKitCLIError.usage }
            guard let parsedWindow = DevKitWindow(rawValue: window) else {
                throw PearfyDevKitCLIError.invalidWindow(window)
            }
            if let instance {
                guard !instance.isEmpty, instance.utf8.count <= 128,
                      instance.utf8.allSatisfy({
                          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                              || $0 == 45 || $0 == 46 || $0 == 95
                      }) else {
                    throw PearfyDevKitCLIError.invalidInstance(instance)
                }
            }
            self.url = url
            self.waitSeconds = waitSeconds
            query = DevKitExportQuery(window: parsedWindow, instanceID: instance)
            self.outputPath = outputPath
        }
    }

    private struct DevKitExportQuery {
        let window: DevKitWindow
        let instanceID: String?
    }

    private static func safeDashboardURL(_ value: String?) throws -> URL {
        try dashboardURL(from: value)
    }

    private static func requireManagedModule(projectRoot: URL) throws {
        let modules = try PearfyModuleManager().doctor(projectRoot: projectRoot)
        guard modules.contains("devkit-ui") else {
            throw PearfyDevKitCLIError.moduleNotInstalled
        }
    }

    private static func checkDashboard(at url: URL) async throws {
        let (_, response) = try await fetch(url: url, token: nil)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.value(forHTTPHeaderField: "content-type")?.hasPrefix("text/html") == true else {
            throw PearfyDevKitCLIError.dashboardUnavailable
        }
    }

    private static func waitForDashboard(at url: URL, timeoutSeconds: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        while clock.now < deadline {
            do {
                try await checkDashboard(at: url)
                return
            } catch {
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw PearfyDevKitCLIError.dashboardUnavailable
    }

    private static func exportSnapshot(
        from dashboardURL: URL,
        token: String,
        query: DevKitExportQuery,
        outputPath: String?
    ) async throws {
        let endpointNames = ["overview", "routes", "traces", "errors", "logs", "instances", "queries"]
        var snapshot: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "requestedWindow": query.window.rawValue
        ]
        if let instanceID = query.instanceID { snapshot["instanceID"] = instanceID }
        for name in endpointNames {
            var components = URLComponents(url: dashboardURL, resolvingAgainstBaseURL: false)
            components?.path = dashboardURL.path + "/api/\(name)"
            var items = [URLQueryItem(name: "window", value: query.window.rawValue)]
            if let instanceID = query.instanceID { items.append(URLQueryItem(name: "instance", value: instanceID)) }
            components?.queryItems = items
            guard let endpoint = components?.url else { throw PearfyDevKitCLIError.invalidURL }
            let (data, response) = try await fetch(url: endpoint, token: token)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PearfyDevKitCLIError.dashboardUnavailable
            }
            do {
                snapshot[name] = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw PearfyDevKitCLIError.invalidDashboardResponse
            }
        }

        let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let outputPath {
            let outputURL = URL(fileURLWithPath: outputPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard !FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue else {
                throw PearfyDevKitCLIError.invalidOutputPath(outputURL.path)
            }
            try data.write(to: outputURL, options: .atomic)
            print("DevKit snapshot exported to \(outputURL.path)")
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }

    private static func fetch(url: URL, token: String?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard data.count <= maximumResponseBytes else { throw PearfyDevKitCLIError.responseTooLarge }
        return (data, response)
    }

    private static func accessToken() throws -> String {
        guard let token = ProcessInfo.processInfo.environment["PEARFY_DEVKIT_TOKEN"],
              (16...256).contains(token.utf8.count) else {
            throw PearfyDevKitCLIError.tokenRequired
        }
        return token
    }

    private static func openBrowser(at url: URL) throws {
        #if os(macOS)
        let executable = "/usr/bin/open"
        #elseif os(Linux)
        let executable = "/usr/bin/xdg-open"
        #else
        throw PearfyDevKitCLIError.browserUnavailable
        #endif
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw PearfyDevKitCLIError.browserUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PearfyDevKitCLIError.browserUnavailable }
    }
}

private enum PearfyDevKitCLIError: Error, CustomStringConvertible {
    case usage
    case unknownOption(String)
    case duplicateOption(String)
    case missingValue(String)
    case invalidURL
    case remoteAccessRequiresTLSAndToken
    case moduleNotInstalled
    case dashboardUnavailable
    case invalidDashboardResponse
    case responseTooLarge
    case tokenRequired
    case browserUnavailable
    case invalidOutputPath(String)
    case invalidWindow(String)
    case invalidInstance(String)
    case invalidWaitTime

    var description: String {
        switch self {
        case .usage:
            "Usage: pearfy devkit <start|open|doctor|export> [--url <dashboard-url>] [options]"
        case .unknownOption(let flag): "unknown option: \(flag)"
        case .duplicateOption(let flag): "option provided more than once: \(flag)"
        case .missingValue(let flag): "missing value for \(flag)"
        case .invalidURL: "invalid dashboard URL; use an origin or a /__pearfy/devkit URL"
        case .remoteAccessRequiresTLSAndToken: "remote DevKit URLs require HTTPS and PEARFY_DEVKIT_TOKEN"
        case .moduleNotInstalled: "devkit-ui is not selected in this managed project; run `pearfy add devkit-ui`"
        case .dashboardUnavailable: "DevKit dashboard is unavailable or returned an unexpected response"
        case .invalidDashboardResponse: "DevKit returned invalid JSON"
        case .responseTooLarge: "DevKit response exceeds the 1 MiB limit"
        case .tokenRequired: "set PEARFY_DEVKIT_TOKEN to export protected DevKit data"
        case .browserUnavailable: "could not open a browser on this platform"
        case .invalidOutputPath(let path): "invalid DevKit export path: \(path)"
        case .invalidWindow(let value): "unsupported time window '\(value)'; use 15m, 1h, or 24h"
        case .invalidInstance(let value): "invalid instance ID '\(value)'"
        case .invalidWaitTime: "--wait-seconds must be between 1 and 120"
        }
    }
}
