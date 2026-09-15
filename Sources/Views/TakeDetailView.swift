import SwiftUI

/// Take history for one target.
///
/// Opens from the take count rather than sitting on screen — an always-visible history
/// table is one of the seven elements this design explicitly rejected.
struct TakeDetailView: View {
    @Environment(AppModel.self) private var model
    let target: TargetRef

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if takes.isEmpty {
                Text("No takes yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(takes) { take in
                            row(take)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 420, height: 320)
    }

    private var takes: [Take] {
        model.loaded?.takes(for: target) ?? []
    }

    private var best: Take? {
        model.loaded?.bestTake(for: target)
    }

    private var header: some View {
        HStack {
            Text("Take history")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text("\(takes.count) take\(takes.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func row(_ take: Take) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.playTake(take) }
            } label: {
                Image(systemName: "play.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // A take whose audio the user deleted is disabled and says so, rather than
            // throwing when tapped.
            .disabled(!hasAudio(take))
            .help(hasAudio(take) ? "Play this take" : "The recording is missing")

            VStack(alignment: .leading, spacing: 1) {
                Text(timeLabel(take))
                    .font(.system(size: 12))
                HStack(spacing: 5) {
                    Text(String(format: "%.1fs", take.durationSeconds))
                    if !hasAudio(take) {
                        Text("· recording missing")
                    }
                    if take.score == nil {
                        Text("· not scored")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if take.id == best?.id, take.score != nil {
                Text("best")
                    .font(.system(size: 9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            }

            if let score = take.score {
                switch score.verdict {
                case .hardToHear:
                    Image(systemName: "ear.trianglebadge.exclamationmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Hard to hear")
                case .unsupportedLength:
                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Too long to score in one piece")
                case .clear, .someWordsHardToHear:
                    Text(Styling.percent(score.accuracy))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Styling.accuracyColor(score.accuracy))
                        .frame(width: 26, alignment: .trailing)
                }
            }

            Menu {
                Button("Re-score") { Task { await model.rescore(take) } }
                    .disabled(!hasAudio(take))
                Button("Move to Trash", role: .destructive) {
                    Task { await model.deleteTake(take) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func hasAudio(_ take: Take) -> Bool {
        model.loaded?.hasAudio(take) ?? false
    }

    private func timeLabel(_ take: Take) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(take.recordedAt) {
            return "Today " + Styling.takeTimeFormatter.string(from: take.recordedAt)
        }
        return Styling.longDateFormatter.string(from: take.recordedAt)
            + " " + Styling.takeTimeFormatter.string(from: take.recordedAt)
    }
}
