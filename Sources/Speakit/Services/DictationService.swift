import Foundation
import AVFoundation
import Speech
import AppKit
import ApplicationServices

/// System-wide voice typing, mirroring Speechify's ⌥Z dictation:
/// press the hotkey anywhere, speak naturally, press it again — Speakit
/// transcribes the audio, strips filler words ("um", "uh", "you know"),
/// tidies the phrasing, and types the result into the frontmost app.
final class DictationService: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var liveTranscript = ""
    @Published private(set) var authorizationDenied = false

    /// Remove disfluencies before inserting text.
    var removeFillerWords: Bool {
        get { UserDefaults.standard.object(forKey: "removeFillerWords") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "removeFillerWords") }
    }

    /// Capitalize the first letter and add a trailing period when the
    /// speaker clearly finished a sentence.
    var autoPunctuate: Bool {
        get { UserDefaults.standard.object(forKey: "autoPunctuate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPunctuate") }
    }

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var awaitingFinalResult = false
    private var insertionFallbackTimer: Timer?
    private var didInsert = false

    private static let fillerPattern = try? NSRegularExpression(
        pattern: "\\b(um+|uh+|uhm+|erm+|er|ah+|hmm+|mmm+)\\b[,.]?\\s*|\\b(you know|i mean|sort of like|kind of like)\\b,?\\s*",
        options: [.caseInsensitive]
    )

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        recognizer?.defaultTaskHint = .dictation
    }

    // MARK: - Public API

    func toggle() {
        isRecording ? finishAndInsert() : start()
    }

    func start() {
        guard !isRecording else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.authorizationDenied = true
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.authorizationDenied = true
                            return
                        }
                        self.beginRecording()
                    }
                }
            }
        }
    }

    /// Stops recording, waits briefly for the recognizer's final result,
    /// then cleans and inserts the text into the frontmost app.
    func finishAndInsert() {
        guard isRecording else { return }
        isRecording = false
        awaitingFinalResult = true
        didInsert = false

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()

        // If no final result arrives quickly, insert the best partial.
        insertionFallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.insertPendingTranscript()
        }
    }

    func cancel() {
        isRecording = false
        awaitingFinalResult = false
        tearDown()
        liveTranscript = ""
    }

    // MARK: - Recording

    private func beginRecording() {
        tearDown()
        liveTranscript = ""
        authorizationDenied = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            // Prefer on-device for privacy and offline use; the recognizer
            // still falls back to the server when unavailable.
            request.requiresOnDeviceRecognition = false
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            NSLog("Speakit: no audio input device available.")
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            NSLog("Speakit: audio engine failed to start: \(error.localizedDescription)")
            tearDown()
            return
        }

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    if result.isFinal, self.awaitingFinalResult {
                        self.insertPendingTranscript()
                    }
                }
                if error != nil, self.awaitingFinalResult {
                    self.insertPendingTranscript()
                }
            }
        }

        isRecording = true
        NSSound(named: "Pop")?.play()
    }

    private func insertPendingTranscript() {
        guard awaitingFinalResult, !didInsert else { return }
        didInsert = true
        awaitingFinalResult = false
        insertionFallbackTimer?.invalidate()
        insertionFallbackTimer = nil
        tearDown()

        let cleaned = cleanTranscript(liveTranscript)
        liveTranscript = ""
        guard !cleaned.isEmpty else { return }
        TextInserter.insert(cleaned)
        NSSound(named: "Bottle")?.play()
    }

    private func tearDown() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    // MARK: - Transcript cleanup

    func cleanTranscript(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if removeFillerWords, let pattern = Self.fillerPattern {
            let range = NSRange(text.startIndex..., in: text)
            text = pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }

        // Collapse doubled spaces and stray space-before-punctuation left
        // behind by filler removal.
        text = text.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if autoPunctuate {
            text = text.prefix(1).uppercased() + String(text.dropFirst())
            if let last = text.last, !"?!.,;:".contains(last), text.split(separator: " ").count >= 3 {
                text += "."
            }
        }
        return text
    }
}

/// Inserts text into whatever app currently has keyboard focus, via the
/// pasteboard plus a synthesized ⌘V. Requires the Accessibility permission.
enum TextInserter {

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility access in System Settings.
    static func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func insert(_ text: String) {
        guard hasAccessibilityPermission else {
            requestAccessibilityPermission()
            // Leave the text on the clipboard so nothing is lost.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }

        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Give the pasteboard a beat to settle before synthesizing ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            postCommandV()
            // Restore whatever the user had on the clipboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let saved = savedItems {
                    pasteboard.clearContents()
                    pasteboard.setString(saved, forType: .string)
                }
            }
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
