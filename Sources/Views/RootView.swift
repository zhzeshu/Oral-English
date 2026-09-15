import SwiftUI

/// Item 01 places a launchable window here so the bundle and signing mechanics can be
/// verified against an empty app. Item 04 replaces the body with the real two-pane layout.
struct RootView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Oral English")
                .font(.system(size: 22, weight: .medium))
            Text("Paste a paragraph to begin.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
