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
    private var settled: Result<Value, Error>?
    private var deadlineTask: Task<Void, Never>?

    private let operation: String
    private let timeout: Duration

    public init(operation: String, timeout: Duration) {
        self.operation = operation
        self.timeout = timeout
    }

    /// Waits for `complete` or `fail`, whichever comes first, or throws on the deadline.
    ///
    /// **The result is buffered.** A delegate can fire before this is ever awaited — and in
    /// practice it does: `recorder.stop()` is called synchronously, the finish callback
    /// arrives immediately, and only then does the caller `await`. An implementation that
    /// only resumes a waiting continuation drops that result on the floor. The symptom was
    /// every take being reported as not cleanly finalized while the audio was in fact
    /// perfect, which the record probe caught.
    public func value() async throws -> Value {
        // Already settled before anyone waited. `withLock` rather than manual
        // lock/unlock, because `NSLock.lock()` is unavailable from an async context — and
        // rightly so: holding a lock across a suspension is how you deadlock.
        if let early = takeSettled() {
            return try early.get()
        }

        return try await withCheckedThrowingContinuation { c in
            // Settled between the check above and here.
            let outcome: Result<Value, Error>? = lock.withLock {
                if let s = settled {
                    settled = nil
                    return s
                }
                continuation = c
                return nil
            }
            if let outcome {
                c.resume(with: outcome)
                return
            }

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
        deliver(.success(value))
    }

    public func fail(_ error: Error) {
        deliver(.failure(error))
    }

    private func takeSettled() -> Result<Value, Error>? {
        lock.withLock {
            let s = settled
            settled = nil
            return s
        }
    }

    /// Resumes exactly once, or buffers for a caller that has not awaited yet.
    private func deliver(_ result: Result<Value, Error>) {
        let waiting: (CheckedContinuation<Value, Error>, Task<Void, Never>?)? = lock.withLock {
            if let c = continuation {
                continuation = nil
                let task = deadlineTask
                deadlineTask = nil
                return (c, task)
            }
            // Nobody is waiting. Keep the first result only, so a later error cannot
            // overwrite a success that already happened.
            if settled == nil { settled = result }
            return nil
        }
        guard let (c, task) = waiting else { return }
        task?.cancel()
        c.resume(with: result)
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
