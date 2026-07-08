import Foundation
import AppKit
import PDFKit
import Vision
import UniformTypeIdentifiers

struct ExtractedDocument {
    var title: String
    var text: String
    var sourceKind: Document.SourceKind
}

enum TextExtractorError: LocalizedError {
    case unreadable(String)
    case emptyDocument
    case badURL

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "Could not read this file: \(detail)"
        case .emptyDocument: return "No readable text was found in this document."
        case .badURL: return "That doesn't look like a valid web address."
        }
    }
}

/// Extracts plain, speakable text from every content type Speakit supports:
/// PDF, DOCX, RTF, EPUB, HTML, Markdown, plain text, web pages, and
/// images (via Vision OCR).
enum TextExtractor {

    // MARK: - Files

    @MainActor
    static func extract(from url: URL) async throws -> ExtractedDocument {
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent

        switch ext {
        case "pdf":
            return ExtractedDocument(title: title, text: try extractPDF(url), sourceKind: .pdf)
        case "txt", "md", "markdown", "text":
            let text = try String(contentsOf: url, encoding: .utf8)
            return try validated(title: title, text: text, kind: .plainText)
        case "rtf", "rtfd", "docx", "doc", "odt":
            return try validated(title: title, text: try extractAttributed(url), kind: .document)
        case "html", "htm", "xhtml":
            return try validated(title: title, text: try extractAttributed(url), kind: .web)
        case "epub":
            return try validated(title: title, text: try extractEPUB(url), kind: .epub)
        case "png", "jpg", "jpeg", "tiff", "tif", "heic", "gif", "bmp", "webp":
            return try validated(title: title, text: try recognizeText(inImageAt: url), kind: .scan)
        default:
            // Last resort: try plain text decoding.
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return try validated(title: title, text: text, kind: .plainText)
            }
            throw TextExtractorError.unreadable("Unsupported file type “.\(ext)”.")
        }
    }

    private static func validated(title: String, text: String, kind: Document.SourceKind) throws -> ExtractedDocument {
        let cleaned = normalize(text)
        guard !cleaned.isEmpty else { throw TextExtractorError.emptyDocument }
        return ExtractedDocument(title: title, text: cleaned, sourceKind: kind)
    }

    // MARK: - PDF

    private static func extractPDF(_ url: URL) throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw TextExtractorError.unreadable("The PDF could not be opened.")
        }
        var pages: [String] = []
        for i in 0..<pdf.pageCount {
            if let text = pdf.page(at: i)?.string {
                pages.append(text)
            }
        }
        let joined = normalize(pages.joined(separator: "\n\n"))
        guard !joined.isEmpty else {
            throw TextExtractorError.unreadable("This PDF has no embedded text — it may be a scan. Try importing page images instead, and Speakit will OCR them.")
        }
        return joined
    }

    // MARK: - Rich documents (DOCX, RTF, HTML files, ODT)

    /// AppKit's NSAttributedString importer natively reads .docx, .rtf,
    /// .odt, and .html files.
    private static func extractAttributed(_ url: URL) throws -> String {
        let attributed = try NSAttributedString(
            url: url,
            options: [:],
            documentAttributes: nil
        )
        return attributed.string
    }

    // MARK: - EPUB

    /// EPUBs are zip archives of XHTML chapters. We unzip with the system
    /// unzip tool and concatenate the chapter text in path order.
    private static func extractEPUB(_ url: URL) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakit-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TextExtractorError.unreadable("The EPUB archive could not be unpacked.")
        }

        var chapterURLs: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ext == "xhtml" || ext == "html" || ext == "htm" {
                    chapterURLs.append(fileURL)
                }
            }
        }
        chapterURLs.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var chapters: [String] = []
        for chapterURL in chapterURLs {
            if let data = try? Data(contentsOf: chapterURL) {
                chapters.append(plainText(fromHTMLData: data))
            }
        }
        let joined = normalize(chapters.joined(separator: "\n\n"))
        guard !joined.isEmpty else { throw TextExtractorError.emptyDocument }
        return joined
    }

    // MARK: - Web pages

    @MainActor
    static func extractWebPage(from urlString: String) async throws -> ExtractedDocument {
        var candidate = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.lowercased().hasPrefix("http") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), url.host != nil else {
            throw TextExtractorError.badURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let rawHTML = String(data: data, encoding: .utf8) ?? ""
        let title = htmlTitle(in: rawHTML) ?? url.host ?? "Web Page"

        let text = plainText(fromHTMLData: stripNonContent(rawHTML).data(using: .utf8) ?? data)
        let cleaned = normalize(text)
        guard !cleaned.isEmpty else { throw TextExtractorError.emptyDocument }
        return ExtractedDocument(title: title, text: cleaned, sourceKind: .web)
    }

    private static func htmlTitle(in html: String) -> String? {
        guard let match = html.range(of: "<title[^>]*>([^<]*)</title>",
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        let tag = String(html[match])
        let inner = tag
            .replacingOccurrences(of: "<title[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</title>", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// Drops scripts, styles, and common chrome (nav/footer/aside) so the
    /// spoken article is mostly body content.
    private static func stripNonContent(_ html: String) -> String {
        var result = html
        for tag in ["script", "style", "noscript", "nav", "footer", "aside", "header", "form", "svg"] {
            result = result.replacingOccurrences(
                of: "<\(tag)[\\s\\S]*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = result.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        return result
    }

    /// Uses AppKit's HTML importer (must run on the main thread) to convert
    /// HTML to plain text with entities resolved.
    private static func plainText(fromHTMLData data: Data) -> String {
        let convert: () -> String = {
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
            if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
                return attributed.string
            }
            return ""
        }
        if Thread.isMainThread {
            return convert()
        }
        return DispatchQueue.main.sync(execute: convert)
    }

    // MARK: - OCR (Vision)

    /// Recognizes printed text in an image, mirroring Speechify's
    /// scan-to-listen feature.
    static func recognizeText(inImageAt url: URL) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: url, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: - Cleanup

    /// Collapses excessive whitespace while preserving paragraph breaks.
    static func normalize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " ?\n ?", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
