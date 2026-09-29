import Foundation

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public struct DevKitProcessResourceSample: Sendable, Equatable {
    public let sampledAt: Date
    /// CPU utilization since the preceding one-second process sample. Values can exceed 100% on multicore workloads.
    public let cpuPercent: Double?
    /// Current resident memory, not the process high-water mark.
    public let residentMemoryBytes: UInt64?

    public init(sampledAt: Date, cpuPercent: Double?, residentMemoryBytes: UInt64?) {
        self.sampledAt = sampledAt
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
    }
}

/// Samples current process CPU and resident memory once per second while enabled.
public actor DevKitProcessResourceSampler {
    private var samplingTask: Task<Void, Never>?
    private var previousCPUSeconds: Double?
    private var previousWallTime: TimeInterval?
    private var latest: DevKitProcessResourceSample?

    public init() {}

    public func start() {
        guard samplingTask == nil else { return }
        sample()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.sample()
            }
        }
    }

    public func latestSample() -> DevKitProcessResourceSample? {
        latest
    }

    private func sample() {
        let wallTime = ProcessInfo.processInfo.systemUptime
        let cpuTime = Self.processCPUSeconds()
        let cpuPercent: Double?
        if let previousCPUSeconds, let previousWallTime, let cpuTime, wallTime > previousWallTime {
            let percent = (cpuTime - previousCPUSeconds) / (wallTime - previousWallTime) * 100
            cpuPercent = percent.isFinite ? max(0, percent) : nil
        } else {
            cpuPercent = nil
        }
        if let cpuTime {
            previousCPUSeconds = cpuTime
            previousWallTime = wallTime
        }
        latest = DevKitProcessResourceSample(
            sampledAt: Date(),
            cpuPercent: cpuPercent,
            residentMemoryBytes: Self.residentMemoryBytes()
        )
    }

    private static func processCPUSeconds() -> Double? {
        #if os(macOS) || os(Linux)
        var usage = rusage()
        guard getrusage(0, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
        #else
        return nil
        #endif
    }

    private static func residentMemoryBytes() -> UInt64? {
        #if os(macOS)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
        #elseif os(Linux)
        guard let contents = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let residentPages = contents.split(whereSeparator: \.isWhitespace).dropFirst().first.flatMap({ UInt64($0) }) else {
            return nil
        }
        let pageSize = sysconf(Int32(_SC_PAGESIZE))
        guard pageSize > 0 else { return nil }
        let (bytes, overflow) = residentPages.multipliedReportingOverflow(by: UInt64(pageSize))
        return overflow ? nil : bytes
        #else
        return nil
        #endif
    }
}
