import SwiftUI

/// Title, an optional theme with autocomplete, and the pasted text, with a live split
/// preview.
///
/// The preview is the cheapest way to confirm the splitter did the right thing on real
/// input, and it is also what makes the single-newline paragraph rule visible before the
/// user commits.
///
/// With `isEditing` the same sheet revises the selected passage: it opens holding the
/// passage's title, theme and source text, and the preview line says what saving would
/// change, including how many recordings would stop appearing.
struct NewPassageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isEditing = false

    @State private var title = ""
    @State private var theme = ""
    @State private var text = ""
    @State private var preview: SentenceSplitter.Result?
    @State private var debounceTask: Task<Void, Never>?
    @State private var revision: (revision: PassageRevision, orphanedTakes: Int)?
    @State private var original = (title: "", theme: "", text: "")
    @State private var confirmingOrphans = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit passage" : "New passage")
                .font(.system(size: 17, weight: .medium))

            HStack(spacing: 10) {
                // An opening markdown heading is offered as the title, and used if the
                // field is left empty.
                TextField("Title", text: $title, prompt: Text(preview?.suggestedTitle ?? "Title"))
                TextField("Theme (optional)", text: $theme)
                    .frame(width: 170)
            }

            if !model.knownThemes.isEmpty {
                HStack(spacing: 6) {
                    Text("Recent:").font(.system(size: 10)).foregroundStyle(.tertiary)
                    ForEach(model.knownThemes.prefix(4), id: \.self) { t in
                        Button(t) { theme = t }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Drawn as a field explicitly. Left to AppKit, the editor is an unbordered
            // rectangle that does not read as somewhere to paste.
            TextEditor(text: $text)
                .font(.system(size: 13))
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 200)
                .background(Styling.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Styling.rule))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        // The editor's own padding plus the text view's 5pt line-fragment
                        // padding, so the placeholder sits where the first character will.
                        Text("Paste an English paragraph. Markdown is fine.")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 13)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: text) { _, newValue in
                    // Debounced, because a TextEditor bound to a multi-thousand-word string
                    // re-lays out on every keystroke.
                    debounceTask?.cancel()
                    debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        refreshPreview(newValue)
                    }
                }

            previewLine

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add passage") {
                    // Recompute rather than trust the debounced preview, which may be up to
                    // 300ms behind the last keystroke.
                    if isEditing, (model.revisionPreview(text: text)?.orphanedTakes ?? 0) > 0 {
                        confirmingOrphans = true
                    } else {
                        commit()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TextIntake.isEffectivelyEmpty(text) || (isEditing && !hasEdits))
            }
        }
        .alert("Some recordings will be hidden", isPresented: $confirmingOrphans) {
            Button("Save") { commit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(orphanWarning(model.revisionPreview(text: text)?.orphanedTakes ?? 0)
                + " The files stay in the passage folder.")
        }
        .padding(20)
        .frame(width: 620)
        // The text is the one required field, so the cursor starts there: ⌘N then ⌘V is
        // the whole gesture. A seed from "New Passage from Clipboard" arrives already
        // pasted, with its preview computed rather than waiting out the debounce.
        .onAppear {
            if isEditing, let p = model.loaded?.passage {
                title = p.title
                theme = p.theme ?? ""
                text = p.sourceText
                original = (title, theme, text)
                refreshPreview(text)
            } else if !model.composeSeed.isEmpty {
                text = model.composeSeed
                preview = SentenceSplitter.split(text)
                model.composeSeed = ""
            }
            editorFocused = true
        }
        // The same paper as the main window, so the white field stands out from it.
        .background(Styling.canvas)
    }

    private var resolvedTitle: String {
        title.isEmpty ? (SentenceSplitter.split(text).suggestedTitle ?? "Untitled") : title
    }

    private var hasEdits: Bool {
        title != original.title || theme != original.theme || TextIntake.clean(text) != TextIntake.clean(original.text)
    }

    private func refreshPreview(_ value: String) {
        preview = SentenceSplitter.split(value)
        if isEditing { revision = model.revisionPreview(text: value) }
    }

    private func commit() {
        Task {
            let theme = theme.isEmpty ? nil : theme
            if isEditing {
                await model.revise(title: resolvedTitle, theme: theme, text: text)
            } else {
                await model.createPassage(title: resolvedTitle, theme: theme, text: text)
            }
            dismiss()
        }
    }

    private func orphanWarning(_ count: Int) -> String {
        count == 1
            ? "1 recording belongs to a removed sentence or paragraph and will no longer appear."
            : "\(count) recordings belong to removed sentences or paragraphs and will no longer appear."
    }

    private static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }

    /// "2 sentences changed, 1 added, 1 removed", or nil when the text is unchanged.
    private func changeSummary(_ r: PassageRevision) -> String? {
        guard r.hasChanges else { return nil }
        var parts: [String] = []
        if !r.editedSentenceIDs.isEmpty { parts.append("\(Self.plural(r.editedSentenceIDs.count, "sentence")) changed") }
        if !r.addedSentenceIDs.isEmpty {
            parts.append(parts.isEmpty ? "\(Self.plural(r.addedSentenceIDs.count, "sentence")) added" : "\(r.addedSentenceIDs.count) added")
        }
        if !r.removedSentenceIDs.isEmpty {
            parts.append(parts.isEmpty ? "\(Self.plural(r.removedSentenceIDs.count, "sentence")) removed" : "\(r.removedSentenceIDs.count) removed")
        }
        // Only formatting or paragraph breaks moved.
        return parts.isEmpty ? "Formatting changed; every sentence keeps its recordings." : parts.joined(separator: ", ") + "."
    }

    @ViewBuilder
    private var previewLine: some View {
        if let p = preview, !p.sentences.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if isEditing, let r = revision {
                    if let summary = changeSummary(r.revision) {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if r.orphanedTakes > 0 {
                        Text(orphanWarning(r.orphanedTakes))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
                Text("Detected \(p.paragraphs.count) paragraph\(p.paragraphs.count == 1 ? "" : "s"), \(p.sentences.count) sentence\(p.sentences.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(p.sentences.prefix(3)) { s in
                    Text("· \(s.text)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                // A soft hint, never a block. Detection on short text is unreliable, and a
                // false block would be worse than the bug it prevents. Without it, non-
                // English text produces a confident zero score the honesty constraint
                // cannot catch, because recognizer confidence on the noise may be high.
                if !TextIntake.hasLatinLetters(text) {
                    Text("This does not look like English. The reference voice and scoring only support English.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
