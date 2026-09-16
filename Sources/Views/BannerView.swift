import SwiftUI

/// One banner surface with an explicit precedence order, so a dismissed voice nag can
/// never hide a permission problem.
struct BannerView: View {
    let kind: BannerKind
    var onAction: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.tint)
            Spacer(minLength: 8)
            Button(actionTitle, action: onAction)
                .controlSize(.small)
            if kind.isDismissible {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.08))
    }

    private var icon: String {
        switch kind {
        case .micDenied: return "mic.slash"
        case .recognitionDenied, .offlineModelMissing: return "waveform.badge.exclamationmark"
        case .librarySynced: return "icloud"
        case .voiceQuality: return "speaker.wave.2"
        }
    }

    private var message: String {
        switch kind {
        case .micDenied:
            return AppFailure.micDenied.userMessage
        case .recognitionDenied:
            return AppFailure.recognitionDenied.userMessage
        case .offlineModelMissing:
            return AppFailure.offlineModelUnavailable(locale: "en-US").userMessage
        case .librarySynced:
            return "Your library is in an iCloud-synced folder, so recordings may be removed to save space."
        case .voiceQuality:
            return "Only basic voices are installed. Add Ava for natural American English."
        }
    }

    private var actionTitle: String {
        switch kind {
        case .micDenied, .recognitionDenied: return "Open settings"
        case .offlineModelMissing: return "Download model"
        case .librarySynced: return "Move library"
        case .voiceQuality: return "Open settings"
        }
    }
}
