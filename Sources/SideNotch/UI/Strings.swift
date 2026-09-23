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
    static var measuringLimit: String { pick("내 한도 측정 중", "Working out your limit") }

    // Memory
    static var memory: String { pick("메모리", "Memory") }
    static var usedShort: String { pick("사용", "used") }
    static func pressure(_ p: MemoryPressure) -> String {
        switch p {
        case .normal:   return pick("메모리 압력 · 여유", "Memory pressure · normal")
        case .warning:  return pick("메모리 압력 · 주의", "Memory pressure · elevated")
        case .critical: return pick("메모리 압력 · 부족", "Memory pressure · critical")
        }
    }
    static func memoryBreakdown(app: String, wired: String, compressed: String) -> String {
        pick("앱 \(app) · 고정 \(wired) · 압축 \(compressed)",
             "App \(app) · wired \(wired) · compressed \(compressed)")
    }
    static func swap(_ amount: String) -> String {
        pick("스왑 \(amount)", "swap \(amount)")
    }
    static var confirmQuit: String { pick("종료", "Quit") }
    static var optimize: String { pick("최적화", "Free up") }
    static func optimizeConfirm(_ count: Int, _ amount: String) -> String {
        pick("\(count)개 종료 · \(amount) 확보", "Quit \(count) · free \(amount)")
    }
    static var nothingToFree: String { pick("정리할 앱 없음", "Nothing idle") }
    static func quitCount(_ count: Int) -> String {
        pick("\(count)개 앱 종료 요청함", "Asked \(count) apps to quit")
    }
    static var noWindows: String { pick("창 없음", "no windows") }
    static func idleFor(_ minutes: Int) -> String {
        minutes >= 60 ? pick("\(minutes / 60)시간 미사용", "idle \(minutes / 60)h")
                      : pick("\(minutes)분 미사용", "idle \(minutes)m")
    }
    static var optimizeHelp: String {
        pick("창이 없거나 30분 넘게 안 쓴 앱을 종료합니다. 한 번 더 눌러 확인",
             "Quits apps with no windows or unused for 30+ minutes. Click again to confirm")
    }
    static func quitApp(_ name: String) -> String {
        pick("\(name) 종료 — 한 번 더 눌러 확인", "Quit \(name) — click again to confirm")
    }

    // Where the denominator came from. The spend is always an estimate; this
    // says whether the limit it is measured against was observed or guessed.
    static func limitMeasured(_ amount: String, cutOffs: Int) -> String {
        pick("한도 \(amount) · 실측 (\(cutOffs)회)", "Limit \(amount) · measured (\(cutOffs)×)")
    }
    /// A lower bound, and said as one: nothing has been refused, so all that is
    /// known is that the account survives at least this much.
    static func limitInferred(_ amount: String) -> String {
        pick("한도 \(amount) 이상 · 중단 이력 없음", "Limit \(amount)+ · never cut off")
    }
    static func limitManual(_ amount: String) -> String {
        pick("한도 \(amount) · 직접 설정", "Limit \(amount) · set by you")
    }

    static func used(_ amount: String) -> String {
        pick("\(amount) 사용", "\(amount) used")
    }
    static func spent(_ cost: String, of budget: String) -> String {
        pick("\(cost) / \(budget) 사용", "\(cost) of \(budget) used")
    }
    static func claudeWindow(resetAt stamp: String) -> String {
        pick("5시간 창 · 초기화 \(stamp)", "5-hour window · resets \(stamp)")
    }
    static func limitWindow(_ label: String, resetAt stamp: String) -> String {
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
    static var monthly: String { pick("월간", "Monthly") }
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
    static func today(_ time: String) -> String { pick("오늘 \(time)", "today \(time)") }
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
