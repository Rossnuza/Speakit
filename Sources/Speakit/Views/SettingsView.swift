import SwiftUI
import AppKit
import AVFoundation

struct SettingsView: View {
    @ObservedObject var player: SpeechPlayer
    @ObservedObject var dictation: DictationService

    @AppStorage("voiceboxBaseURL") private var voiceboxBaseURL = VoiceboxClient.defaultBaseURLString
    @State private var voiceboxStatus: String?
    @State private var isTestingVoicebox = false

    var body: some View {
        TabView {
            playbackTab
                .tabItem { Label("Playback", systemImage: "play.circle") }
            aiVoicesTab
                .tabItem { Label("AI Voices", systemImage: "sparkles") }
            dictationTab
                .tabItem { Label("Voice Typing", systemImage: "mic") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 500, height: 380)
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

    private var aiVoicesTab: some View {
        Form {
            LabeledContent("Engine") {
                Picker("", selection: $player.engineKind) {
                    ForEach(TTSEngineKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            TextField("Voicebox server", text: $voiceboxBaseURL, prompt: Text(VoiceboxClient.defaultBaseURLString))
                .textFieldStyle(.roundedBorder)

            LabeledContent("Connection") {
                VStack(alignment: .trailing, spacing: 4) {
                    Button {
                        testVoicebox()
                    } label: {
                        if isTestingVoicebox {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTestingVoicebox)
                    if let voiceboxStatus {
                        Text(voiceboxStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }

            Text("Voicebox (voicebox.sh) is a free, open-source AI voice studio that runs on this Mac — natural neural voices in 23 languages, plus voice cloning, with no accounts or fees. Launch the Voicebox app and enable its API server (gear icon), then pick an AI voice from the player bar's voice menu.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Link("Get Voicebox", destination: URL(string: "https://voicebox.sh")!)
                Spacer()
                if let docsURL = URL(string: voiceboxBaseURL.isEmpty
                                     ? VoiceboxClient.defaultBaseURLString + "/docs"
                                     : voiceboxBaseURL + "/docs") {
                    Link("Local API Reference", destination: docsURL)
                }
            }
            .font(.caption)
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
        player.currentVoiceDisplayName
            + (player.engineKind == .voicebox ? " (Voicebox AI)" : "")
    }

    private func testVoicebox() {
        isTestingVoicebox = true
        voiceboxStatus = nil
        Task {
            let result = await VoiceboxClient.shared.checkConnection()
            await MainActor.run {
                isTestingVoicebox = false
                switch result {
                case .success(let count):
                    voiceboxStatus = "Connected — \(count) voice profile\(count == 1 ? "" : "s") available."
                case .failure(let error):
                    voiceboxStatus = error.localizedDescription
                }
            }
        }
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
