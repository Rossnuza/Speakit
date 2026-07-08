import Foundation

/// Persists the user's listening library. Document metadata is stored as
/// JSON; each document's extracted text is a UTF-8 file keyed by its id.
final class LibraryStore: ObservableObject {

    @Published private(set) var documents: [Document] = []

    private let fileManager = FileManager.default

    private var rootDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Speakit", isDirectory: true)
    }

    private var documentsDirectory: URL {
        rootDirectory.appendingPathComponent("Documents", isDirectory: true)
    }

    private var indexURL: URL {
        rootDirectory.appendingPathComponent("library.json")
    }

    init() {
        try? fileManager.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - CRUD

    @discardableResult
    func add(title: String, text: String, sourceKind: Document.SourceKind) -> Document {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let document = Document(title: title, sourceKind: sourceKind, wordCount: words)
        do {
            try text.write(to: textURL(for: document.id), atomically: true, encoding: .utf8)
        } catch {
            NSLog("Speakit: failed to store document text: \(error.localizedDescription)")
        }
        documents.insert(document, at: 0)
        saveIndex()
        return document
    }

    func document(id: UUID) -> Document? {
        documents.first { $0.id == id }
    }

    func text(for id: UUID) -> String? {
        try? String(contentsOf: textURL(for: id), encoding: .utf8)
    }

    func delete(_ document: Document) {
        documents.removeAll { $0.id == document.id }
        try? fileManager.removeItem(at: textURL(for: document.id))
        saveIndex()
    }

    func rename(_ document: Document, to newTitle: String) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        documents[index].title = trimmed
        saveIndex()
    }

    /// Records where playback stopped so the document resumes there later.
    func updatePosition(documentID: UUID, characterOffset: Int) {
        guard let index = documents.firstIndex(where: { $0.id == documentID }) else { return }
        documents[index].lastPosition = characterOffset
        if let text = text(for: documentID), !text.isEmpty {
            let length = (text as NSString).length
            documents[index].progress = min(1.0, Double(characterOffset) / Double(length))
        }
        saveIndex()
    }

    // MARK: - Persistence

    private func textURL(for id: UUID) -> URL {
        documentsDirectory.appendingPathComponent("\(id.uuidString).txt")
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        if let decoded = try? JSONDecoder().decode([Document].self, from: data) {
            documents = decoded
        }
    }

    private func saveIndex() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(documents)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("Speakit: failed to save library index: \(error.localizedDescription)")
        }
    }
}
