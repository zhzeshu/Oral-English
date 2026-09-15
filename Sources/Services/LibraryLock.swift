import Foundation

/// A single-instance guard over the library.
///
/// `build.sh` leaves a launchable copy in `build/` and installs another to
/// `~/Applications`, both with the same bundle identifier, so two instances against one
/// library is an easy accident. An actor serializes writes within one process and does
/// nothing across two, and the atomic-write discipline makes the resulting loss *harder*
/// to notice: each write is individually clean, so there is no corruption to detect.
///
/// Uses `flock`, which the kernel releases when the process dies. A PID file would strand
/// after a crash and block the next launch.
///
/// Lives in `Services/` rather than `Core/` because it needs `Darwin`, and because there is
/// nothing here worth unit-testing — the behavior under contention is a kernel property.
public final class LibraryLock {
    private var descriptor: Int32 = -1
    private let url: URL

    public init(libraryRoot: URL) {
        self.url = libraryRoot.appendingPathComponent(".lock", isDirectory: false)
    }

    /// True when this process now holds the lock.
    public func tryAcquire() -> Bool {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return false }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            descriptor = -1
            return false
        }
        return true
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
