import SwiftUI

/// One practice target.
///
/// Three zones: accuracy at the right margin as a small muted number, blank until the
/// target has been attempted; the text in the middle; and the transport, which appears only
/// on the row being worked on.
///
/// Takes only small equatable inputs, never the whole passage, so mutating one take does not
/// re-body every row.
struct SentenceRowView: View {
    let index: Int
    let summary: AppModel.RowSummary
    let isActive: Bool
    let isExpanded: Bool
    let nestedSentences: [String]

    var onSelect: () -> Void
    var onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                text
                Spacer(minLength: 8)
                if isActive {
                    transport
                } else {
                    accuracy
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 11)

            if isExpanded { detail }
        }
        .background(isActive ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(summary.text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(summary.takeCount > 0 || isActive ? .primary : .secondary)
            // Paragraph and whole rows show their sentences dimmed inside, which is the
            // only difference between the three granularities.
            if !nestedSentences.isEmpty {
                ForEach(Array(nestedSentences.enumerated()), id: \.offset) { _, s in
                    Text(s)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Blank until the target has been attempted, so a fresh passage shows no scoring
    /// furniture at all.
    @ViewBuilder
    private var accuracy: some View {
        if let a = summary.bestAccuracy, summary.verdict != .hardToHear {
            Text(Styling.percent(a))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        } else if summary.verdict == .hardToHear {
            Image(systemName: "ear.trianglebadge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        } else {
            Color.clear.frame(width: 24, height: 1)
        }
    }

    /// Placeholders until items 07 through 09 wire the audio. Disabled rather than absent,
    /// so the layout does not shift when they start working.
    private var transport: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
            Image(systemName: "mic")
            Image(systemName: "arrow.left.arrow.right")
            if summary.takeCount > 0 {
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
    }

    /// One plain-language line naming what was heard, one muted line with the percentage
    /// and take count. Take history opens from the take count, not from here.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heard = summary.heardText, !heard.isEmpty {
                Text("You said: \(heard)")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            HStack(spacing: 6) {
                if let a = summary.bestAccuracy {
                    Text("\(Styling.percent(a)) percent")
                    Text("·")
                    Text(Styling.accuracyBand(a))
                }
                if summary.takeCount > 0 {
                    Text("·")
                    Text("\(summary.takeCount) take\(summary.takeCount == 1 ? "" : "s")")
                }
                if summary.hasMissingAudio {
                    Text("·")
                    Text("a recording is missing")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)

            if !summary.problemWords.isEmpty {
                Text("Words to work on: \(summary.problemWords.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 13)
    }
}
