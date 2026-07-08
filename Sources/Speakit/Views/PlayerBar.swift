import SwiftUI
import AVFoundation

/// Speechify-style playback bar: skip back / play-pause / skip forward,
/// a speed menu up to 4.5x, voice picker, progress, and audio export.
struct PlayerBar: View {
    @ObservedObject var player: SpeechPlayer

    var isExporting: Bool = false
    var onPlayPause: () -> Void
    var onExport: (() -> Void)?

    @State private var showVoicePicker = false

    var body: some View {
        HStack(spacing: 16) {
            // Transport
            HStack(spacing: 10) {
                Button(action: player.skipBackward) {
                    Image(systemName: "backward.fill")
                }
                .help("Previous sentence")

                Button(action: onPlayPause) {
                    Image(systemName: player.state == .speaking ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help(player.state == .speaking ? "Pause" : "Play")

                Button(action: player.skipForward) {
                    Image(systemName: "forward.fill")
                }
                .help("Next sentence")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)

            // Speed
            Menu {
                ForEach(SpeechPlayer.speedSteps, id: \.self) { step in
                    Button {
                        player.speedMultiplier = step
                    } label: {
                        if abs(player.speedMultiplier - step) < 0.01 {
                            Label(Self.speedLabel(step), systemImage: "checkmark")
                        } else {
                            Text(Self.speedLabel(step))
                        }
                    }
                }
            } label: {
                Text(Self.speedLabel(player.speedMultiplier))
                    .monospacedDigit()
                    .frame(minWidth: 44)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Playback speed")

            // Voice
            Button {
                showVoicePicker.toggle()
            } label: {
                Label(player.currentVoiceDisplayName,
                      systemImage: player.engineKind == .voicebox ? "sparkles" : "person.wave.2")
                    .lineLimit(1)
            }
            .popover(isPresented: $showVoicePicker, arrowEdge: .top) {
                VoicePickerView(player: player)
            }
            .help("Choose a voice")

            // Progress
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: player.progressFraction)
                    .progressViewStyle(.linear)
                Text(remainingLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)

            if let onExport {
                Button(action: onExport) {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .disabled(isExporting)
                .help("Export narration as an audio file for offline listening")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var remainingLabel: String {
        let seconds = player.estimatedSecondsRemaining
        guard seconds > 0 else { return "—" }
        let minutes = seconds / 60
        if minutes >= 60 {
            return String(format: "~%dh %02dm left", minutes / 60, minutes % 60)
        }
        if minutes > 0 {
            return "~\(minutes) min left"
        }
        return "~\(seconds)s left"
    }

    static func speedLabel(_ value: Double) -> String {
        // %g drops trailing zeros: 1 → "1×", 1.25 → "1.25×", 4.5 → "4.5×".
        String(format: "%g×", value)
    }
}
