import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Full-document reading view with synchronized highlighting and the
/// playback bar docked at the bottom.
struct ReaderView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var player: SpeechPlayer

    let document: Document

    @AppStorage("readerFontSize") private var fontSize: Double = 17
    @State private var text: String = ""
    @State private var isExporting = false
    @State private var exportMessage: String?

    private var isCurrentDocument: Bool {
        player.currentDocumentID == document.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HighlightingTextView(
                text: text,
                wordRange: isCurrentDocument ? player.highlightRange : nil,
                sentenceRange: isCurrentDocument ? player.sentenceRange : nil,
                fontSize: fontSize,
                onSeek: { characterIndex in
                    ensureLoaded()
                    player.seek(toCharacter: characterIndex)
                }
            )

            Divider()

            PlayerBar(
                player: player,
                isExporting: isExporting,
                onPlayPause: {
                    if isCurrentDocument {
                        player.togglePlayPause()
                    } else {
                        appState.listen(to: document)
                    }
                },
                onExport: exportAudio
            )
        }
        .navigationTitle(document.title)
        .navigationSubtitle("\(document.sourceKind.label) · \(document.wordCount) words · ~\(document.estimatedListeningLabel)")
        .toolbar {
            ToolbarItemGroup {
                Slider(value: $fontSize, in: 12...30) {
                    Text("Text Size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                .frame(width: 140)
                .help("Reader text size")
            }
        }
        .onAppear(perform: loadText)
        .onChange(of: document.id) {
            loadText()
        }
        .alert("Audio Export", isPresented: .init(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportMessage ?? "")
        }
    }

    private func loadText() {
        text = appState.library.text(for: document.id) ?? ""
    }

    /// Makes sure this document is the one loaded in the player before
    /// seek/play operations.
    private func ensureLoaded() {
        guard !isCurrentDocument else { return }
        player.load(text: text,
                    title: document.title,
                    documentID: document.id,
                    startAtCharacter: document.lastPosition)
        player.play()
    }

    private func exportAudio() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "caf") ?? .audio]
        panel.nameFieldStringValue = document.title + ".caf"
        panel.title = "Export Narration Audio"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isExporting = true
            AudioExporter.export(
                text: text,
                voiceIdentifier: player.voiceIdentifier,
                speedMultiplier: player.speedMultiplier,
                to: url
            ) { result in
                isExporting = false
                switch result {
                case .success(let fileURL):
                    exportMessage = "Saved narration to \(fileURL.lastPathComponent)."
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                case .failure(let error):
                    exportMessage = error.localizedDescription
                }
            }
        }
    }
}
