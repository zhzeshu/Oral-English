import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewPassage = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(showingNewPassage: $showingNewPassage)
        } detail: {
            VStack(spacing: 0) {
                if let kind = model.banner {
                    BannerView(
                        kind: kind,
                        onAction: { bannerAction(kind) },
                        onDismiss: { dismissBannerIfAllowed(kind) }
                    )
                }
                PassageDetailView(showingNewPassage: $showingNewPassage)
            }
            .background(Styling.canvas)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        // Light, always. The app inherited the system appearance, and on a Mac set to dark
        // that made the page you read from near-black. Pinning it is a deliberate product
        // decision rather than an oversight: this is a reading surface, and it should look
        // like paper under every system setting.
        .preferredColorScheme(.light)
        .tint(Styling.accent)
        .sheet(isPresented: $showingNewPassage) { NewPassageSheet() }
        .task { await model.bootstrap() }
        // A second instance cannot share the library safely, so it says why and quits
        // rather than sitting there with a dead window. Two instances against one library
        // lose takes silently, and the atomic writes make that loss harder to notice.
        .alert("Already open", isPresented: .constant(model.isAnotherInstanceRunning)) {
            Button("Quit") { Workspace.terminate() }
        } message: {
            Text(AppFailure.alreadyRunning.userMessage)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil && !model.isAnotherInstanceRunning },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func bannerAction(_ kind: BannerKind) {
        switch kind {
        case .micDenied:
            Workspace.openPrivacySettings(.microphone)
        case .recognitionDenied:
            Workspace.openPrivacySettings(.speechRecognition)
        case .offlineModelMissing:
            // Not a permission problem, so not a Privacy pane. The model has to be
            // downloaded, and this is the only place the app offers to do it.
            Task { await model.installSpeechModel() }
        case .voiceQuality:
            Workspace.openPrivacySettings(.spokenContent)
        case .librarySynced:
            Task { await model.relocateLibraryOutOfSync() }
        }
    }

    private func dismissBannerIfAllowed(_ kind: BannerKind) {
        guard kind.isDismissible else { return }
        if kind == .voiceQuality { model.settings.voiceBannerDismissed = true }
        model.refreshBanner()
    }


}
