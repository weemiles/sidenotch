import Foundation

/// How hard the system is working to keep memory free — the same signal
/// Activity Monitor colours its pressure graph with. A full-looking RAM figure
/// is normal on macOS; pressure is what says whether it is actually a problem.
enum MemoryPressure: Equatable {
    case normal, warning, critical
}

struct MemoryUsage: Equatable {
    var total: UInt64 = 0
    /// Activity Monitor's "App Memory": anonymous pages minus what can be purged.
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal
    /// Biggest apps first.
    var hogs: [MemoryHog] = []

    /// Activity Monitor's "Memory Used". Cached files are left out: the system
    /// hands those back the moment anything asks.
    var used: UInt64 { app + wired + compressed }
    var usedFraction: Double {
        total > 0 ? min(1, Double(used) / Double(total)) : 0
    }
    var available: Bool { total > 0 }
}

/// Reads the kernel's VM counters. A few syscalls, so it rides the fast poll.
enum MemoryReader {
    /// `mach_host_self()` hands out a new send right on every call; asking once
    /// keeps a two-second poll from leaking ports.
    private static let host = mach_host_self()

    static func read() -> MemoryUsage {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemoryUsage() }

        let page = UInt64(vm_kernel_page_size)
        var usage = MemoryUsage()
        usage.total = ProcessInfo.processInfo.physicalMemory
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        usage.app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
        usage.wired = UInt64(stats.wire_count) * page
        usage.compressed = UInt64(stats.compressor_page_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            usage.swapUsed = swap.xsu_used
        }

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            switch level {
            case 4:  usage.pressure = .critical
            case 2:  usage.pressure = .warning
            default: usage.pressure = .normal
            }
        }
        usage.hogs = hogs(limit: 8)
        return usage
    }
}

/// One app's share of memory, helpers included: a browser is dozens of
/// processes, and listing them one by one would say nothing about the browser.
struct MemoryHog: Equatable, Identifiable {
    /// The outermost `.app` bundle, or the executable name for anything else.
    var id: String
    var name: String
    /// What the icon is drawn from.
    var iconPath: String
    /// Set when the group is an app, which can be asked to quit properly.
    var bundlePath: String?
    var pids: [pid_t]
    var bytes: UInt64
    /// Of everything this user's processes hold. Footprints count swapped and
    /// compressed pages too, so against physical RAM one app alone can pass
    /// most of it — a share of the whole is the figure that adds up.
    var share: Double = 0
}

extension MemoryReader {
    /// Largest consumers by footprint, the figure Activity Monitor's Memory
    /// column shows. Only this user's processes can be read without root, which
    /// is also exactly the set that can be quit from here.
    static func hogs(limit: Int) -> [MemoryHog] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }

        let me = getpid()
        var groups: [String: MemoryHog] = [:]
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

        for pid in pids.prefix(count) where pid > 1 && pid != me {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0, info.ri_phys_footprint > 0 else { continue }
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            let path = String(cString: pathBuffer)

            let bundle = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
            let key = bundle ?? displayName(executable: path)
            if groups[key] == nil {
                let name = bundle.map { (($0 as NSString).lastPathComponent as NSString)
                    .deletingPathExtension } ?? key
                groups[key] = MemoryHog(id: key, name: name, iconPath: bundle ?? path,
                                        bundlePath: bundle, pids: [], bytes: 0)
            }
            groups[key]?.pids.append(pid)
            groups[key]?.bytes += info.ri_phys_footprint
        }
        let whole = groups.values.reduce(0) { $0 + $1.bytes }
        return groups.values.sorted { $0.bytes > $1.bytes }.prefix(limit).map {
            var hog = $0
            hog.share = whole > 0 ? Double(hog.bytes) / Double(whole) : 0
            return hog
        }
    }

    /// A self-updating CLI is often installed as `…/claude/versions/2.1.280`,
    /// so the file name is a version. The first folder above it that is not
    /// one is the tool's name.
    private static func displayName(executable path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        while let last = parts.last,
              last == "versions" || last.allSatisfy({ $0.isNumber || $0 == "." }) {
            parts.removeLast()
        }
        let name = parts.last ?? (path as NSString).lastPathComponent
        return name.hasPrefix("com.apple.") ? String(name.dropFirst(10)) : name
    }
}
