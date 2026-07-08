import SwiftUI
import AppKit

/// A read-only text view that paints Speechify-style synchronized
/// highlights: a soft wash over the sentence being spoken and a stronger
/// pill over the current word, auto-scrolling to keep them visible.
/// Clicking a paragraph jumps playback there.
struct HighlightingTextView: NSViewRepresentable {

    let text: String
    let wordRange: NSRange?
    let sentenceRange: NSRange?
    let fontSize: Double
    var onSeek: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onSeek: onSeek)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ClickableTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 32, height: 28)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        let coordinator = context.coordinator
        textView.onDoubleClickCharacterIndex = { index in
            coordinator.onSeek?(index)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ClickableTextView,
              let storage = textView.textStorage else { return }

        let coordinator = context.coordinator
        coordinator.onSeek = onSeek

        if coordinator.renderedText != text || coordinator.renderedFontSize != fontSize {
            storage.setAttributedString(Self.baseAttributedString(for: text, fontSize: fontSize))
            coordinator.renderedText = text
            coordinator.renderedFontSize = fontSize
            coordinator.lastSentenceRange = nil
            coordinator.lastWordRange = nil
        }

        let textLength = storage.length

        // Clear previous highlights.
        if let previous = coordinator.lastSentenceRange, previous.upperBound <= textLength {
            storage.removeAttribute(.backgroundColor, range: previous)
        }
        if let previous = coordinator.lastWordRange, previous.upperBound <= textLength {
            storage.removeAttribute(.backgroundColor, range: previous)
        }

        // Paint sentence wash, then the stronger word highlight on top.
        if let sentence = sentenceRange, sentence.upperBound <= textLength {
            storage.addAttribute(.backgroundColor,
                                 value: NSColor.systemYellow.withAlphaComponent(0.18),
                                 range: sentence)
            coordinator.lastSentenceRange = sentence
        } else {
            coordinator.lastSentenceRange = nil
        }

        if let word = wordRange, word.upperBound <= textLength {
            storage.addAttribute(.backgroundColor,
                                 value: NSColor.systemYellow.withAlphaComponent(0.55),
                                 range: word)
            coordinator.lastWordRange = word
            textView.scrollRangeToVisible(word)
        } else {
            coordinator.lastWordRange = nil
        }
    }

    static func baseAttributedString(for text: String, fontSize: Double) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.35
        paragraph.paragraphSpacing = 10
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    final class Coordinator {
        var renderedText: String = ""
        var renderedFontSize: Double = 0
        var lastWordRange: NSRange?
        var lastSentenceRange: NSRange?
        var onSeek: ((Int) -> Void)?

        init(onSeek: ((Int) -> Void)?) {
            self.onSeek = onSeek
        }
    }
}

/// NSTextView subclass that reports double-clicks as character offsets,
/// used for click-to-jump playback.
final class ClickableTextView: NSTextView {

    var onDoubleClickCharacterIndex: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClickCharacterIndex {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if index >= 0, index <= (string as NSString).length {
                onDoubleClickCharacterIndex(index)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
