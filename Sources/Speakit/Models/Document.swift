import Foundation

/// A library item: metadata is kept in the library index, the extracted
/// text lives in its own file on disk (Application Support/Speakit/Documents).
struct Document: Identifiable, Codable, Hashable {

    enum SourceKind: String, Codable {
        case pdf
        case epub
        case document   // docx, rtf, odt…
        case plainText
        case web
        case scan       // OCR'd image
        case pasted

        var symbolName: String {
            switch self {
            case .pdf: return "doc.richtext"
            case .epub: return "book"
            case .document: return "doc.text"
            case .plainText: return "doc.plaintext"
            case .web: return "globe"
            case .scan: return "text.viewfinder"
            case .pasted: return "doc.on.clipboard"
            }
        }

        var label: String {
            switch self {
            case .pdf: return "PDF"
            case .epub: return "EPUB"
            case .document: return "Document"
            case .plainText: return "Text"
            case .web: return "Web Page"
            case .scan: return "Scan"
            case .pasted: return "Pasted Text"
            }
        }
    }

    let id: UUID
    var title: String
    var sourceKind: SourceKind
    var dateAdded: Date
    var wordCount: Int
    /// Character offset where the user last left off.
    var lastPosition: Int
    /// 0...1 fraction of the document already listened to.
    var progress: Double

    init(id: UUID = UUID(),
         title: String,
         sourceKind: SourceKind,
         dateAdded: Date = Date(),
         wordCount: Int = 0,
         lastPosition: Int = 0,
         progress: Double = 0) {
        self.id = id
        self.title = title
        self.sourceKind = sourceKind
        self.dateAdded = dateAdded
        self.wordCount = wordCount
        self.lastPosition = lastPosition
        self.progress = progress
    }

    /// Rough listening time at 1x (~180 wpm), e.g. "12 min".
    var estimatedListeningLabel: String {
        let minutes = max(1, Int((Double(wordCount) / 180.0).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}
