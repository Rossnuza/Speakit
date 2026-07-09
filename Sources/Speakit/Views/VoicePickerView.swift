import SwiftUI
import AppKit
import AVFoundation

/// Voice chooser with two engines:
/// - **Voicebox AI** — natural neural voices (and clones) served by the
///   open-source Voicebox app running locally on this Mac
/// - **System** — every Apple speech voice installed, across 60+ languages
struct VoicePickerView: View {
    @ObservedObject var player: SpeechPlayer

    @State private var selectedTab: TTSEngineKind

    init(player: SpeechPlayer) {
        self.player = player
        _selectedTab = State(initialValue: player.engineKind)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Engine", selection: $selectedTab) {
                ForEach(TTSEngineKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch selectedTab {
            case .voicebox:
                VoiceboxVoiceList(player: player)
            case .system:
                SystemVoiceList(player: player)
            }
        }
        .frame(width: 360, height: 460)
    }
}

// MARK: - Voicebox AI voices

private struct VoiceboxVoiceList: View {
    @ObservedObject var player: SpeechPlayer

    @State private var profiles: [VoiceboxClient.Profile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var previewingID: String?

    /// Keeps the preview player alive while its clip plays.
    @State private var previewPlayer: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Contacting Voicebox…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if let errorMessage {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Voicebox isn't reachable")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Button("Try Again") { Task { await loadProfiles() } }
                    Link("Get Voicebox (free, open source)",
                         destination: URL(string: "https://voicebox.sh")!)
                        .font(.caption)
                }
                .padding()
                .frame(maxWidth: .infinity)
                Spacer()
            } else if profiles.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("No voice profiles yet")
                        .font(.headline)
                    Text("Create a voice profile in the Voicebox app (you can clone a voice from a few seconds of audio), then refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Refresh") { Task { await loadProfiles() } }
                }
                .padding()
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("AI voices run locally via Voicebox — free, offline, unlimited.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await loadProfiles() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh voice profiles")
            }
            .padding(10)
        }
        .task { await loadProfiles() }
    }

    @ViewBuilder
    private func profileRow(_ profile: VoiceboxClient.Profile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                Text(subtitle(for: profile))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                preview(profile)
            } label: {
                if previewingID == profile.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.circle")
                }
            }
            .buttonStyle(.borderless)
            .help("Preview this voice")

            if player.engineKind == .voicebox && player.voiceboxProfileID == profile.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            player.selectVoiceboxProfile(id: profile.id, name: profile.name, engine: profile.engine)
        }
    }

    private func subtitle(for profile: VoiceboxClient.Profile) -> String {
        var parts: [String] = ["Voicebox AI"]
        if let engine = profile.engine { parts.append(engine) }
        if let language = profile.language { parts.append(language) }
        return parts.joined(separator: " · ")
    }

    private func loadProfiles() async {
        isLoading = true
        errorMessage = nil
        do {
            profiles = try await VoiceboxClient.shared.fetchProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func preview(_ profile: VoiceboxClient.Profile) {
        guard previewingID == nil else { return }
        previewingID = profile.id
        Task {
            defer { previewingID = nil }
            do {
                let data = try await VoiceboxClient.shared.generate(
                    text: "Hi, I'm \(profile.name). This is how I sound in Speakit.",
                    profileID: profile.id,
                    engine: profile.engine
                )
                let audioPlayer = try AVAudioPlayer(data: data)
                previewPlayer = audioPlayer
                audioPlayer.play()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - System voices

private struct SystemVoiceList: View {
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

            if player.engineKind == .system && player.voiceIdentifier == voice.identifier {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            player.engineKind = .system
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
