import AppKit
import Foundation

/// Minimal application host for a probe that needs a privacy prompt.
///
/// A privacy dialog needs a UI context to appear in. A probe bundle launched with `open`
/// gets its own code identity — which is what makes the Speech framework's usage-string
/// check pass — but with no `NSApplication` there is nowhere for the prompt to be shown, so
/// the request returns false immediately and reads as a denial.
///
/// Registering as an accessory app gives it a real activation context without putting a
/// window on screen or a Dock icon in the way.
@MainActor
public enum ProbeApp {

    /// Runs async work inside a real application, then exits.
    public static func run(_ work: @escaping @Sendable @MainActor () async -> Void) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Delegate(work: work)
        app.delegate = delegate
        app.run()
        exit(0)
    }

    private final class Delegate: NSObject, NSApplicationDelegate {
        let work: @Sendable @MainActor () async -> Void

        init(work: @escaping @Sendable @MainActor () async -> Void) {
            self.work = work
            super.init()
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                await work()
                // Flush before the process disappears, or captured output is truncated.
                fflush(stdout)
                fflush(stderr)
                NSApp.terminate(nil)
            }
        }
    }
}
