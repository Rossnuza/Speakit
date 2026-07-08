import SwiftUI
import AppKit
import AVFoundation

struct SettingsView: View {
    @ObservedObject var player: SpeechPlayer
    @ObservedObject var dictation: DictationService

    var body: some View {
        TabView {
            playbackTab
                .tabItem { Label("Playback", systemImage: "play.circle") }
            dictationTab
                .tabItem { Label("Voice Typing", systemImage: "mic") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 340)
    }

    // MARK: - Tabs

    private var playbackTab: some View {
        Form {
            Picker("Default speed", selection: $player.speedMultiplier) {
                ForEach(SpeechPlayer.speedSteps, id: \.self) { step in
                    Text(PlayerBar.speedLabel(step)).tag(step)
                }
            }

            LabeledContent("Voice") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(currentVoiceDescription)
                    Text("Pick a voice from the player bar's voice menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("More voices") {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Open Spoken Content Settings") {
                        openSpokenContentSettings()
                    }
                    Text("Download Enhanced and Premium voices in 60+ languages there; they appear in Speakit automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var dictationTab: some View {
        Form {
            Toggle("Remove filler words (um, uh, you know…)", isOn: .init(
                get: { dictation.removeFillerWords },
                set: { dictation.removeFillerWords = $0 }
            ))
            Toggle("Auto-capitalize and punctuate", isOn: .init(
                get: { dictation.autoPunctuate },
                set: { dictation.autoPunctuate = $0 }
            ))

            LabeledContent("Permissions") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Voice typing needs Microphone, Speech Recognition, and Accessibility access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Button("Open Privacy & Security Settings") {
                        openPrivacySettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var shortcutsTab: some View {
        Form {
            LabeledContent("Voice typing (any app)") { shortcutBadge("⌥Z") }
            LabeledContent("Read selected text (any app)") { shortcutBadge("⌥R") }
            Text("Press ⌥Z, speak naturally, then press ⌥Z again — the cleaned-up text is typed into whatever field has focus. Select text anywhere and press ⌥R to hear it read aloud; press ⌥R again to stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Helpers

    private var currentVoiceDescription: String {
        if let id = player.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
            return "\(voice.name) (\(language))"
        }
        return "System default"
    }

    private func shortcutBadge(_ keys: String) -> some View {
        Text(keys)
            .font(.callout.monospaced().bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func openSpokenContentSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
