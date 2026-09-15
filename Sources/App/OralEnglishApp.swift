import SwiftUI

@main
struct OralEnglishApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model.selectedTarget == nil || !model.practice.canPlayReference())
            }
        }
    }
}
