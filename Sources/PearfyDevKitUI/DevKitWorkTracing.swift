import Foundation

public enum DevKitWorkStatus: String, Codable, Sendable {
    case ok
    case error
}

/// Bounded in-process traces for completed background work.
public actor DevKitWorkTraceRecorder {
    public static let capacity = 512

    private let maximumTraces: Int
    private var traces: [DevKitTrace] = []

    public init(capacity: Int = 512) {
        maximumTraces = max(1, capacity)
    }

    /// Records only the registered work name, timing and outcome; error details and payloads are excluded.
    public func record(
        name: String,
        startedAt: Date,
        durationMilliseconds: Double,
        status: DevKitWorkStatus
    ) {
        guard Self.isSafeName(name),
              startedAt.timeIntervalSince1970.isFinite,
              durationMilliseconds.isFinite,
              durationMilliseconds >= 0 else { return }

        let spanID = Self.randomHex(byteCount: 8)
        let span = DevKitSpan(
            spanID: spanID,
            name: "work \(name)",
            startedAt: startedAt,
            durationMilliseconds: durationMilliseconds,
            status: status.rawValue
        )
        traces.append(DevKitTrace(
            traceID: Self.randomHex(byteCount: 16),
            kind: .work,
            startedAt: startedAt,
            durationMilliseconds: durationMilliseconds,
            status: status.rawValue,
            spans: [span]
        ))
        if traces.count > maximumTraces {
            traces.removeFirst(traces.count - maximumTraces)
        }
    }

    func snapshot(window: DevKitWindow, now: Date = Date()) -> [DevKitTrace] {
        let seconds: TimeInterval
        switch window {
        case .fifteenMinutes: seconds = 15 * 60
        case .oneHour: seconds = 60 * 60
        case .twentyFourHours: seconds = 24 * 60 * 60
        }
        let cutoff = now.addingTimeInterval(-seconds)
        return traces
            .filter { $0.startedAt >= cutoff && $0.startedAt <= now }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func randomHex(byteCount: Int) -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            .prefix(byteCount * 2)
            .description
    }
}
