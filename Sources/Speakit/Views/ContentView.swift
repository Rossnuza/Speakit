import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Main window: library sidebar on the left, reader + player on the right.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var library: LibraryStore
    @ObservedObject var player: SpeechPlayer
    @ObservedObject var dictation: DictationService

    @State private var showFileImporter = false
    @State private var showPasteSheet = false
    @State private var showWebSheet = false
    @State private var isImporting = false

    private static let importableTypes: [UTType] = {
        var types: [UTType] = [.pdf, .plainText, .rtf, .html, .image]
        for ext in ["docx", "doc", "odt", "epub", "md", "markdown"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Import Files…", systemImage: "doc.badge.plus") {
                        showFileImporter = true
                    }
                    Button("Listen to a Web Page…", systemImage: "globe") {
                        showWebSheet = true
                    }
                    Button("Paste Text…", systemImage: "doc.on.clipboard") {
                        showPasteSheet = true
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add something to listen to")

                Button {
                    appState.toggleDictation()
                } label: {
                    Label("Voice Typing",
                          systemImage: dictation.isRecording ? "mic.fill" : "mic")
                        .foregroundStyle(dictation.isRecording ? .red : .primary)
                }
                .help("Toggle system-wide voice typing (⌥Z)")
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                isImporting = true
                Task { @MainActor in
                    await appState.importFiles(urls)
                    isImporting = false
                }
            }
        }
        .sheet(isPresented: $showPasteSheet) {
            PasteTextSheet { title, text in
                appState.importPastedText(title: title, text: text)
            }
        }
        .sheet(isPresented: $showWebSheet) {
            WebLinkSheet { urlString in
                isImporting = true
                Task { @MainActor in
                    await appState.importWebPage(urlString)
                    isImporting = false
                }
            }
        }
        .alert("Speakit", isPresented: .init(
            get: { appState.lastError != nil },
            set: { if !$0 { appState.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.lastError ?? "")
        }
        .overlay {
            if isImporting {
                ProgressView("Importing…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $appState.selectedDocumentID) {
            Section("Library") {
                ForEach(library.documents) { document in
                    DocumentRow(document: document,
                                isSpeaking: player.isPlaying(documentID: document.id))
                        .tag(document.id)
                        .contextMenu {
                            Button("Listen") { appState.listen(to: document) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                deleteDocument(document)
                            }
                        }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 270)
        .overlay {
            if library.documents.isEmpty {
                EmptyLibraryHint()
            }
        }
    }

    private func deleteDocument(_ document: Document) {
        if player.currentDocumentID == document.id {
            player.stop()
        }
        if appState.selectedDocumentID == document.id {
            appState.selectedDocumentID = nil
        }
        library.delete(document)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = appState.selectedDocumentID,
           let document = library.document(id: id) {
            ReaderView(player: player, document: document)
        } else {
            WelcomeView(
                onImport: { showFileImporter = true },
                onWeb: { showWebSheet = true },
                onPaste: { showPasteSheet = true }
            )
        }
    }
}

// MARK: - Rows & empty states

struct DocumentRow: View {
    let document: Document
    let isSpeaking: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSpeaking ? "waveform" : document.sourceKind.symbolName)
                .foregroundStyle(isSpeaking ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(document.estimatedListeningLabel)
                    if document.progress > 0.01 && document.progress < 0.999 {
                        Text("· \(Int(document.progress * 100))%")
                    } else if document.progress >= 0.999 {
                        Text("· finished")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct EmptyLibraryHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Your library is empty")
                .font(.headline)
            Text("Add a PDF, web page, or pasted text with the + button.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct WelcomeView: View {
    var onImport: () -> Void
    var onWeb: () -> Void
    var onPaste: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Listen to anything")
                .font(.largeTitle.bold())
            Text("Turn PDFs, docs, web pages, and scans into natural-sounding audio —\nwith highlighting that follows along, at up to 4.5× speed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Import Files", systemImage: "doc.badge.plus", action: onImport)
                Button("Web Page", systemImage: "globe", action: onWeb)
                Button("Paste Text", systemImage: "doc.on.clipboard", action: onPaste)
            }
            .controlSize(.large)

            VStack(spacing: 6) {
                shortcutHint(keys: "⌥Z", text: "voice typing into any app")
                shortcutHint(keys: "⌥R", text: "read the text you've selected in any app")
            }
            .padding(.top, 12)
        }
        .padding(40)
    }

    private func shortcutHint(keys: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.callout.monospaced().bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Import sheets

struct PasteTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    var onSubmit: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Text")
                .font(.title2.bold())
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary, lineWidth: 1)
                )
            HStack {
                Button("Paste from Clipboard") {
                    if let clipboard = NSPasteboard.general.string(forType: .string) {
                        text = clipboard
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Library") {
                    onSubmit(title, text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct WebLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    var onSubmit: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Listen to a Web Page")
                .font(.title2.bold())
            Text("Speakit fetches the article and reads the main text aloud.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("https://example.com/article", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Fetch & Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func submit() {
        onSubmit(urlString)
        dismiss()
    }
}
