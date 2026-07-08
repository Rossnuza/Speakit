import Foundation
import AVFoundation

/// Renders a document's narration to an audio file so it can be listened
/// to offline or on another device — Speakit's take on Speechify's
/// downloadable audio.
final class AudioExporter {

    enum ExportError: LocalizedError {
        case unsupportedBuffer
        case writeFailed(String)
        case formatMismatch

        var errorDescription: String? {
            switch self {
            case .unsupportedBuffer:
                return "The synthesizer produced audio in an unexpected format."
            case .writeFailed(let detail):
                return "Could not write the audio file: \(detail)"
            case .formatMismatch:
                return "Voicebox returned clips in differing audio formats; try a different voice profile."
            }
        }
    }

    /// Routes to the engine the player is currently narrating with.
    static func export(text: String,
                       using player: SpeechPlayer,
                       to destination: URL,
                       completion: @escaping (Result<URL, Error>) -> Void) {
        switch player.engineKind {
        case .voicebox:
            exportViaVoicebox(text: text,
                              profileID: player.voiceboxProfileID,
                              to: destination,
                              completion: completion)
        case .system:
            export(text: text,
                   voiceIdentifier: player.voiceIdentifier,
                   speedMultiplier: player.speedMultiplier,
                   to: destination,
                   completion: completion)
        }
    }

    /// Renders every sentence through the local Voicebox API and stitches
    /// the clips into a single WAV file. Runs at natural (1x) speed.
    static func exportViaVoicebox(text: String,
                                  profileID: String?,
                                  to destination: URL,
                                  completion: @escaping (Result<URL, Error>) -> Void) {
        let sentences = SpeechPlayer.sentenceRanges(in: text)
        let ns = text as NSString
        Task {
            do {
                try? FileManager.default.removeItem(at: destination)
                var outputFile: AVAudioFile?
                for range in sentences {
                    let sentence = ns.substring(with: range)
                    let data = try await VoiceboxClient.shared.generate(text: sentence, profileID: profileID)
                    let buffer = try Self.pcmBuffer(from: data)
                    if outputFile == nil {
                        outputFile = try AVAudioFile(forWriting: destination,
                                                     settings: buffer.format.settings)
                    }
                    guard outputFile?.processingFormat == buffer.format else {
                        throw ExportError.formatMismatch
                    }
                    try outputFile?.write(from: buffer)
                }
                await MainActor.run { completion(.success(destination)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private static func pcmBuffer(from data: Data) throws -> AVAudioPCMBuffer {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakit-export-\(UUID().uuidString).wav")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let file = try AVAudioFile(forReading: tempURL)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: frameCount) else {
            throw ExportError.unsupportedBuffer
        }
        try file.read(into: buffer)
        return buffer
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
