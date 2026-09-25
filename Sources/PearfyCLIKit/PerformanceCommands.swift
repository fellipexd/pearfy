import Foundation

public enum PearfyPerformanceCommand {
    public static func benchmark(frameworkRoot: URL, arguments: [String]) throws -> Int32 {
        let script = frameworkRoot.appendingPathComponent("scripts/benchmark-di.sh")
        if FileManager.default.fileExists(atPath: script.path) {
            return try launch(executable: "/usr/bin/env", arguments: ["bash", script.path] + arguments)
        }

        let sibling = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("pearfy-bench")
        if let sibling, FileManager.default.isExecutableFile(atPath: sibling.path) {
            return try launch(executable: sibling.path, arguments: arguments)
        }

        return try launch(
            executable: "/usr/bin/env",
            arguments: ["swift", "run", "-c", "release", "--package-path", frameworkRoot.path, "pearfy-bench"] + arguments
        )
    }

    public static func doctorPerformance(frameworkRoot: URL) -> Int32 {
        print("Pearfy performance diagnostics")
        print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Architecture: \(architecture())")
        print("Framework checkout: \(frameworkRoot.path)")
        print("Package.swift: \(FileManager.default.fileExists(atPath: frameworkRoot.appendingPathComponent("Package.swift").path) ? "available" : "missing")")
        print("Benchmark script: \(FileManager.default.fileExists(atPath: frameworkRoot.appendingPathComponent("scripts/benchmark-di.sh").path) ? "available" : "missing")")

        #if os(macOS)
        let xctraceAvailable = canFindXcodeTool("xctrace")
        let sampleAvailable = executableOnPath("sample") != nil
        print("CPU profiler (xctrace/sample): \(xctraceAvailable || sampleAvailable ? "available" : "unavailable")")
        print("Memory profiler (xctrace/heap or RSS sampling): \(xctraceAvailable || executableOnPath("ps") != nil ? "available" : "unavailable")")
        #elseif os(Linux)
        print("CPU profiler (perf): \(executableOnPath("perf") == nil ? "unavailable" : "available")")
        let memoryProfiler = executableOnPath("heaptrack") ?? executableOnPath("valgrind")
        print("Memory profiler (heaptrack/valgrind): \(memoryProfiler == nil ? "unavailable" : "available")")
        #else
        print("Host profiling: unsupported platform")
        #endif

        return FileManager.default.fileExists(atPath: frameworkRoot.appendingPathComponent("Package.swift").path) ? 0 : 1
    }

    public static func profile(kind: String, arguments: [String]) throws -> Int32 {
        guard kind == "cpu" || kind == "memory" else {
            throw PerformanceCommandError.usage
        }
        let command = arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
        guard !command.isEmpty else { throw PerformanceCommandError.missingProfileTarget(kind) }

        #if os(macOS)
        if canFindXcodeTool("xctrace") {
            let template = kind == "cpu" ? "Time Profiler" : "Allocations"
            return try launch(
                executable: "/usr/bin/env",
                arguments: ["xcrun", "xctrace", "record", "--template", template, "--launch", "--"] + command
            )
        }
        return try profileWithMacOSFallback(kind: kind, command: command)
        #elseif os(Linux)
        if kind == "cpu" {
            return try launch(executable: "/usr/bin/env", arguments: ["perf", "record", "-g", "--"] + command)
        }
        if executableOnPath("heaptrack") != nil {
            return try launch(executable: "/usr/bin/env", arguments: ["heaptrack"] + command)
        }
        if executableOnPath("valgrind") != nil {
            return try launch(executable: "/usr/bin/env", arguments: ["valgrind", "--tool=massif"] + command)
        }
        throw PerformanceCommandError.profilerUnavailable("install heaptrack or valgrind for memory profiling")
        #else
        throw PerformanceCommandError.profilerUnavailable("profiling is unsupported on this platform")
        #endif
    }

    private static func launch(executable: String, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    #if os(macOS)
    private static func profileWithMacOSFallback(kind: String, command: [String]) throws -> Int32 {
        let duration = profileDurationSeconds()
        let outputDirectory = ProcessInfo.processInfo.environment["PEARFY_PROFILE_OUTPUT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let identifier = UUID().uuidString
        let target = Process()
        target.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        target.arguments = command
        target.standardInput = FileHandle.standardInput
        target.standardOutput = FileHandle.standardOutput
        target.standardError = FileHandle.standardError
        try target.run()

        do {
            if kind == "cpu" {
                guard let sample = executableOnPath("sample") else {
                    throw PerformanceCommandError.profilerUnavailable("xctrace and sample are unavailable")
                }
                let output = outputDirectory.appendingPathComponent("pearfy-profile-cpu-\(identifier).txt")
                let status = try launch(
                    executable: sample.path,
                    arguments: [String(target.processIdentifier), String(duration), "1", "-mayDie", "-file", output.path]
                )
                print("CPU sample written to \(output.path)")
                stop(target)
                return status
            }

            guard let ps = executableOnPath("ps") else {
                throw PerformanceCommandError.profilerUnavailable("xctrace and ps are unavailable")
            }
            let processID = String(target.processIdentifier)
            let output = outputDirectory.appendingPathComponent("pearfy-profile-memory-\(identifier).csv")
            var rows = ["elapsed_ms,rss_kb"]
            let start = Date()
            var peakRSSKilobytes = 0
            for index in 0..<(duration * 10) {
                guard target.isRunning else { break }
                let snapshot = try captureOutput(executable: ps.path, arguments: ["-o", "rss=", "-p", processID])
                if snapshot.status == 0,
                   let rss = snapshot.output.split(whereSeparator: \.isWhitespace).first.flatMap({ Int($0) }) {
                    peakRSSKilobytes = max(peakRSSKilobytes, rss)
                    let sampleMilliseconds = Int(Date().timeIntervalSince(start) * 1_000)
                    rows.append("\(sampleMilliseconds),\(rss)")
                }
                if index + 1 < duration * 10 { Thread.sleep(forTimeInterval: 0.1) }
            }
            guard rows.count > 1 else { throw PerformanceCommandError.profilerUnavailable("could not sample target RSS") }
            try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: output, options: .atomic)
            let elapsed = Int(Date().timeIntervalSince(start) * 1_000)
            print("RSS samples written to \(output.path) (peak \(peakRSSKilobytes) KB over \(elapsed) ms)")
            stop(target)
            return 0
        } catch {
            stop(target)
            throw error
        }
    }

    private static func capture(executable: String, arguments: [String], output: URL) throws -> Int32 {
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw PerformanceCommandError.profilerUnavailable("could not create profile output at \(output.path)")
        }
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = file
        process.standardError = file
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func captureOutput(executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private static func profileDurationSeconds() -> Int {
        let configured = ProcessInfo.processInfo.environment["PEARFY_PROFILE_DURATION_SECONDS"].flatMap(Int.init) ?? 5
        return min(300, max(1, configured))
    }
    #endif

    private static func executableOnPath(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH", default: ""]
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    #if os(macOS)
    private static func canFindXcodeTool(_ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcrun", "--find", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    #endif

    private static func architecture() -> String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

public enum PerformanceCommandError: Error, Sendable, CustomStringConvertible {
    case usage
    case missingProfileTarget(String)
    case profilerUnavailable(String)

    public var description: String {
        switch self {
        case .usage:
            "Usage: pearfy profile <cpu|memory> -- <program> [arguments...]"
        case .missingProfileTarget(let kind):
            "profile \(kind) requires a program after `--`"
        case .profilerUnavailable(let message): message
        }
    }
}
