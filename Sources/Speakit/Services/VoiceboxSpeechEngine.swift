import Foundation
import AVFoundation

/// Speaks sentences through Voicebox's local AI voices.
///
/// Pipeline: sentence text → Voicebox REST /generate → WAV →
/// AVAudioPlayerNode → AVAudioUnitTimePitch (speed without pitch shift,
/// covering Speakit's full 0.5x–4.5x range) → output.
///
/// While one sentence plays, the next is prefetched so playback flows
/// without gaps. Word highlighting is estimated by distributing the
/// clip's duration across the sentence's words by length.
final class VoiceboxSpeechEngine: SpeechEngine {

    weak var delegate: SpeechEngineDelegate?

    /// Voicebox profile (voice) to render with.
    var profileID: String?
    /// TTS engine the profile runs on (kokoro, qwen, …), sent with each
    /// request because Voicebox validates the pairing.
    var profileEngine: String?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var connectedFormat: AVAudioFormat?

    /// Bumped on every speak/stop; async completions compare against it so
    /// stale network replies and buffer callbacks are ignored.
    private var generation = 0

    // Rendered-audio cache, keyed by profile + sentence.
    private let cache = NSCache<NSString, NSData>()
    private var inFlightPrefetches = Set<String>()

    // Estimated word-highlight timing.
    private var wordTimer: Timer?
    private var wordSchedule: [(range: NSRange, start: TimeInterval, end: TimeInterval)] = []
    private var lastReportedWordIndex = -1
    private var playbackStartDate: Date?
    private var accumulatedPlaybackTime: TimeInterval = 0

    private var isPausedByUser = false
    /// Audio arrived while paused; start it on resume.
    private var startIsPending = false

    init() {
        cache.countLimit = 32
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
    }

    // MARK: - SpeechEngine

