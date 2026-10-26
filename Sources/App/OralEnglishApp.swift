import AppKit
import SwiftUI

/// Application lifecycle, which SwiftUI alone does not give this app correctly.
///
/// A `WindowGroup` app keeps running after its last window closes. That is right for a
/// document app -- Pages with no document open is still Pages -- and wrong for this one,
/// which has exactly one window and one library. Closing it left a running process with no
/// window and a Dock icon that looked like a dead app, which is what "open and close is
/// pretty strange" describes.
///
/// Two behaviours restore what every other single-window Mac app does: closing the window
/// quits, and clicking the Dock icon of a running instance brings a window back.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {

    /// Registered by the app once the model exists, so termination can release the library
    /// lock explicitly rather than relying on the file descriptor dying with the process.
    static var willTerminate: (@MainActor () -> Void)?

    /// Light, for every window -- not just the main one. `preferredColorScheme` on the root
    /// view pins the main window, but a sheet is a window of its own, and AppKit-backed
    /// controls inside it draw with the window's appearance rather than SwiftUI's color
    /// scheme. On a Mac set to dark, that left the paste sheet's `TextEditor` (an
    /// `NSTextView` underneath) drawn dark inside an otherwise light sheet. Pinning the
    /// application appearance covers sheets, popovers and alerts in one place.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Belt and braces for the case this app can still reach: running with no window, where
    /// clicking the Dock icon must produce one rather than just bouncing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.willTerminate?()
    }
}

@main
struct OralEnglishApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // `AppModel.shutdown` releases the single-instance lock and had no caller
                // at all, so it was dead code guarding the one thing it exists to guard.
                .task { AppLifecycle.willTerminate = { model.shutdown() } }
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            // File > New, where every Mac user looks first. The window itself is not
            // a document, so "New" makes a passage rather than another window.
            CommandGroup(replacing: .newItem) {
                Button("New Passage…") { model.composePassage() }
                    .keyboardShortcut("n", modifiers: .command)
                // The usual way in: copy a paragraph from anywhere, then one keystroke.
                Button("New Passage from Clipboard") {
                    model.composePassage(seed: Workspace.clipboardText() ?? "")
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            // A menu item rather than a hidden shortcut on a view: the empty state has
            // advertised "⌘R — record" since the first screen was built, and until now it
            // was bound to nothing at all.
            CommandMenu("Practice") {
                Button(model.practice.recordingTarget == nil ? "Record" : "Stop Recording") {
                    guard let ref = model.practice.recordingTarget ?? model.selectedTarget else { return }
                    Task { await model.toggleRecording(ref) }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selectedTarget == nil && model.practice.recordingTarget == nil)

                Button("Play Reference") {
                    guard let ref = model.selectedTarget else { return }
                    Task { await model.playReference(ref) }
                }
                // L for listen. ⌘P went to playing your own take, which is what the
                // in-app menu has advertised since the screen was built. Space would be
                // the natural key and is deliberately avoided: it would swallow spaces in
                // the paste sheet's text field.
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.selectedTarget == nil || !model.practice.canPlayReference())

                Button("Play My Take") {
                    guard let ref = model.selectedTarget else { return }
                    Task { await model.playBestTake(ref) }
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model.selectedTarget.map { !model.canPlayTake($0) } ?? true)

                Button("Compare") {
                    guard let ref = model.selectedTarget else { return }
                    Task { await model.compareBest(ref) }
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(model.selectedTarget.map { !model.canCompare($0) } ?? true)

                Divider()

                Button("Next Sentence") { model.selectNextTarget() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
        }
    }
}
