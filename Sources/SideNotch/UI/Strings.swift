import Foundation

/// Korean and English, chosen from the system language. Small enough that a
/// `.lproj` bundle would cost more than it saves, and keeping the pairs side by
/// side makes it obvious when one of them is missing.
///
/// `SIDENOTCH_LANG=en` (or `ko`) overrides, which is how the screenshots in the
/// README get taken in either language.
enum L {
    static let isKorean: Bool = {
        if let forced = ProcessInfo.processInfo.environment["SIDENOTCH_LANG"] {
            return forced.lowercased().hasPrefix("ko")
        }
        return Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
    }()

    private static func pick(_ ko: String, _ en: String) -> String { isKorean ? ko : en }

    // Panel
    static var estimate: String { pick("추정", "estimate") }
    static var left: String { pick("남음", "left") }
    static var noActiveWindow: String { pick("활성 5시간 창 없음", "No active 5-hour window") }
    static var noCodexSession: String { pick("최근 Codex 세션 없음", "No recent Codex session") }

    static func used(_ amount: String) -> String {
        pick("\(amount) 사용", "\(amount) used")
    }
    static func spent(_ cost: String, of budget: String) -> String {
        pick("\(cost) / \(budget) 사용", "\(cost) of \(budget) used")
    }
    static func claudeWindow(resetAt stamp: String) -> String {
        pick("5시간 창 · 초기화 \(stamp)", "5-hour window · resets \(stamp)")
    }
    static func codexWindow(_ label: String, resetAt stamp: String) -> String {
        pick("\(label) 한도 · 초기화 \(stamp)", "\(label) limit · resets \(stamp)")
    }
    static func inTime(_ duration: String) -> String {
        pick("\(duration) 후", "in \(duration)")
    }
    static func secondaryLeft(_ label: String, _ percent: String) -> String {
        pick("\(label) \(percent) 남음", "\(label) \(percent) left")
    }

    // Windows and durations
    static var weekly: String { pick("주간", "Weekly") }
    static func hours(_ n: Int) -> String { pick("\(n)시간", "\(n)h") }
    static func minutes(_ n: Int) -> String { pick("\(n)분", "\(n)m") }
    static func days(_ d: Int, _ h: Int) -> String { pick("\(d)일 \(h)시간", "\(d)d \(h)h") }
    static func hoursMinutes(_ h: Int, _ m: Int) -> String { pick("\(h)시간 \(m)분", "\(h)h \(m)m") }
    static var soon: String { pick("곧", "now") }
    static var justNow: String { pick("방금", "just now") }
    static func secondsAgo(_ n: Int) -> String { pick("\(n)초 전", "\(n)s ago") }
    static func minutesAgo(_ n: Int) -> String { pick("\(n)분 전", "\(n)m ago") }
    static func hoursAgo(_ n: Int) -> String { pick("\(n)시간 전", "\(n)h ago") }

    /// Weekday in the reset stamp is what makes a date five days out legible.
    static var dateFormat: String { pick("M/d(E) HH:mm", "MMM d (E) HH:mm") }
    static var localeIdentifier: String { pick("ko_KR", "en_US") }

    // Menu bar
    static var refreshNow: String { pick("지금 새로고침", "Refresh Now") }
    static var moveToCursorScreen: String {
        pick("커서가 있는 화면으로 옮기기", "Move to Display with Cursor")
    }
    static var openSettings: String { pick("설정 파일 열기", "Open Settings File") }
    static var reloadSettings: String { pick("설정 다시 읽기", "Reload Settings") }
    static var launchAtLogin: String { pick("로그인 시 자동 실행", "Launch at Login") }
    static var quit: String { pick("SideNotch 종료", "Quit SideNotch") }
}
