// OllamaUsage — macOS menu bar widget for Ollama Cloud legacy-plan usage.
// Data: https://ollama.com/api/balance (session/weekly remaining_percent + resets_at).
// Requires OLLAMA_API_KEY in the environment. Poll interval via
// `defaults write menubar.ollama-usage intervalSeconds <n>` (default 300),
// or env OLLAMA_USAGE_INTERVAL. Settings live in the same `defaults` suite.

import AppKit
import ServiceManagement

// MARK: - API model

struct BalanceResponse: Decodable {
    let included: Included?
    struct Included: Decodable {
        let session: Limit?
        let weekly: Limit?
        let balance_usd: Double?
        struct Limit: Decodable {
            let remaining_percent: Double
            let resets_at: String
        }
    }
}

struct APIError: Error {
    let kind: String
    let retryAfter: TimeInterval?
}

// MARK: - Display items

enum DisplayItem: String, CaseIterable {
    case sessionUsage = "session_usage"
    case sessionReset = "session_reset"
    case weeklyUsage = "weekly_usage"
    case weeklyReset = "weekly_reset"

    var label: String {
        switch self {
        case .sessionUsage: "Session Usage"
        case .sessionReset: "Session Reset Time"
        case .weeklyUsage: "Weekly Usage"
        case .weeklyReset: "Weekly Reset Time"
        }
    }

    var isSession: Bool {
        self == .sessionUsage || self == .sessionReset
    }

    var isUsage: Bool {
        self == .sessionUsage || self == .weeklyUsage
    }
}

/// Color by percent REMAINING (only usage items are tinted).
func color(forRemaining pct: Double) -> NSColor {
    if pct >= 50 {
        return .systemGreen
    }
    if pct >= 20 {
        return .systemOrange
    }
    if pct >= 10 {
        return .systemPink
    }
    return .systemRed
}

func makeSegment(_ item: DisplayItem, remaining: Double, countdownText: String) -> String {
    switch item {
    case .sessionUsage: "S \(Int(remaining.rounded()))%"
    case .sessionReset: "S \(countdownText)"
    case .weeklyUsage: "W \(Int(remaining.rounded()))%"
    case .weeklyReset: "W \(countdownText)"
    }
}

// MARK: - State

final class State {
    var session: BalanceResponse.Included.Limit?
    var weekly: BalanceResponse.Included.Limit?
    var lastUpdated: Date?
    var consecutiveFailures = 0
    var errorKind: String?

    var titleText: String {
        if let k = errorKind, session == nil && weekly == nil {
            return "⚠︎ \(k)"
        }
        guard let s = session, let w = weekly else { return "⚠︎ no usage data" }
        let text: (DisplayItem) -> String = { item in
            makeSegment(item, remaining: item.isSession ? s.remaining_percent : w.remaining_percent,
                        countdownText: countdown(from: item.isSession ? s.resets_at : w.resets_at))
        }
        return defaultItems.map { text($0) }.joined(separator: " | ")
    }
}

let defaultItems: [DisplayItem] = [.sessionUsage, .sessionReset]

// MARK: - Settings

let settingsDefaults = UserDefaults.standard

func colorEnabled() -> Bool {
    settingsDefaults.object(forKey: "colors") == nil ? true : settingsDefaults.bool(forKey: "colors")
}

func setColorEnabled(_ on: Bool) {
    settingsDefaults.set(on, forKey: "colors")
}

func visibleItems() -> [DisplayItem] {
    let raw = settingsDefaults.stringArray(forKey: "items") ?? defaultItems.map(\.rawValue)
    let all = Set(DisplayItem.allCases)
    let items = raw.compactMap(DisplayItem.init(rawValue:)).filter { all.contains($0) }
    return items.isEmpty ? defaultItems : items
}

func setVisibleItems(_ items: [DisplayItem]) {
    settingsDefaults.set(items.map(\.rawValue), forKey: "items")
}

