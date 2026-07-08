import Foundation
import AVFoundation

/// Renders a document's narration to an audio file so it can be listened
/// to offline or on another device — Speakit's take on Speechify's
/// downloadable audio.
final class AudioExporter {

    enum ExportError: LocalizedError {
        case unsupportedBuffer
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedBuffer:
                return "The synthesizer produced audio in an unexpected format."
            case .writeFailed(let detail):
                return "Could not write the audio file: \(detail)"
            }
        }
    }

    /// Keeps in-flight exports alive until their completion fires.
    private static var activeExports: [ObjectIdentifier: AudioExporter] = [:]

    private let synthesizer = AVSpeechSynthesizer()
    private var audioFile: AVAudioFile?
    private var failure: Error?

    /// Synthesizes `text` with the given voice and speed into a Core Audio
    /// file at `destination` (use a .caf extension).
    static func export(text: String,
                       voiceIdentifier: String?,
                       speedMultiplier: Double,
                       to destination: URL,
                       completion: @escaping (Result<URL, Error>) -> Void) {
        let exporter = AudioExporter()
        activeExports[ObjectIdentifier(exporter)] = exporter
        exporter.run(text: text,
                     voiceIdentifier: voiceIdentifier,
                     speedMultiplier: speedMultiplier,
                     destination: destination) { result in
            DispatchQueue.main.async {
                activeExports[ObjectIdentifier(exporter)] = nil
                completion(result)
            }
        }
    }

    private func run(text: String,
                     voiceIdentifier: String?,
                     speedMultiplier: Double,
                     destination: URL,
                     completion: @escaping (Result<URL, Error>) -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = SpeechPlayer.avRate(forMultiplier: speedMultiplier)
        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }

        try? FileManager.default.removeItem(at: destination)

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                self.failure = ExportError.unsupportedBuffer
                return
            }
            // A zero-length buffer marks the end of synthesis.
            if pcmBuffer.frameLength == 0 {
                if let failure = self.failure {
                    completion(.failure(failure))
                } else {
                    completion(.success(destination))
                }
                return
            }
            do {
                if self.audioFile == nil {
                    self.audioFile = try AVAudioFile(
                        forWriting: destination,
                        settings: pcmBuffer.format.settings
                    )
                }
                try self.audioFile?.write(from: pcmBuffer)
            } catch {
                if self.failure == nil {
                    self.failure = ExportError.writeFailed(error.localizedDescription)
                }
            }
        }
    }
}