    func speak(sentence: String, rateMultiplier: Double) {
        cancelCurrentPlayback()
        generation += 1
        let gen = generation
        isPausedByUser = false
        startIsPending = false
        timePitch.rate = Float(min(max(rateMultiplier, 0.5), 4.5))

        if let cached = cache.object(forKey: cacheKey(for: sentence)) {
            startPlayback(of: cached as Data, sentence: sentence, generation: gen)
            return
        }

        let profile = profileID
        let engine = profileEngine
        Task { [weak self] in
            do {
                let data = try await VoiceboxClient.shared.generate(text: sentence, profileID: profile, engine: engine)
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    self.cache.setObject(data as NSData, forKey: self.cacheKey(for: sentence))
                    self.startPlayback(of: data, sentence: sentence, generation: gen)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.generation == gen else { return }
                    self.delegate?.engine(self, didFailWith: error.localizedDescription)
                }
            }
        }
    }

    func prefetch(sentence: String, rateMultiplier: Double) {
        let key = cacheKey(for: sentence)
        guard cache.object(forKey: key) == nil,
              !inFlightPrefetches.contains(key as String) else { return }
        inFlightPrefetches.insert(key as String)

        let profile = profileID
        let engine = profileEngine
        Task { [weak self] in
            let data = try? await VoiceboxClient.shared.generate(text: sentence, profileID: profile, engine: engine)
            await MainActor.run {
                guard let self else { return }
                self.inFlightPrefetches.remove(key as String)
                if let data {
                    self.cache.setObject(data as NSData, forKey: key)
                }
            }
        }
    }

    func pause() {
        isPausedByUser = true
        guard !startIsPending else { return }
        playerNode.pause()
        if let start = playbackStartDate {
            accumulatedPlaybackTime += Date().timeIntervalSince(start)
            playbackStartDate = nil
        }
    }

    func resume() {
        isPausedByUser = false
        if startIsPending {
            startIsPending = false
            beginScheduledPlayback()
            return
        }
        playerNode.play()
        playbackStartDate = Date()
    }

    func stop() {
        generation += 1
        cancelCurrentPlayback()
        isPausedByUser = false
        startIsPending = false
    }

    // MARK: - Playback

    private func startPlayback(of data: Data, sentence: String, generation gen: Int) {
        do {
            let buffer = try Self.pcmBuffer(from: data)
            try configureGraph(for: buffer.format)

            let clipDuration = Double(buffer.frameLength) / buffer.format.sampleRate
            let effectiveDuration = clipDuration / Double(timePitch.rate)
            buildWordSchedule(for: sentence, duration: effectiveDuration)

            playerNode.stop()
            playerNode.scheduleBuffer(buffer, at: nil, options: [],
                                      completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.cancelCurrentPlayback()
                    self.delegate?.engineDidFinishSentence(self)
                }
            }

            if isPausedByUser {
                startIsPending = true
            } else {
                beginScheduledPlayback()
            }
        } catch {
            delegate?.engine(self, didFailWith: error.localizedDescription)
        }
    }

    private func beginScheduledPlayback() {
        playerNode.play()
        accumulatedPlaybackTime = 0
        playbackStartDate = Date()
        lastReportedWordIndex = -1
        startWordTimer()
        reportWordHighlightIfNeeded()
    }

    private func configureGraph(for format: AVAudioFormat) throws {
        if connectedFormat != format {
            playerNode.stop()
            audioEngine.connect(playerNode, to: timePitch, format: format)
            audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }
    }

    private func cancelCurrentPlayback() {
        wordTimer?.invalidate()
        wordTimer = nil
        wordSchedule = []
        lastReportedWordIndex = -1
        playbackStartDate = nil
        accumulatedPlaybackTime = 0
        playerNode.stop()
    }

    private func cacheKey(for sentence: String) -> NSString {
        "\(profileID ?? "default")|\(sentence)" as NSString
    }

    /// Decodes audio data (WAV from Voicebox) into a PCM buffer via a
    /// temporary file, which lets AVAudioFile handle any container format.
    private static func pcmBuffer(from data: Data) throws -> AVAudioPCMBuffer {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakit-vb-\(UUID().uuidString).wav")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let file = try AVAudioFile(forReading: tempURL)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frameCount) else {
            throw VoiceboxClient.ClientError.unrecognizedAudioPayload("empty audio clip")
        }
        try file.read(into: buffer)
        return buffer
    }

    // MARK: - Estimated word highlighting

    private func buildWordSchedule(for sentence: String, duration: TimeInterval) {
        wordSchedule = []
        guard duration > 0 else { return }

        let ns = sentence as NSString
        var wordRanges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            wordRanges.append(range)
        }
        guard !wordRanges.isEmpty else { return }

        // Weight each word by its character count (+2 to account for the
        // pause around short words), then spread the clip duration.
        let weights = wordRanges.map { Double($0.length + 2) }
        let totalWeight = weights.reduce(0, +)
        var cursor: TimeInterval = 0
        for (range, weight) in zip(wordRanges, weights) {
            let slice = duration * (weight / totalWeight)
            wordSchedule.append((range: range, start: cursor, end: cursor + slice))
            cursor += slice
        }
    }

    private func startWordTimer() {
        wordTimer?.invalidate()
        guard !wordSchedule.isEmpty else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.reportWordHighlightIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        wordTimer = timer
    }

    private func reportWordHighlightIfNeeded() {
        guard !wordSchedule.isEmpty else { return }
        let elapsed = accumulatedPlaybackTime
            + (playbackStartDate.map { Date().timeIntervalSince($0) } ?? 0)
        var index = wordSchedule.firstIndex { elapsed >= $0.start && elapsed < $0.end }
            ?? (elapsed >= (wordSchedule.last?.end ?? 0) ? wordSchedule.count - 1 : 0)
        index = min(max(index, 0), wordSchedule.count - 1)
        guard index != lastReportedWordIndex else { return }
        lastReportedWordIndex = index
        delegate?.engine(self, willSpeakRangeInSentence: wordSchedule[index].range)
    }
}
