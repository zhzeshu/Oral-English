import AppKit

/// The few AppKit calls the app model needs, kept behind a seam so `AppModel` does not
/// import AppKit directly.
public enum Workspace {
    @MainActor
    public static func terminate() {
        NSApplication.shared.terminate(nil)
    }

    /// Plain text on the clipboard, or nil when there is none worth starting a passage from.
    @MainActor
    public static func clipboardText() -> String? {
        guard let s = NSPasteboard.general.string(forType: .string),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    public static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func openPrivacySettings(_ pane: PrivacyPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    public enum PrivacyPane {
        case microphone
        case speechRecognition
        case spokenContent

        var urlString: String {
            switch self {
            case .microphone:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .speechRecognition:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            case .spokenContent:
                return "x-apple.systempreferences:com.apple.preference.universalaccess?SpeechSection"
            }
        }
    }
}
