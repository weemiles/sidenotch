import AppKit
import ApplicationServices
import CoreAudio

/// Shows Meetily's recording state in the notch and menu bar, and opens it.
///
/// Meetily has no URL scheme, CLI or global shortcut — only its menu bar
/// menu. So this reads and presses that menu through Accessibility. The menu
/// is readable while closed, and its titles ("Start Recording" vs "Stop
/// Recording") tell whether it is recording. Without Accessibility, Meetily
/// holding the microphone open still says it is recording.
@MainActor
final class MeetilyRecorder: ObservableObject {
    enum Status: Equatable {
        case notRunning
        /// Accessibility is not granted and the microphone is idle.
        case noPermission
        case idle
        /// Meetily is running but its menu does not offer Start right now —
        /// no transcription model yet, or still stopping.
        case busy
        case recording
        case paused
    }

    /// One reader for the notch button and the menu bar indicator, so they
    /// never disagree and Meetily's menu is only polled once.
    static let shared = MeetilyRecorder()
    nonisolated static let bundleID = "com.meetily.ai"
    nonisolated static let isInstalled: Bool =
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil

    @Published private(set) var status: Status = .notRunning
    private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard let app = runningApp else { status = .notRunning; return }
        guard AXIsProcessTrusted() else {
            status = Self.isCapturingInput(pid: app.processIdentifier) ? .recording : .noPermission
            return
        }
        let items = menuItems(of: app)
        if find("Stop Recording", in: items) != nil {
            status = find("Resume Recording", in: items) != nil ? .paused : .recording
        } else if let start = find("Start Recording", in: items), isEnabled(start) {
            status = .idle
        } else {
            status = .busy
        }
    }

    func toggle() {
        if status != .notRunning, !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            return
        }
        switch status {
        case .notRunning:
            openApp()
        case .noPermission, .busy:
            break
        case .idle:
            press("Start Recording")
        case .recording, .paused:
            press("Stop Recording")
        }
        // The menu is rebuilt asynchronously after a press.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
    }

    /// Brings Meetily's window forward. Activating alone does not reopen a
    /// window that was closed to the tray, so its "Open Main Window" item is
    /// pressed first when Accessibility allows it.
    func openApp() {
        if runningApp != nil, AXIsProcessTrusted() {
            press("Open Main Window")
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) {
            AppLauncher.open(url)
        }
    }

    // MARK: Microphone

    /// Whether Core Audio has an input stream running for this process. Needs
    /// no permission, unlike reading Meetily's menu.
    private static func isCapturingInput(pid: pid_t) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var list = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &ids) == noErr else { return false }
        return ids.contains { id in
            uint32(id, kAudioProcessPropertyPID) == UInt32(bitPattern: pid)
                && uint32(id, kAudioProcessPropertyIsRunningInput) == 1
        }
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Accessibility

    private var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
            .first { !$0.isTerminated }
    }

    private func press(_ title: String) {
        guard let app = runningApp,
              let item = find(title, in: menuItems(of: app)) else { return }
        if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return }
        // Some status menus only act once they are open.
        guard let barItem = statusItem(of: app) else { return }
        AXUIElementPerformAction(barItem, kAXPressAction as CFString)
        if let item = find(title, in: menuItems(of: app)) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
    }

    private func statusItem(of app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // A hung Meetily must not stall the notch for the default six seconds.
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let bar: AXUIElement = attribute(root, "AXExtrasMenuBar") else { return nil }
        return children(of: bar).first
    }

    private func menuItems(of app: NSRunningApplication) -> [AXUIElement] {
        guard let barItem = statusItem(of: app) else { return [] }
        return children(of: barItem).flatMap(children(of:))
    }

    /// Titles carry an emoji prefix ("⏹ Stop Recording"), so match the words.
    private func find(_ title: String, in items: [AXUIElement]) -> AXUIElement? {
        items.first { (attribute($0, kAXTitleAttribute) as String?)?.contains(title) == true }
    }

    private func isEnabled(_ item: AXUIElement) -> Bool {
        (attribute(item, kAXEnabledAttribute) as Bool?) ?? true
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? T
    }
}
