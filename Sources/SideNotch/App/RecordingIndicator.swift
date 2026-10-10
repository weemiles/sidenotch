import AppKit
import Combine

/// A menu bar item that exists only while Meetily is recording — a red dot
/// and "녹음 중" next to the clock, so a recording left running is hard to miss.
@MainActor
final class RecordingIndicator: NSObject {
    private let recorder: MeetilyRecorder
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?

    init(recorder: MeetilyRecorder) {
        self.recorder = recorder
        super.init()
        subscription = recorder.$status
            .removeDuplicates()
            .sink { [weak self] status in self?.update(status) }
    }

    private func update(_ status: MeetilyRecorder.Status) {
        switch status {
        case .recording: show(title: L.recordingNow, color: .systemRed)
        case .paused:    show(title: L.recordingPaused, color: .systemOrange)
        default:         hide()
        }
    }

    private func show(title: String, color: NSColor) {
        let item = self.item ?? makeItem()
        guard let button = item.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(.init(paletteColors: [color]))
        let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        dot?.isTemplate = false
        button.image = dot
        button.imagePosition = .imageLeading
        button.title = " " + title
    }

    private func hide() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: L.stopRecording, action: #selector(stop), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: L.openMeetily, action: #selector(openMeetily), keyEquivalent: "")
            .target = self
        item.menu = menu
        self.item = item
        return item
    }

    // A menu rather than a bare click: one stray click must not end a meeting.
    @objc private func stop() {
        if recorder.status == .recording || recorder.status == .paused { recorder.toggle() }
    }

    @objc private func openMeetily() { recorder.openApp() }
}
