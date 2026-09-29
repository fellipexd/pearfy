import Foundation
import PearfyWeb

actor DevKitRequestTraceStore {
    static let capacity = 512

    private struct TraceParent {
        let traceID: String
        let spanID: String
        let flags: String
    }

    private var records: [DevKitTrace] = []

    func middleware() -> HTTPMiddleware {
        { request, next in
            let routeTemplate = request.contextValue(HTTPRequest.routeTemplateContextKey)
            let isDevKitRequest = routeTemplate?.hasPrefix(PearfyDevKitUI.routePrefix) == true
                || request.path == PearfyDevKitUI.routePrefix
                || request.path.hasPrefix("\(PearfyDevKitUI.routePrefix)/")
            guard !isDevKitRequest else {
                return await next(request)
            }

            let method = Self.safeMethod(request.method.description)
            let parent = Self.traceParent(request.headers["traceparent"])
            let traceID = parent?.traceID ?? Self.randomHex(byteCount: 16)
            let spanID = Self.randomHex(byteCount: 8)
            let flags = parent?.flags ?? "01"
            let traceparent = "00-\(traceID)-\(spanID)-\(flags)"
            let startedAt = Date()
            let clock = ContinuousClock()
            let start = clock.now
            let tracedRequest = request
                .addingContextValue(HTTPRequest.traceIDContextKey, value: traceID)
                .addingContextValue(HTTPRequest.spanIDContextKey, value: spanID)
            let response = await next(tracedRequest)
            let duration = start.duration(to: clock.now).components
            let durationMilliseconds = max(
                0,
                Double(duration.seconds) * 1_000
                    + Double(duration.attoseconds) / 1_000_000_000_000_000
            )
            let status = response.status >= 500 ? "error" : response.status >= 400 ? "client-error" : "ok"
            let span = DevKitSpan(
                spanID: spanID,
                parentSpanID: parent?.spanID,
                name: "HTTP \(method) \(routeTemplate ?? "unmatched")",
                startedAt: startedAt,
                durationMilliseconds: durationMilliseconds,
                status: status
            )
            let trace = DevKitTrace(
                traceID: traceID,
                kind: .request,
                routeTemplate: routeTemplate,
                method: method,
                startedAt: startedAt,
                durationMilliseconds: durationMilliseconds,
                status: status,
                spans: [span],
                statusCode: (100...599).contains(response.status) ? response.status : nil
            )
            await self.append(trace)
            var headers = response.headers
            headers["traceparent"] = traceparent
            headers["x-trace-id"] = traceID
            return HTTPResponse(status: response.status, headers: headers, body: response.body)
        }
    }

    func traces(in window: DevKitWindow) -> [DevKitTrace] {
        let cutoff = Date().addingTimeInterval(-window.intervalSeconds)
        return records
            .filter { $0.startedAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func append(_ trace: DevKitTrace) {
        if records.count == Self.capacity { records.removeFirst() }
        records.append(trace)
    }

    private static func safeMethod(_ value: String) -> String {
        guard value.utf8.count <= 32,
              value.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return "OTHER" }
        return value.uppercased()
    }

    private static func traceParent(_ raw: String?) -> TraceParent? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "00",
              parts[1].count == 32,
              parts[2].count == 16,
              parts[3].count == 2,
              parts.dropFirst().allSatisfy({ $0.utf8.allSatisfy(isHex) }) else { return nil }
        let traceID = String(parts[1]).lowercased()
        let spanID = String(parts[2]).lowercased()
        guard traceID.contains(where: { $0 != "0" }), spanID.contains(where: { $0 != "0" }) else { return nil }
        return TraceParent(traceID: traceID, spanID: spanID, flags: String(parts[3]).lowercased())
    }

    private static func randomHex(byteCount: Int) -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(byteCount * 2).description
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}

extension DevKitWindow {
    fileprivate var intervalSeconds: TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .twentyFourHours: 24 * 60 * 60
        }
    }
}
