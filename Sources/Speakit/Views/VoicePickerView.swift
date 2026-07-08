import SwiftUI
import AVFoundation

/// Browses every speech voice installed on the Mac — hundreds across 60+
/// languages, including Enhanced and Premium neural voices — with search
/// and instant preview. More voices can be added in System Settings.
struct VoicePickerView: View {
    @ObservedObject var player: SpeechPlayer

    @State private var searchText = ""
    @State private var previewSynthesizer = AVSpeechSynthesizer()

    private struct LanguageGroup: Identifiable {
        let id: String
        let displayName: String
        let voices: [AVSpeechSynthesisVoice]
    }

    private var groups: [LanguageGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            guard !query.isEmpty else { return true }
            return voice.name.lowercased().contains(query)
                || Self.languageName(for: voice.language).lowercased().contains(query)
                || voice.language.lowercased().contains(query)
        }
        let grouped = Dictionary(grouping: voices) { $0.language }
        return grouped
            .map { code, voices in
                LanguageGroup(
                    id: code,
                    displayName: Self.languageName(for: code),
                    voices: voices.sorted { Self.qualityRank($0) == Self.qualityRank($1)
                        ? $0.name < $1.name
                        : Self.qualityRank($0) > Self.qualityRank($1) }
                )
            }
            .sorted { lhs, rhs in
                // Current locale's language floats to the top.
                let current = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
                if lhs.id == current { return true }
                if rhs.id == current { return false }
                return lhs.displayName < rhs.displayName
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search voices or languages", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)

            Divider()

            List {
                ForEach(groups) { group in
                    Section(group.displayName) {
                        ForEach(group.voices, id: \.identifier) { voice in
                            voiceRow(voice)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            Text("Add more voices in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .frame(width: 340, height: 420)
    }

    @ViewBuilder
    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(voice.name)
                Text(qualityLabel(voice))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                preview(voice)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Preview this voice")

            if player.voiceIdentifier == voice.identifier {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            player.voiceIdentifier = voice.identifier
        }
    }

    private func preview(_ voice: AVSpeechSynthesisVoice) {
        previewSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Hi, I'm \(voice.name). This is how I sound.")
        utterance.voice = voice
        utterance.rate = SpeechPlayer.avRate(forMultiplier: 1.0)
        previewSynthesizer.speak(utterance)
    }

    private func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    private static func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 2
        case .enhanced: return 1
        default: return 0
        }
    }

    private static func languageName(for code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}
