import Dispatch
import Foundation

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Waits for an interrupt/termination signal so an application can perform
/// cooperative lifecycle shutdown before the process exits.
public enum PearfyProcessSignals {
    public static func waitForTermination() async {
        let waiter = SignalWaiter()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter.install(continuation)
        }
    }
}

private final class SignalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []
    private let signals: [Int32] = [SIGINT, SIGTERM]

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        self.continuation = continuation
        for signalNumber in signals {
            _ = signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [weak self] in self?.complete() }
            sources.append(source)
            source.resume()
        }
        lock.unlock()
    }

    private func complete() {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let sources = self.sources
        self.sources.removeAll()
        lock.unlock()

        for source in sources {
            source.cancel()
        }
        for signalNumber in signals {
            _ = signal(signalNumber, SIG_DFL)
        }
        continuation.resume()
    }
}
