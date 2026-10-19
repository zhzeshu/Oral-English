import SwiftUI

/// The passage, reading top to bottom as a single column. No borders between rows, no
/// paragraph labels, separated by whitespace alone.
struct PassageDetailView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingNewPassage: Bool
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var historyTarget: TargetRef?

    var body: some View {
        if let loaded = model.loaded {
            content(loaded)
        } else if model.summaries.isEmpty {
            // An empty library opens straight into the paste box, because that is the first
            // thing to do. An invitation, not an apology.
            ContentUnavailableView {
                Text("Start your first passage")
            } description: {
                Text("Paste an English paragraph and it will be split into sentences.")
            } actions: {
                Button("Paste a paragraph") { showingNewPassage = true }
            }
        } else {
            ContentUnavailableView {
                Text("Nothing selected")
            } description: {
                Text("Choose a passage on the left.")
            }
        }
    }

    private func content(_ loaded: LoadedPassage) -> some View {
        VStack(spacing: 0) {
            header(loaded)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.visibleTargets.enumerated()), id: \.element) { i, ref in
                        if let summary = model.rowSummaries[ref] {
                            SentenceRowView(
                                index: i,
                                summary: summary,
                                isActive: model.selectedTarget == ref,
                                isExpanded: model.expandedTarget == ref,
                                nestedSentences: nested(for: ref, in: loaded),
                                isSpeaking: model.practice.speakingTarget == ref,
                                spokenRange: model.spokenRange(for: ref),
                                canPlay: model.practice.canPlayReference(),
                                isRecordingThis: model.isRecording(ref),
                                canRecord: model.practice.recordingTarget == nil
                                    && model.practice.audio.isIdle,
                                canCompare: model.canCompare(ref),
                                onSelect: { model.selectedTarget = ref },
                                onPlay: { Task { await model.playReference(ref) } },
                                onRecord: { Task { await model.toggleRecording(ref) } },
                                onCompare: { Task { await model.compareBest(ref) } },
                                onToggleExpand: {
                                    model.expandedTarget = model.expandedTarget == ref ? nil : ref
                                },
                                onShowHistory: { historyTarget = ref }
                            )
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            // Transient: renders nothing at all when audio is idle.
            TransportBarView(
                activity: model.practice.audio,
                level: model.recorderLevel,
                elapsed: model.recorderElapsed,
                noInputDetected: model.recorderNoInput,
                // Through the model, not straight to the controller: stopping a take has
                // to finalize the file and adopt it, or the recording is stranded.
                onStop: { Task { await model.stopAudio() } }
            )
        }
        .popover(item: $historyTarget) { ref in
            TakeDetailView(target: ref)
        }
        .alert("Rename passage", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") { Task { await model.rename(to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Paragraph and whole rows show their sentences dimmed inside. Same component.
    private func nested(for ref: TargetRef, in loaded: LoadedPassage) -> [String] {
        switch ref.kind {
        case .sentence:
            return []
        case .paragraph:
            guard let p = loaded.passage.paragraph(id: ref.id) else { return [] }
            return p.sentenceIDs.compactMap { loaded.passage.sentence(id: $0)?.text }
        case .passage:
            return []
        }
    }

    private func header(_ loaded: LoadedPassage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loaded.passage.title)
                        .font(.system(size: 20, weight: .medium))
                    Text(metaLine(loaded))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                menu(loaded)
            }
            // The segmented control is the only affordance for the three granularities.
            Picker("", selection: Binding(
                get: { model.granularity },
                set: { model.granularity = $0 }
            )) {
                Text("Sentence").tag(Granularity.sentence)
                Text("Paragraph").tag(Granularity.paragraph)
                Text("Whole").tag(Granularity.passage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// One muted line. Everything that was a row of status chips now lives in the menu.
    private func metaLine(_ loaded: LoadedPassage) -> String {
        var parts: [String] = []
        if let theme = loaded.passage.theme { parts.append(theme) }
        parts.append(Styling.longDateFormatter.string(from: loaded.passage.createdAt))
        if let voice = model.activeVoiceName { parts.append(voice) }
        return parts.joined(separator: " · ")
    }

    private func menu(_ loaded: LoadedPassage) -> some View {
        Menu {
            Button("Rename…") {
                newTitle = loaded.passage.title
                renaming = true
            }
            Menu("Voice") {
                ForEach(model.voiceCatalog.grouped, id: \.tier) { group in
                    Section(group.tier.label) {
                        ForEach(group.voices) { v in
                            Button(v.name) { model.selectVoice(v) }
                        }
                    }
                }
            }
            Button("Reveal in Finder") { model.revealInFinder() }
            Divider()
            Section("Keyboard") {
                Text("Space — play reference")
                Text("⌘R — record")
                Text("⌘P — play my take")
                Text("⌘B — compare")
                Text("⌘↓ — next")
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                Task { await model.deleteSelectedPassage() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
