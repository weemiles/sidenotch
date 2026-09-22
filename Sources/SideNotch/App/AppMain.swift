import AppKit
import Darwin

@main
@MainActor
struct SideNotchApp {
    static func main() {
        guard acquireSingleInstanceLock() else {
            // A second copy stacks a second island on screen at a slightly
            // different size, which reads as the shape being misaligned.
            FileHandle.standardError.write(Data("SideNotch is already running.\n".utf8))
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate               // NSApplication holds this weakly
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    /// Held for the lifetime of the process; the kernel drops it on exit, so a
    /// crash cannot leave a stale lock behind.
    private static func acquireSingleInstanceLock() -> Bool {
        let path = Config.url.deletingLastPathComponent().appendingPathComponent("run.lock")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(path.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }    // cannot lock: better to run than not
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}
