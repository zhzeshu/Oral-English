import SwiftUI

/// Title, an optional theme with autocomplete, and the pasted text, with a live split
/// preview.
///
/// The preview is the cheapest way to confirm the splitter did the right thing on real
/// input, and it is also what makes the single-newline paragraph rule visible before the
/// user commits.
struct NewPassageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var theme = ""
    @State private var text = ""
    @State private var preview: SentenceSplitter.Result?
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New passage")
                .font(.system(size: 17, weight: .medium))

            HStack(spacing: 10) {
                TextField("Title", text: $title)
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

            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 200)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste an English paragraph")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
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
                        preview = SentenceSplitter.split(newValue)
                    }
                }

            previewLine

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add passage") {
                    Task {
                        await model.createPassage(
                            title: title.isEmpty ? "Untitled" : title,
                            theme: theme.isEmpty ? nil : theme,
                            text: text
                        )
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TextIntake.isEffectivelyEmpty(text))
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    @ViewBuilder
    private var previewLine: some View {
        if let p = preview, !p.sentences.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
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
