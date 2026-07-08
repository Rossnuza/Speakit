import Foundation
import AppKit
import SwiftUI
import Combine

/// Central coordinator: owns the long-lived services, wires up global
/// hotkeys, and routes cross-cutting actions (quick-listen, position saves,
/// the dictation HUD).
final class AppState: ObservableObject {

    static let shared = AppState()

    let library = LibraryStore()
    let player = SpeechPlayer()
    let dictation = DictationService()

    @Published var selectedDocumentID: UUID?
    @Published var lastError: String?

    private let hotkeys = HotkeyManager()
    private let dictationHUD = DictationHUDController()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        player.onPositionChange = { [weak self] documentID, offset in
            self?.library.updatePosition(documentID: documentID, characterOffset: offset)
        }

        hotkeys.register(.toggleDictation) { [weak self] in
            self?.toggleDictation()
        }
        hotkeys.register(.readSelection) { [weak self] in
            self?.readSelectionFromFrontmostApp()
        }

        dictation.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                guard let self else { return }
                recording ? self.dictationHUD.show(service: self.dictation)
                          : self.dictationHUD.hide()
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    func toggleDictation() {
        dictation.toggle()
    }

    /// ⌥R from anywhere: copies the frontmost app's current selection
    /// (synthesized ⌘C) and reads it aloud — Speechify's "listen to
    /// anything on your screen".
    func readSelectionFromFrontmostApp() {
        if player.state == .speaking, player.currentDocumentID == nil {
            // Second press while quick-listening acts as stop.
            player.stop()
            return
        }
        guard TextInserter.hasAccessibilityPermission else {
            TextInserter.requestAccessibilityPermission()
            return
        }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let changeCountBefore = pasteboard.changeCount

        Self.postCommandC()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            defer {
                if let saved {
                    pasteboard.clearContents()
                    pasteboard.setString(saved, forType: .string)
                }
            }
            guard pasteboard.changeCount != changeCountBefore,
                  let selection = pasteboard.string(forType: .string),
                  !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            self.player.load(text: selection, title: "Quick Listen", documentID: nil)
            self.player.play()
        }
    }

    /// Opens a document in the player (resuming its saved position) and
    /// starts playback.
    func listen(to document: Document) {
        guard let text = library.text(for: document.id) else {
            lastError = "The text for “\(document.title)” could not be loaded."
            return
        }
        selectedDocumentID = document.id
        if player.currentDocumentID != document.id {
            let start = document.progress >= 0.999 ? 0 : document.lastPosition
            player.load(text: text, title: document.title, documentID: document.id, startAtCharacter: start)
        }
        player.togglePlayPause()
    }

    // MARK: - Importing

    @MainActor
    func importFiles(_ urls: [URL]) async {
        for url in urls {
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let extracted = try await TextExtractor.extract(from: url)
                let doc = library.add(title: extracted.title,
                                      text: extracted.text,
                                      sourceKind: extracted.sourceKind)
                selectedDocumentID = doc.id
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    @MainActor
    func importWebPage(_ urlString: String) async {
        do {
            let extracted = try await TextExtractor.extractWebPage(from: urlString)
            let doc = library.add(title: extracted.title,
                                  text: extracted.text,
                                  sourceKind: extracted.sourceKind)
            selectedDocumentID = doc.id
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importPastedText(title: String, text: String) {
        let cleaned = TextExtractor.normalize(text)
        guard !cleaned.isEmpty else {
            lastError = "There's no text to import."
            return
        }
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.suggestedTitle(from: cleaned)
            : title
        let doc = library.add(title: finalTitle, text: cleaned, sourceKind: .pasted)
        selectedDocumentID = doc.id
    }

    static func suggestedTitle(from text: String) -> String {
        let firstLine = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "Untitled"
        return String(firstLine.prefix(60))
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKeyCode: CGKeyCode = 8
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
