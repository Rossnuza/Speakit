import Foundation
import AVFoundation
import NaturalLanguage

/// Orchestrates document narration: sentence chunking, transport controls,
/// synchronized highlighting, adjustable speed (0.5x–4.5x), and resumable
/// positions.
///
/// The actual audio comes from a pluggable `SpeechEngine`:
/// - `SystemSpeechEngine` — Apple's built-in voices (offline, word-accurate)
/// - `VoiceboxSpeechEngine` — natural AI voices from the local Voicebox app
///
/// Text is spoken one sentence at a time so that skip forward/back, live
/// speed changes, engine/voice switches, and progress tracking all work
/// without restarting the whole document.
final class SpeechPlayer: NSObject, ObservableObject {

    enum PlaybackState {
        case idle
        case speaking
        case paused
    }

    // MARK: - Published state

    @Published private(set) var state: PlaybackState = .idle
    /// Range of the word currently being spoken, in the full document text.
    @Published private(set) var highlightRange: NSRange?
    /// Range of the sentence currently being spoken, in the full document text.
    @Published private(set) var sentenceRange: NSRange?
    @Published private(set) var currentSentenceIndex: Int = 0
    @Published private(set) var currentDocumentID: UUID?
    @Published private(set) var currentTitle: String = ""
    /// Set when an engine fails (e.g. Voicebox isn't running).
    @Published var playbackError: String?

    /// Which TTS backend narrates.
    @Published var engineKind: TTSEngineKind {
        didSet {
            UserDefaults.standard.set(engineKind.rawValue, forKey: "engineKind")
            switch state {
            case .speaking:
                restartCurrentSentenceIfSpeaking()
            case .paused:
                // The old engine's queued audio is useless now; drop to idle
                // (keeping the position) so play() re-renders with the new
                // engine.
                invalidatePausedPlayback()
            case .idle:
                break
            }
        }
    }

    /// Playback speed multiplier. 1.0 is normal speech; Speechify-style range.
    @Published var speedMultiplier: Double {
        didSet {
            UserDefaults.standard.set(speedMultiplier, forKey: "defaultSpeed")
            restartCurrentSentenceIfSpeaking()
        }
    }

    /// Identifier of the selected system voice; nil = system default.
    @Published var voiceIdentifier: String? {
        didSet {
            UserDefaults.standard.set(voiceIdentifier, forKey: "defaultVoiceID")
            systemEngine.voiceIdentifier = voiceIdentifier
            if engineKind == .system { restartCurrentSentenceIfSpeaking() }
        }
    }

    /// Selected Voicebox profile (AI voice).
    @Published private(set) var voiceboxProfileID: String?
    @Published private(set) var voiceboxProfileName: String?

    /// Called whenever the sentence index advances, so the app can persist
    /// the reading position. Arguments: document id, character offset.
    var onPositionChange: ((UUID, Int) -> Void)?

