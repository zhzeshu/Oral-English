import SwiftUI

/// The status line.
///
/// Exists **only** while audio is active. When nothing is happening there is nothing there —
/// which is the whole point of the subtractive rule for this item. The keyboard shortcuts
/// are deliberately not printed here; they live in the menu.
struct TransportBarView: View {
    let activity: AudioActivity
    let level: Double
    let elapsed: TimeInterval
    let noInputDetected: Bool
    var onStop: () -> Void

    var body: some View {
        if let label = activity.label {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isRecording ? .red : .secondary)
                Text(label)
                    .font(.system(size: 11))

                if isRecording {
                    meter
                    Text(timeString)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Spacer()
                }

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isRecording ? .red : .secondary)
                .accessibilityLabel("Stop")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .overlay(alignment: .top) { Divider() }

            if noInputDetected {
                // Acting on the meter rather than only drawing it. One hint covers a dead
                // microphone, a hardware-muted one, and a privacy grant that denies without
                // a dialog. A hint, never a dialog.
                Text("No input is being detected. Check the microphone and try again.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)
            }
        }
    }

    private var isRecording: Bool {
        if case .recording = activity { return true }
        return false
    }

    private var icon: String {
        switch activity {
        case .idle: return ""
        case .speaking: return "speaker.wave.2"
        case .recording: return "mic"
        case .playingTake: return "play"
        case .playingAB: return "arrow.left.arrow.right"
        }
    }

    private var timeString: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A live level meter, so it is obvious the microphone is picking something up.
    private var meter: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                let bars = max(Int(geo.size.width / 4), 1)
                ForEach(0..<bars, id: \.self) { i in
                    let threshold = Double(i) / Double(bars)
                    Capsule()
                        .fill(level > threshold ? Color.red : Color.secondary.opacity(0.25))
                        .frame(width: 2)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 18)
    }
}
