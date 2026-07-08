import Foundation
import AVFoundation

/// Which text-to-speech backend narrates documents.
enum TTSEngineKind: String, CaseIterable, Identifiable {
    /// Apple's built-in AVSpeechSynthesizer voices.
    case system
    /// Voicebox (voicebox.sh) — local open-source AI voices served over
    /// its REST API on this Mac.
    case voicebox

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .voicebox: return "Voicebox AI"
        }
    }
}

protocol SpeechEngineDelegate: AnyObject {
    /// The engine is about to speak this range *within the current
    /// sentence*. For AI audio the range is estimated from timing.
    func engine(_ engine: SpeechEngine, willSpeakRangeInSentence range: NSRange)
    /// The current sentence finished playing naturally.
    func engineDidFinishSentence(_ engine: SpeechEngine)
    /// Something went wrong (e.g. the Voicebox server isn't running).
    func engine(_ engine: SpeechEngine, didFailWith message: String)
}

/// One sentence-at-a-time speech backend. The player orchestrates
/// sentences, transport, and progress; engines only render audio.
protocol SpeechEngine: AnyObject {
    var delegate: SpeechEngineDelegate? { get set }
    func speak(sentence: String, rateMultiplier: Double)
    func pause()
    func resume()
    /// Stop and discard any queued or in-flight audio.
    func stop()
    /// Optional hint: the given sentence will likely be spoken next.
    func prefetch(sentence: String, rateMultiplier: Double)
}

extension SpeechEngine {
    func prefetch(sentence: String, rateMultiplier: Double) {}
}

// MARK: - System engine (AVSpeechSynthesizer)

/// Apple's built-in synthesizer. Fast, offline, with true word-accurate
/// highlight callbacks.
final class SystemSpeechEngine: NSObject, SpeechEngine {

    weak var delegate: SpeechEngineDelegate?

    /// Identifier of the AVSpeechSynthesisVoice to use; nil = default.
    var voiceIdentifier: String?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(sentence: String, rateMultiplier: Double) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.rate = SpeechPlayer.avRate(forMultiplier: rateMultiplier)
        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension SystemSpeechEngine: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, willSpeakRangeInSentence: characterRange)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engineDidFinishSentence(self)
        }
    }
}