    static let speedSteps: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5]

    // MARK: - Engines

    private let systemEngine = SystemSpeechEngine()
    private let voiceboxEngine = VoiceboxSpeechEngine()

    private var activeEngine: SpeechEngine {
        switch engineKind {
        case .system: return systemEngine
        case .voicebox: return voiceboxEngine
        }
    }

    // MARK: - Private

    private var fullText: String = ""
    private var sentences: [NSRange] = []

    override init() {
        let savedSpeed = UserDefaults.standard.double(forKey: "defaultSpeed")
        self.speedMultiplier = savedSpeed > 0 ? savedSpeed : 1.0
        self.voiceIdentifier = UserDefaults.standard.string(forKey: "defaultVoiceID")
        self.engineKind = UserDefaults.standard.string(forKey: "engineKind")
            .flatMap(TTSEngineKind.init(rawValue:)) ?? .system
        self.voiceboxProfileID = UserDefaults.standard.string(forKey: "voiceboxProfileID")
        self.voiceboxProfileName = UserDefaults.standard.string(forKey: "voiceboxProfileName")
        super.init()
        systemEngine.delegate = self
        voiceboxEngine.delegate = self
        systemEngine.voiceIdentifier = voiceIdentifier
        voiceboxEngine.profileID = voiceboxProfileID
    }

    var hasContent: Bool { !sentences.isEmpty }

    var progressFraction: Double {
        guard !sentences.isEmpty else { return 0 }
        return Double(currentSentenceIndex) / Double(sentences.count)
    }

    /// Human-readable name of the active voice, for the player bar.
    var currentVoiceDisplayName: String {
        switch engineKind {
        case .voicebox:
            return voiceboxProfileName ?? "Voicebox AI"
        case .system:
            if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
                return voice.name
            }
            return "System Voice"
        }
    }

    /// Rough time remaining, based on ~180 spoken words per minute at 1x.
    var estimatedSecondsRemaining: Int {
        guard hasContent, currentSentenceIndex < sentences.count else { return 0 }
        let ns = fullText as NSString
        var words = 0
        for range in sentences[currentSentenceIndex...] {
            words += ns.substring(with: range)
                .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
        let wordsPerSecond = (180.0 / 60.0) * speedMultiplier
        return Int(Double(words) / wordsPerSecond)
    }

    // MARK: - Voice selection

    /// Switches narration to a Voicebox AI voice.
    func selectVoiceboxProfile(id: String, name: String) {
        voiceboxProfileID = id
        voiceboxProfileName = name
        UserDefaults.standard.set(id, forKey: "voiceboxProfileID")
        UserDefaults.standard.set(name, forKey: "voiceboxProfileName")
        voiceboxEngine.profileID = id
        if engineKind == .voicebox {
            restartCurrentSentenceIfSpeaking()
        } else {
            engineKind = .voicebox
        }
    }

    // MARK: - Loading

    /// Loads a document for playback, resuming from a character offset.
    func load(text: String, title: String, documentID: UUID?, startAtCharacter: Int = 0) {
        stop()
        fullText = text
        currentTitle = title
        currentDocumentID = documentID
        sentences = Self.sentenceRanges(in: text)
        currentSentenceIndex = sentenceIndex(containing: startAtCharacter)
    }

    func isPlaying(documentID: UUID) -> Bool {
        currentDocumentID == documentID && state == .speaking
    }

    // MARK: - Transport controls

    func play() {
        switch state {
        case .paused:
            activeEngine.resume()
            state = .speaking
        case .idle:
            guard hasContent else { return }
            if currentSentenceIndex >= sentences.count { currentSentenceIndex = 0 }
            state = .speaking
            speakCurrentSentence()
        case .speaking:
            break
        }
    }

    func pause() {
        guard state == .speaking else { return }
        activeEngine.pause()
        state = .paused
    }

    func togglePlayPause() {
        state == .speaking ? pause() : play()
    }

    func stop() {
        state = .idle
        systemEngine.stop()
        voiceboxEngine.stop()
        highlightRange = nil
        sentenceRange = nil
    }

    func skipForward() {
        guard hasContent, currentSentenceIndex + 1 < sentences.count else { return }
        jump(to: currentSentenceIndex + 1)
    }

    func skipBackward() {
        guard hasContent else { return }
        jump(to: max(0, currentSentenceIndex - 1))
    }

    /// Jumps playback to the sentence containing the given character offset
    /// (used when the user clicks in the reader).
    func seek(toCharacter offset: Int) {
        guard hasContent else { return }
        jump(to: sentenceIndex(containing: offset))
    }

    // MARK: - Internals

    private func jump(to index: Int) {
        let wasActive = (state != .idle)
        activeEngine.stop()
        currentSentenceIndex = index
        notifyPosition()
        if wasActive {
            state = .speaking
            speakCurrentSentence()
        }
    }

    private func restartCurrentSentenceIfSpeaking() {
        guard state == .speaking else { return }
        systemEngine.stop()
        voiceboxEngine.stop()
        speakCurrentSentence()
    }

    private func invalidatePausedPlayback() {
        systemEngine.stop()
        voiceboxEngine.stop()
        state = .idle
        highlightRange = nil
        sentenceRange = nil
    }

    private func speakCurrentSentence() {
        guard currentSentenceIndex < sentences.count else {
            finishPlayback()
            return
        }
        let range = sentences[currentSentenceIndex]
        sentenceRange = range
        let ns = fullText as NSString
        activeEngine.speak(sentence: ns.substring(with: range), rateMultiplier: speedMultiplier)

        // Keep the pipeline warm: pre-render the next sentence.
        if currentSentenceIndex + 1 < sentences.count {
            let next = ns.substring(with: sentences[currentSentenceIndex + 1])
            activeEngine.prefetch(sentence: next, rateMultiplier: speedMultiplier)
        }
    }

    private func finishPlayback() {
        state = .idle
        highlightRange = nil
        sentenceRange = nil
        notifyPosition()
    }

    private func notifyPosition() {
        guard let id = currentDocumentID else { return }
        let offset = currentSentenceIndex < sentences.count
            ? sentences[currentSentenceIndex].location
            : (fullText as NSString).length
        onPositionChange?(id, offset)
    }

    private func sentenceIndex(containing character: Int) -> Int {
        for (i, range) in sentences.enumerated()
        where character < range.location + range.length {
            return i
        }
        return max(0, sentences.count - 1)
    }

    /// Maps a human speed multiplier to AVSpeechUtterance's 0...1 rate scale,
    /// where 0.5 is normal speech.
    static func avRate(forMultiplier multiplier: Double) -> Float {
        let m = min(max(multiplier, 0.5), 4.5)
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate) // 0.5
        let rate: Double
        if m <= 1.0 {
            rate = normal * m
        } else {
            let maxRate = Double(AVSpeechUtteranceMaximumSpeechRate) // 1.0
            rate = normal + (m - 1.0) / 3.5 * (maxRate - normal)
        }
        return Float(rate)
    }

    static func sentenceRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let nsRange = NSRange(range, in: text)
            let chunk = text[range]
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ranges.append(nsRange)
            }
            return true
        }
        return ranges
    }
}

// MARK: - SpeechEngineDelegate

extension SpeechPlayer: SpeechEngineDelegate {

    func engine(_ engine: SpeechEngine, willSpeakRangeInSentence range: NSRange) {
        guard engine === activeEngine,
              state == .speaking,
              currentSentenceIndex < sentences.count else { return }
        let sentence = sentences[currentSentenceIndex]
        let location = sentence.location + range.location
        let length = min(range.length, max(0, sentence.length - range.location))
        guard length > 0 else { return }
        highlightRange = NSRange(location: location, length: length)
    }

    func engineDidFinishSentence(_ engine: SpeechEngine) {
        guard engine === activeEngine, state == .speaking else { return }
        currentSentenceIndex += 1
        notifyPosition()
        if currentSentenceIndex < sentences.count {
            speakCurrentSentence()
        } else {
            finishPlayback()
        }
    }

    func engine(_ engine: SpeechEngine, didFailWith message: String) {
        guard engine === activeEngine else { return }
        playbackError = message
        state = .idle
        highlightRange = nil
        sentenceRange = nil
    }
}
