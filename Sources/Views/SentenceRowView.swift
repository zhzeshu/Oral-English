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
    let isSpeaking: Bool
    let spokenRange: (location: Int, length: Int)?
    let canPlay: Bool
    let isRecordingThis: Bool
    let canRecord: Bool
    let canPlayTake: Bool
    let canCompare: Bool

    var onSelect: () -> Void
    var onPlay: () -> Void
    var onRecord: () -> Void
    var onPlayTake: () -> Void
    var onCompare: () -> Void
    var onToggleExpand: () -> Void
    var onShowHistory: () -> Void

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
        .background(isActive ? Styling.activeRow : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 5) {
            blockFrame(
                Text(highlighted)
                    .font(.system(size: fontSize, weight: isHeading ? .semibold : .regular))
                    .lineSpacing(4)
            )
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

    private var isHeading: Bool { summary.block?.kind == .heading }

    private var fontSize: CGFloat {
        isHeading ? Styling.headingSize(summary.block?.level ?? 1) : 15
    }

    /// The markdown block around the text: a marker and indent for a list item, a rule
    /// down the left for a quote. Markers sit outside the text, never in it, because the
    /// text is what gets spoken and scored.
    @ViewBuilder
    private func blockFrame(_ content: some View) -> some View {
        switch summary.block?.kind {
        case .listItem:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(summary.block?.marker ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
                content
            }
            .padding(.leading, CGFloat(max((summary.block?.level ?? 1) - 1, 0)) * 22)
        case .quote:
            content
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Styling.rule).frame(width: 3)
                }
        default:
            content
        }
    }

    /// Blank until the target has been attempted, so a fresh passage shows no scoring
    /// furniture at all.
    @ViewBuilder
    private var accuracy: some View {
        if let a = summary.bestAccuracy, summary.verdict == .clear || summary.verdict == .someWordsHardToHear {
            Text(Styling.percent(a))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        } else if summary.verdict == .hardToHear {
            Image(systemName: "ear.trianglebadge.exclamationmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Hard to hear — try recording again")
                .frame(width: 24, alignment: .trailing)
        } else if summary.verdict == .unsupportedLength {
            Image(systemName: "text.badge.xmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("This passage is too long to score in one piece")
                .frame(width: 24, alignment: .trailing)
        } else {
            Color.clear.frame(width: 24, height: 1)
        }
    }

    /// The spoken word highlighted in place.
    ///
    /// Built from UTF-16 offsets through the pure converter, never by slicing a Character
    /// array — that drifts on any accented character or emoji. A voice that emits no ranges
    /// is a supported case: the whole sentence highlights instead of nothing.
    private var highlighted: AttributedString {
        var out = Styling.formatted(
            summary.text, styles: summary.styles,
            color: summary.takeCount > 0 || isActive ? .primary : .secondary
        )
        guard isSpeaking else { return out }
        guard let r = spokenRange,
              let swiftRange = SpokenRange.range(
                in: summary.text, utf16Location: r.location, utf16Length: r.length),
              let attributedRange = Range(swiftRange, in: out)
        else {
            out.backgroundColor = Styling.highlight.opacity(0.28)
            return out
        }
        out[attributedRange].backgroundColor = Styling.highlight.opacity(0.55)
        return out
    }

    private var transport: some View {
        HStack(spacing: 3) {
            Button(action: onPlay) {
                Image(systemName: isSpeaking ? "speaker.wave.2.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .disabled(!canPlay && !isSpeaking)
            // One button, two states: start a take, or stop the one running. It was a
            // plain glyph until now -- decoration where the app's whole purpose belonged.
            Button(action: onRecord) {
                Image(systemName: isRecordingThis ? "stop.fill" : "mic")
                    .foregroundStyle(isRecordingThis ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canRecord && !isRecordingThis)
            .help(isRecordingThis ? "Stop recording (⌘R)" : "Record yourself reading this (⌘R)")
            // Your own voice, one press away. `play.fill` above is the reference; this is
            // deliberately a different shape rather than a second play triangle, because
            // two identical glyphs side by side is how you press the wrong one.
            Button(action: onPlayTake) {
                Image(systemName: "person.wave.2.fill")
            }
            .buttonStyle(.plain)
            .disabled(!canPlayTake)
            .help(canPlayTake ? "Listen to your best take (⌘P)" : "Record yourself first")
            Button(action: onCompare) {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.plain)
            .disabled(!canCompare)
            .help("Hear the reference, then your best take (⌘B)")
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
                    // The history opens from the take count, which is the only affordance
                    // for it. An always-visible table was explicitly rejected.
                    Button("\(summary.takeCount) take\(summary.takeCount == 1 ? "" : "s")") {
                        onShowHistory()
                    }
                    .buttonStyle(.plain)
                    .underline()
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
