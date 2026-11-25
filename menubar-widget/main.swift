// OllamaUsage — macOS menu bar widget for Ollama Cloud legacy-plan usage.
// Data: https://ollama.com/api/balance (session/weekly remaining_percent + resets_at).
// Requires OLLAMA_API_KEY in the environment. Poll interval via
// `defaults write menubar.ollama-usage intervalSeconds <n>` (default 300),
// or env OLLAMA_USAGE_INTERVAL. Settings live in the same `defaults` suite.

import AppKit
import ServiceManagement

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
        let stored = settingsDefaults.integer(forKey: "intervalSeconds")
        return min(3600, max(30, TimeInterval(stored == 0 ? 300 : stored)))
    }

    func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds(), repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func poll() {
        pollRetryWorkItem?.cancel()
        loadBalance { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(resp):
                    if let included = resp.included {
                        if let cur = normalize(included), included.session == nil {
                            // Current-plan account: single synthesized limit.
                            self.state.session = .init(remaining_percent: cur.0, resets_at: cur.1)
                            self.state.weekly = nil
                        } else {
                            self.state.session = included.session
                            self.state.weekly = included.weekly
                        }
                    }
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
            let isSession = item.isSession
            guard let limit = isSession ? state.session : state.weekly else { continue }
            let tint = item.isUsage && colorEnabled() ? color(forRemaining: limit.remaining_percent) : nil
            let text = makeSegment(item, remaining: limit.remaining_percent,
                                   countdownText: countdown(from: limit.resets_at))
            segs.append((text, tint))
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
            let isSession = item.isSession
            guard let limit = isSession ? state.session : state.weekly else { continue }
            menu.addItem(infoItem("\(item.label): \(Int(limit.remaining_percent.rounded()))% left"
                    + " — resets in \(countdown(from: limit.resets_at))"))
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

        let intervalItem = NSMenuItem(title: "Update Interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu()
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

    /// "Update Interval" submenu; checkmark tracks the active setting.
    func intervalMenu() -> NSMenu {
        let menu = NSMenu()
        for (label, secs) in [("30s", 30), ("1m", 60), ("5m", 300), ("15m", 900), ("30m", 1800), ("60m", 3600)] {
            let mi = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            mi.state = (intervalSeconds() == TimeInterval(secs)) ? .on : .off
            mi.representedObject = secs
            mi.target = self
            menu.addItem(mi)
        }
        return menu
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
    let sem = DispatchSemaphore(value: 0)
    loadBalance { result in
        switch result {
        case let .success(resp):
            let st = State()
            if let included = resp.included {
                if let cur = normalize(included), included.session == nil {
                    st.session = .init(remaining_percent: cur.0, resets_at: cur.1)
                } else {
                    st.session = included.session
                    st.weekly = included.weekly
                }
            }
            print(st.titleText)
            var rows = [(String, BalanceResponse.Included.Limit)]()
            if let s = st.session {
                rows.append(("Session", s))
            }
            if let w = st.weekly {
                rows.append(("Weekly", w))
            }
            for (label, limit) in rows {
                print("\(label): \(Int(limit.remaining_percent.rounded()))% left"
                    + " — resets in \(countdown(from: limit.resets_at))")
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
