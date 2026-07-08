import SwiftUI
import AppKit

/// Menu-bar dropdown: quick playback controls, speed, voice typing, and
/// quick-listen for clipboard text — Speakit stays useful while the main
/// window is closed.
struct MiniPlayerView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var player: SpeechPlayer
    @ObservedObject var dictation: DictationService

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if player.hasContent {
                VStack(alignment: .leading, spacing: 6) {
                    Text(player.currentTitle.isEmpty ? "Now Playing" : player.currentTitle)
                        .font(.headline)
                        .lineLimit(1)
                    ProgressView(value: player.progressFraction)
                        .progressViewStyle(.linear)
                }

                HStack(spacing: 14) {
                    Button(action: player.skipBackward) {
                        Image(systemName: "backward.fill")
                    }
                    Button(action: player.togglePlayPause) {
                        Image(systemName: player.state == .speaking ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 26))
                    }
                    Button(action: player.skipForward) {
                        Image(systemName: "forward.fill")
                    }

                    Spacer()

                    Menu(PlayerBar.speedLabel(player.speedMultiplier)) {
                        ForEach(SpeechPlayer.speedSteps, id: \.self) { step in
                            Button(PlayerBar.speedLabel(step)) {
                                player.speedMultiplier = step
                            }
                        }
                    }
                    .fixedSize()

                    Button(action: player.stop) {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop")
                }
                .buttonStyle(.borderless)

                Divider()
            }

            Button {
                appState.toggleDictation()
            } label: {
                Label(dictation.isRecording ? "Stop Voice Typing" : "Start Voice Typing  (⌥Z)",
                      systemImage: dictation.isRecording ? "mic.fill" : "mic")
            }

            Button {
                readClipboard()
            } label: {
                Label("Listen to Clipboard", systemImage: "doc.on.clipboard")
            }

            Divider()

            Button("Open Speakit") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            Button("Quit Speakit") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 280)
    }

    private func readClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        player.load(text: text, title: "Clipboard", documentID: nil)
        player.play()
    }
}
