import Foundation
import PearfyObservability
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CloudHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol CloudHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> CloudHTTPResponse
}

private struct URLSessionHTTPTransport: CloudHTTPTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudHTTPError.invalidResponse }
        let headers = response.allHeaderFields.reduce(into: [:]) { values, item in
            values[String(describing: item.key)] = String(describing: item.value)
        }
        return CloudHTTPResponse(statusCode: response.statusCode, headers: headers, body: body)
    }
}

public struct HTTPRetryPolicy: Sendable, Equatable {
    /// Includes the initial request.
    public let maximumAttempts: Int
    public let initialBackoffMilliseconds: Int64
    public let maximumBackoffMilliseconds: Int64

    public init(maximumAttempts: Int = 3, initialBackoffMilliseconds: Int64 = 100, maximumBackoffMilliseconds: Int64 = 2_000) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialBackoffMilliseconds = max(0, initialBackoffMilliseconds)
        self.maximumBackoffMilliseconds = max(self.initialBackoffMilliseconds, maximumBackoffMilliseconds)
    }

    fileprivate func delay(after attempt: Int) -> Duration {
        let multiplier = Int64(1) << min(max(0, attempt - 1), 20)
        guard initialBackoffMilliseconds > 0 else { return .zero }
        let boundedInitial = min(initialBackoffMilliseconds, maximumBackoffMilliseconds)
        let delay = boundedInitial > maximumBackoffMilliseconds / multiplier
            ? maximumBackoffMilliseconds
            : boundedInitial * multiplier
        return .milliseconds(delay)
    }
}

public enum CloudHTTPError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidResponse
    case circuitOpen
    case overloaded

    public var description: String {
        switch self {
        case .invalidResponse: "PEARFY_CLOUD_001: server returned a non-HTTP response"
        case .circuitOpen: "PEARFY_CLOUD_002: outbound HTTP circuit breaker is open"
        case .overloaded: "PEARFY_CLOUD_003: outbound HTTP admission queue is full"
        }
    }
}

/// Circuit breaker shared by outbound clients. One probe is allowed after the
/// reset timeout; the breaker closes only when that probe succeeds.
public actor CircuitBreaker {
    private enum State {
        case closed
        case open(until: ContinuousClock.Instant)
        case halfOpen(probeInFlight: Bool)
    }

    private let failureThreshold: Int
    private let resetAfter: Duration
    private let clock = ContinuousClock()
    private var state: State = .closed
    private var consecutiveFailures = 0

    public init(failureThreshold: Int = 5, resetAfter: Duration = .seconds(10)) {
        self.failureThreshold = max(1, failureThreshold)
        self.resetAfter = max(.zero, resetAfter)
    }

    public func acquire() throws {
        switch state {
        case .closed:
            return
        case .open(let until):
            guard clock.now >= until else { throw CloudHTTPError.circuitOpen }
            state = .halfOpen(probeInFlight: true)
        case .halfOpen(let probeInFlight):
            guard !probeInFlight else { throw CloudHTTPError.circuitOpen }
            state = .halfOpen(probeInFlight: true)
        }
    }

    public func record(success: Bool) {
        switch state {
        case .halfOpen:
            if success {
                state = .closed
                consecutiveFailures = 0
            } else {
                open()
            }
        case .closed:
            if success {
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= failureThreshold { open() }
            }
        case .open:
            break
        }
    }

    private func open() {
        state = .open(until: clock.now.advanced(by: resetAfter))
        consecutiveFailures = failureThreshold
    }
}

/// URLSession-based outbound client. Retries are limited to idempotent HTTP
/// methods and transient 429/5xx responses; credentials remain caller-provided.
public final class CloudHTTPClient: CloudHTTPTransport, Sendable {
    private let transport: any CloudHTTPTransport
    private let retryPolicy: HTTPRetryPolicy
    private let circuitBreaker: CircuitBreaker
    private let limiter: HTTPConcurrencyLimiter

    public init(
        session: URLSession = .shared,
        transport: (any CloudHTTPTransport)? = nil,
        retryPolicy: HTTPRetryPolicy = HTTPRetryPolicy(),
        circuitBreaker: CircuitBreaker = CircuitBreaker(),
        maximumConcurrentRequests: Int = 64,
        maximumQueuedRequests: Int = 256,
        metrics: MetricsRegistry? = nil
    ) {
        self.transport = transport ?? URLSessionHTTPTransport(session: session)
        self.retryPolicy = retryPolicy
        self.circuitBreaker = circuitBreaker
        limiter = HTTPConcurrencyLimiter(
            maximumConcurrent: maximumConcurrentRequests,
            maximumQueued: maximumQueuedRequests,
            metrics: metrics,
            metricLabels: try? MetricLabels(["client": "default"])
        )
    }

    public func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
        try await limiter.acquire()
        do {
            try Task.checkCancellation()
            let response = try await sendAdmitted(request)
            await limiter.release()
            return response
        } catch {
            await limiter.release()
            throw error
        }
    }

    public func requestCounts() async -> (active: Int, queued: Int) {
        await limiter.counts()
    }

    private func sendAdmitted(_ request: URLRequest) async throws -> CloudHTTPResponse {
        try await circuitBreaker.acquire()
        let retryableMethod = Self.idempotentMethods.contains((request.httpMethod ?? "GET").uppercased())

        for attempt in 1...retryPolicy.maximumAttempts {
            do {
                let result = try await transport.send(request)
                let transientFailure = result.statusCode == 429 || (500...599).contains(result.statusCode)
                if retryableMethod, transientFailure, attempt < retryPolicy.maximumAttempts {
                    try await Task.sleep(for: retryPolicy.delay(after: attempt))
                    continue
                }
                await circuitBreaker.record(success: !transientFailure)
                return result
            } catch {
                if error is CancellationError || Task.isCancelled {
                    await circuitBreaker.record(success: false)
                    throw error
                }
                guard retryableMethod, attempt < retryPolicy.maximumAttempts else {
                    await circuitBreaker.record(success: false)
                    throw error
                }
                do {
                    try await Task.sleep(for: retryPolicy.delay(after: attempt))
                } catch {
                    await circuitBreaker.record(success: false)
                    throw error
                }
            }
        }
        await circuitBreaker.record(success: false)
        throw CloudHTTPError.invalidResponse
    }

    private static let idempotentMethods: Set<String> = ["GET", "HEAD", "PUT", "DELETE", "OPTIONS"]
}