// MARK: - Countdown (self-tested)

func countdown(from resetsAt: String, now: Date = Date()) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var target = f.date(from: resetsAt)
    if target == nil {
        f.formatOptions = [.withInternetDateTime]
        target = f.date(from: resetsAt)
    }
    guard let target, target > now else { return "resetting…" }
    let secs = Int(target.timeIntervalSince(now))
    let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
    if d > 0 {
        return "\(d)d \(h)h"
    }
    if h > 0 {
        return "\(h)h \(m)m"
    }
    return "\(m)m"
}

// MARK: - Polling

func fetchBalance(apiKey: String, completion: @escaping (Result<BalanceResponse, APIError>) -> Void) {
    var req = URLRequest(url: URL(string: "https://ollama.com/api/balance")!)
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 15
    URLSession.shared.dataTask(with: req) { data, resp, err in
        if let http = resp as? HTTPURLResponse {
            switch http.statusCode {
            case 200:
                guard let data else {
                    completion(.failure(APIError(kind: "empty", retryAfter: nil)))
                    return
                }
                do {
                    try completion(.success(JSONDecoder().decode(BalanceResponse.self, from: data)))
                } catch {
                    completion(.failure(APIError(kind: "parse", retryAfter: nil)))
                }
            case 401, 403:
                completion(.failure(APIError(kind: "auth", retryAfter: nil)))
            case 429:
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                completion(.failure(APIError(kind: "rate-limited", retryAfter: retry)))
            default:
                completion(.failure(APIError(kind: "http \(http.statusCode)", retryAfter: nil)))
            }
        } else if let err {
            completion(.failure(APIError(kind: err.localizedDescription, retryAfter: nil)))
        } else {
            completion(.failure(APIError(kind: "network", retryAfter: nil)))
        }
    }.resume()
}

// MARK: - Self-test

