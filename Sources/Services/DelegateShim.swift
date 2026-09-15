import Foundation

/// A one-shot bridge from a non-isolated Objective-C delegate callback to an `await`, with
/// a deadline.
///
/// Every audio and speech API in this app reports through a delegate or a completion
/// handler that is not actor-isolated. Three rules make that safe, and all three matter:
///
/// 1. **One shim per operation**, owned by the `@MainActor` service for that operation's
///    duration. No shared mutable state, so there is nothing to race.
/// 2. **Resume exactly once**, on the success path *and* on every error path. A double
///    resume is a hard crash; a missing resume hangs the UI forever.
/// 3. **Always with a deadline.** Revision 1 of the plan covered the error callback, which
///    only helps when a callback *arrives*. A callback that never arrives was unhandled —
///    and because every control binds to the audio activity, one unresumed continuation
///    disabled the whole app until a force quit, which then collided with the take-rescue
///    path and discarded the take. Four realistic never-fires paths exist: the input device
///    vanishing mid-take, machine sleep, a recognition asset stalling mid-download, and a
///    voice that emits no callbacks at all.
///
/// Never use `assumeIsolated` in these callbacks. It compiles, usually works, and fails
/// much later for reasons that are painful to find.
public final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false
    private var deadlineTask: Task<Void, Never>?

    private let operation: String
    private let timeout: Duration

    public init(operation: String, timeout: Duration) {
        self.operation = operation
        self.timeout = timeout
    }

    /// Waits for `complete` or `fail`, whichever comes first, or throws on the deadline.
    public func value() async throws -> Value {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if finished {
                lock.unlock()
                c.resume(throwing: CancellationError())
                return
            }
            continuation = c
            lock.unlock()

            let seconds = Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1e18
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(for: self?.timeout ?? .seconds(5))
                guard !Task.isCancelled else { return }
                self?.fail(AppFailure.timedOut(operation: self?.operation ?? "the operation",
                                               afterSeconds: seconds))
            }
        }
    }

    public func complete(_ value: Value) {
        resume { $0.resume(returning: value) }
    }

    public func fail(_ error: Error) {
        resume { $0.resume(throwing: error) }
    }

    private func resume(_ body: (CheckedContinuation<Value, Error>) -> Void) {
        lock.lock()
        guard !finished, let c = continuation else {
            finished = true
            continuation = nil
            lock.unlock()
            return
        }
        finished = true
        continuation = nil
        let task = deadlineTask
        deadlineTask = nil
        lock.unlock()

        task?.cancel()
        body(c)
    }
}

/// Deadlines, scaled to the work rather than fixed, so a legitimately slow whole-passage
/// recognition is not aborted while a wedged recorder still recovers quickly.
public enum Deadlines {
    /// After `stop()`. The AAC container is finalized in the delegate.
    public static let recorderFinish = Duration.seconds(5)
    /// Duration of the audio plus slack.
    public static func playerFinish(duration: Double) -> Duration {
        .seconds(max(duration + 2, 3))
    }
    /// Silence between word callbacks, not total speech length.
    public static let synthesisCallback = Duration.seconds(10)
    /// The greater of 15 seconds and twice the audio duration.
    public static func recognition(audioDuration: Double) -> Duration {
        .seconds(max(15, audioDuration * 2))
    }
    /// Quit must not hang, even with a wedged encoder.
    public static let terminationRescue = Duration.seconds(3)
}
