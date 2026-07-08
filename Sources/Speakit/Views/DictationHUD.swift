import AppKit
import SwiftUI

/// A small floating, non-activating panel shown while voice typing is
/// active, so the user can see the live transcript without leaving the
/// app they're dictating into.
final class DictationHUDController {

    private var panel: NSPanel?

    func show(service: DictationService) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: DictationHUDView(service: service))
            self.panel = panel
        }
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 80
        )
        panel.setFrameOrigin(origin)
    }
}

struct DictationHUDView: View {
    @ObservedObject var service: DictationService

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, isActive: service.isRecording)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.isRecording ? "Listening… press ⌥Z to finish" : "Processing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(service.liveTranscript.isEmpty ? "Speak naturally" : service.liveTranscript)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                service.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel dictation")
        }
        .padding(14)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
