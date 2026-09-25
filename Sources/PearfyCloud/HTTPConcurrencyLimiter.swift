import Foundation
import PearfyObservability

/// A cancellable, bounded admission gate for outbound HTTP work.
actor HTTPConcurrencyLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumConcurrent: Int
    private let maximumQueued: Int
    private let metrics: MetricsRegistry?
    private let metricLabels: MetricLabels?
    private var active = 0
    private var waiters: [Waiter] = []
    private var lastMetricUpdate: Task<Void, Never>?

    init(
        maximumConcurrent: Int,
        maximumQueued: Int,
        metrics: MetricsRegistry?,
        metricLabels: MetricLabels?
    ) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.maximumQueued = max(0, maximumQueued)
        self.metrics = metrics
        self.metricLabels = metricLabels
    }

    func acquire() async throws {
        if active < maximumConcurrent {
            active += 1
            enqueueMetric("pearfy_outbound_http_requests_in_flight", by: 1)
            return
        }
        guard waiters.count < maximumQueued else { throw CloudHTTPError.overloaded }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
                enqueueMetric("pearfy_outbound_http_queue_depth", by: 1)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() async {
        if waiters.isEmpty {
            active = max(0, active - 1)
            enqueueMetric("pearfy_outbound_http_requests_in_flight", by: -1)
        } else {
            let waiter = waiters.removeFirst()
            enqueueMetric("pearfy_outbound_http_queue_depth", by: -1)
            waiter.continuation.resume()
        }
    }

    func counts() async -> (active: Int, queued: Int) {
        await lastMetricUpdate?.value
        return (active, waiters.count)
    }

    private func cancelWaiter(_ id: UUID) async {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        enqueueMetric("pearfy_outbound_http_queue_depth", by: -1)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func enqueueMetric(_ name: String, by amount: Double) {
        guard let metrics, let metricLabels else { return }
        let previous = lastMetricUpdate
        lastMetricUpdate = Task.detached {
            await previous?.value
            try? await metrics.adjustGauge(name, by: amount, labels: metricLabels)
        }
    }
}