func selfTest() {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime]
    let now = fmt.date(from: "2026-11-23T12:00:00Z")!

    assert(countdown(from: "2026-11-23T12:45:00Z", now: now) == "45m")
    assert(countdown(from: "2026-11-23T13:45:00Z", now: now) == "1h 45m")
    assert(countdown(from: "2026-11-25T01:30:00Z", now: now) == "1d 13h")
    assert(countdown(from: "2026-11-23T11:00:00Z", now: now) == "resetting…")
    assert(countdown(from: "2026-11-23T12:45:00.000Z", now: now) == "45m")

    // Segment titles for all four item types.
    assert(makeSegment(.sessionUsage, remaining: 89.85, countdownText: "1h 12m") == "S 90%")
    assert(makeSegment(.sessionReset, remaining: 90, countdownText: "1h 12m") == "S 1h 12m")
    assert(makeSegment(.weeklyUsage, remaining: 50.75, countdownText: "3d 5h") == "W 51%")
    assert(makeSegment(.weeklyReset, remaining: 51, countdownText: "3d 5h") == "W 3d 5h")

    // Color thresholds on percent remaining.
    assert(color(forRemaining: 100) == .systemGreen)
    assert(color(forRemaining: 50) == .systemGreen)
    assert(color(forRemaining: 49.9) == .systemOrange)
    assert(color(forRemaining: 20) == .systemOrange)
    assert(color(forRemaining: 19.9) == .systemPink)
    assert(color(forRemaining: 10) == .systemPink)
    assert(color(forRemaining: 9.9) == .systemRed)

    // Error / missing-data titles.
    let st = State()
    assert(st.titleText == "⚠︎ no usage data")
    st.errorKind = "auth"
    assert(st.titleText == "⚠︎ auth")

    settingsDefaults.removeObject(forKey: "items")
    assert(visibleItems() == defaultItems)
    setVisibleItems([.weeklyReset, .sessionUsage])
    assert(visibleItems() == [.weeklyReset, .sessionUsage])
    settingsDefaults.removeObject(forKey: "items")

    print("self-test OK")
    exit(0)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = State()
    var statusItem: NSStatusItem!
    var timer: Timer?
    var pollRetryWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "ollama-use"
        buildMenu()
        render()
        poll()
        restartTimer()
    }

    // Interval: menu (60m max), `defaults write menubar.ollama-usage
    // intervalSeconds <n>` (default 300), or env OLLAMA_USAGE_INTERVAL.
    // Clamped to 30s…3600s for the API rate limit.
    func intervalSeconds() -> TimeInterval {
        if let env = ProcessInfo.processInfo.environment["OLLAMA_USAGE_INTERVAL"], let t = TimeInterval(env) {
            return min(3600, max(30, t))
        }
        return min(3600, max(30, TimeInterval(settingsDefaults.integer(forKey: "intervalSeconds") == 0 ? 300 : settingsDefaults.integer(forKey: "intervalSeconds"))))
    }

    func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds(), repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func poll() {
        pollRetryWorkItem?.cancel()
        guard let key = ProcessInfo.processInfo.environment["OLLAMA_API_KEY"], !key.isEmpty else {
            state.errorKind = "no API key"
            state.session = nil
            state.weekly = nil
            render()
            return
        }
        fetchBalance(apiKey: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(resp):
                    self.state.session = resp.included?.session
                    self.state.weekly = resp.included?.weekly
                    self.state.lastUpdated = Date()
                    self.state.consecutiveFailures = 0
                    self.state.errorKind = nil
                    self.render()
                case let .failure(e):
                    self.state.consecutiveFailures += 1
                    if self.state.consecutiveFailures >= 2 || self.state.session == nil {
                        self.state.errorKind = e.kind
                        self.render()
                    }
                    if let retry = e.retryAfter {
                        let work = DispatchWorkItem { [weak self] in self?.poll() }
                        self.pollRetryWorkItem = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + retry, execute: work)
                    }
                }
            }
        }
    }

    // MARK: Rendering

    /// (text, optional tint) segments for the status bar title.
    func segments() -> [(String, NSColor?)] {
        var segs: [(String, NSColor?)] = []
        if let k = state.errorKind, state.session == nil, state.weekly == nil {
            return [("⚠︎ \(k)", NSColor.systemYellow)]
        }
        for item in visibleItems() {
            if item.isSession, let s = state.session {
                segs.append(item.isUsage
                    ? ("S \(Int(s.remaining_percent.rounded()))%", colorEnabled() ? color(forRemaining: s.remaining_percent) : nil)
                    : ("S \(countdown(from: s.resets_at))", nil))
            } else if !item.isSession, let w = state.weekly {
                segs.append(item.isUsage
                    ? ("W \(Int(w.remaining_percent.rounded()))%", colorEnabled() ? color(forRemaining: w.remaining_percent) : nil)
                    : ("W \(countdown(from: w.resets_at))", nil))
            }
        }
        if segs.isEmpty {
            return [("⚠︎ no usage data", NSColor.systemYellow)]
        }
        return segs
    }

    func render() {
        guard let button = statusItem.button else { return }
        let segs = segments()
        let font = NSFont.menuBarFont(ofSize: 0)
        let attr = NSMutableAttributedString()
        for (i, (text, tint)) in segs.enumerated() {
            if i > 0 {
                attr.append(NSAttributedString(string: " | ", attributes: [.font: font]))
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if let tint {
                attrs[.foregroundColor] = tint
            }
            attr.append(NSAttributedString(string: text, attributes: attrs))
        }
        button.attributedTitle = attr
        buildMenu()
    }

    // MARK: Menu

    func buildMenu() {
        let menu = NSMenu()

        for item in visibleItems().sorted(by: { $0.rawValue < $1.rawValue }) {
            if item.isSession, let s = state.session {
                menu.addItem(infoItem("\(item.label): \(Int(s.remaining_percent.rounded()))% left — resets in \(countdown(from: s.resets_at))"))
            } else if !item.isSession, let w = state.weekly {
                menu.addItem(infoItem("\(item.label): \(Int(w.remaining_percent.rounded()))% left — resets in \(countdown(from: w.resets_at))"))
            }
        }
        if let updated = state.lastUpdated {
            let df = DateFormatter()
            df.dateStyle = .none
            df.timeStyle = .short
            menu.addItem(infoItem("Updated \(df.string(from: updated))"))
        }
        if let err = state.errorKind, state.session == nil, state.weekly == nil {
            menu.addItem(infoItem("⚠︎ \(err)"))
        }

        menu.addItem(.separator())

        // Settings
        let colors = NSMenuItem(title: "Show Colors", action: #selector(toggleColors), keyEquivalent: "")
        colors.state = colorEnabled() ? .on : .off
        menu.addItem(colors)

        for item in DisplayItem.allCases {
            let mi = NSMenuItem(title: item.label, action: #selector(toggleItem(_:)), keyEquivalent: "")
            let visible = visibleItems().contains(item)
            mi.state = visible ? .on : .off
            let count = visibleItems().count
            // Enforce "at least one, at most two" visible items.
            mi.isEnabled = visible ? count > 1 : count < 2
            mi.representedObject = item.rawValue
            mi.target = self
            menu.addItem(mi)
        }

        let intervalMenu = NSMenu()
        for (label, secs) in [("30s", 30), ("1m", 60), ("5m", 300), ("15m", 900), ("30m", 1800), ("60m", 3600)] {
            let mi = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            mi.state = (intervalSeconds() == TimeInterval(secs)) ? .on : .off
            mi.representedObject = secs
            mi.target = self
            intervalMenu.addItem(mi)
        }
        let intervalItem = NSMenuItem(title: "Update Interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items {
            if item.target == nil, item.action != #selector(NSApplication.terminate(_:)) {
                item.target = self
            }
        }
        statusItem.menu = menu
    }

    func infoItem(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: Menu actions

    @objc func refresh() {
        poll()
    }

    @objc func toggleColors() {
        setColorEnabled(!colorEnabled())
        render()
    }

    @objc func toggleItem(_ sender: NSMenuItem) {
        var items = visibleItems()
        guard let raw = sender.representedObject as? String, let item = DisplayItem(rawValue: raw) else { return }
        if let idx = items.firstIndex(of: item) {
            guard items.count > 1 else { return }
            items.remove(at: idx)
        } else {
            guard items.count < 2 else { return }
            items.append(item)
        }
        setVisibleItems(items)
        render()
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Int else { return }
        settingsDefaults.set(secs, forKey: "intervalSeconds")
        restartTimer()
    }

    @objc func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            default: try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("launch-at-login failed: \(error.localizedDescription)")
        }
        render()
    }
}

// MARK: - Entry

func printOnce() {
    guard let key = ProcessInfo.processInfo.environment["OLLAMA_API_KEY"], !key.isEmpty else {
        print("no API key (OLLAMA_API_KEY)")
        exit(1)
    }
    let sem = DispatchSemaphore(value: 0)
    fetchBalance(apiKey: key) { result in
        switch result {
        case let .success(resp):
            let st = State()
            st.session = resp.included?.session
            st.weekly = resp.included?.weekly
            print(st.titleText)
            if let s = resp.included?.session {
                print("Session: \(Int(s.remaining_percent.rounded()))% left — resets in \(countdown(from: s.resets_at))")
            }
            if let w = resp.included?.weekly {
                print("Weekly: \(Int(w.remaining_percent.rounded()))% left — resets in \(countdown(from: w.resets_at))")
            }
        case let .failure(e):
            print("error: \(e.kind)")
            exit(1)
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    selfTest()
}

if CommandLine.arguments.contains("--once") {
    printOnce()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
