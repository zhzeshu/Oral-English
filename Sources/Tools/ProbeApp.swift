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

// MARK: - On-screen prompt
//
// A probe launched with `open` has no live stdout: probe.sh captures it to a file and prints
// it after the process exits. That is fine for a report, and useless for a prompt -- you
// cannot read a sentence aloud that you will not see until after the recording has ended.
// Spoken prompts cover the timing ("read it now") but not the text: hearing a sentence once
// is not enough to read it back accurately, and re-reading from memory measures memory.
//
// So the host puts the sentence on screen, in a floating window, for as long as it is
// needed. Deliberately not a real UI -- one label for the line to read, one for what the
// probe is doing.
extension ProbeApp {

    private static var panel: NSWindow?
    private static var sentenceLabel: NSTextField?
    private static var statusLabel: NSTextField?

    /// Shows or updates the prompt window. `sentence` is what to read; `status` is what the
    /// probe is doing. Passing nil leaves that line unchanged.
    public static func prompt(sentence: String? = nil, status: String? = nil) {
        if panel == nil { buildPanel() }
        if let sentence { sentenceLabel?.stringValue = sentence }
        if let status { statusLabel?.stringValue = status }
        // Force a redraw now rather than at the next run-loop pass. The probe spends most of
        // its time awaiting audio, so an un-drawn update would sit invisible for seconds.
        panel?.contentView?.display()
    }

    /// Closes the prompt window. Safe to call when it was never shown.
    public static func dismissPrompt() {
        panel?.orderOut(nil)
        panel = nil
        sentenceLabel = nil
        statusLabel = nil
    }

    private static func buildPanel() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 200),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Oral English Probe"
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.center()

        let sentence = NSTextField(wrappingLabelWithString: "")
        sentence.font = .systemFont(ofSize: 24, weight: .regular)
        sentence.alignment = .center
        sentence.isSelectable = false

        let status = NSTextField(labelWithString: "")
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.alignment = .center

        let stack = NSStackView(views: [sentence, status])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: window.contentLayoutRect)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
        window.orderFrontRegardless()

        panel = window
        sentenceLabel = sentence
        statusLabel = status
    }
}
