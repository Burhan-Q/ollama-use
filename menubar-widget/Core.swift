// OllamaUsage — data model, normalization, settings, countdown,
// API/mock loading, and the `--self-test` suite. UI lives in OllamaUsage.swift.

import AppKit
import Foundation

// MARK: - API model

struct BalanceResponse: Decodable {
    let included: Included?
    struct Included: Decodable {
        let session: Limit?
        let weekly: Limit?
        let balance_usd: Double?
        let allowance_usd: Double?
        let period: Period?
        struct Period: Decodable {
            let from: String?
            let until: String
        }

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
        if session == nil, weekly == nil {
            return errorKind.map { "⚠︎ \($0)" } ?? "⚠︎ no usage data"
        }
        let limit = { (isSession: Bool) -> BalanceResponse.Included.Limit? in
            isSession ? self.session : self.weekly
        }
        // Build from whichever limits exist (current-plan accounts have one).
        return defaultItems.compactMap { item in
            titleSegment(item, limit: limit(item.isSession))
        }.joined(separator: " | ")
    }
}

/// One status-bar segment for an item; nil when that limit has no data.
func titleSegment(_ item: DisplayItem, limit: BalanceResponse.Included.Limit?) -> String? {
    guard let limit else { return nil }
    return makeSegment(item,
                       remaining: limit.remaining_percent,
                       countdownText: countdown(from: limit.resets_at))
}

let defaultItems: [DisplayItem] = [.sessionUsage, .sessionReset]

// Map the endpoint's two response shapes onto the app's one usage model.
// Legacy: included.session/.weekly (percent + resets_at). Current:
// balance_usd/allowance_usd with a period. Current-plan accounts have a
// single limit, surfaced through the session slot. Legacy wins if a
// response somehow carries both; purchased credits are ignored.
func normalize(_ included: BalanceResponse.Included?) -> (Double, String)? {
    if included?.session != nil, included?.weekly != nil {
        return (included!.session!.remaining_percent, included!.session!.resets_at)
    }
    if let balance = included?.balance_usd, let allowance = included?.allowance_usd, allowance > 0 {
        return (balance / allowance * 100, included!.period!.until)
    }
    return nil
}

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

/// Mock endpoint for testing non-legacy plan shapes: pointing
/// OLLAMA_BALANCE_MOCK at a JSON file bypasses the network entirely
/// (and the OLLAMA_API_KEY requirement). Real requests otherwise.
func loadBalance(completion: @escaping (Result<BalanceResponse, APIError>) -> Void) {
    let env = ProcessInfo.processInfo.environment
    if let rawPath = env["OLLAMA_BALANCE_MOCK"], !rawPath.isEmpty {
        // Expand `~` ourselves: GUI launches may not.
        let path = (rawPath as NSString).expandingTildeInPath
        let data = FileManager.default.contents(atPath: path)
        if let data {
            do {
                try completion(.success(JSONDecoder().decode(BalanceResponse.self, from: data)))
            } catch {
                completion(.failure(APIError(kind: "mock parse", retryAfter: nil)))
            }
        } else {
            completion(.failure(APIError(kind: "mock file unreadable: \(path)", retryAfter: nil)))
        }
        return
    }
    guard let key = env["OLLAMA_API_KEY"], !key.isEmpty else {
        completion(.failure(APIError(kind: "no API key", retryAfter: nil)))
        return
    }
    fetchBalance(apiKey: key, completion: completion)
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

    // MARK: Self-test additions (normalization)

    // Normalization (both response shapes).
    normalizationTests()

    settingsDefaults.removeObject(forKey: "items")
    assert(visibleItems() == defaultItems)
    setVisibleItems([.weeklyReset, .sessionUsage])
    assert(visibleItems() == [.weeklyReset, .sessionUsage])
    settingsDefaults.removeObject(forKey: "items")

    print("self-test OK")
    exit(0)
}

// Self-test: the two response shapes and the normalize() mapping.
func normalizationTests() {
    var inc: BalanceResponse.Included?
    func decode(_ json: String) {
        do {
            inc = try JSONDecoder().decode(BalanceResponse.self, from: Data(json.utf8)).included
        } catch {
            fatalError("self-test json failed to decode: \(error)")
        }
    }

    // Current plan: percent math + period.until, purchased ignored.
    decode(#"""
    {"included":{"balance_usd":72.5,"allowance_usd":100,
    "period":{"from":"2026-09-15T09:30:00Z","until":"2026-10-15T09:30:00Z"}},
    "purchased":{"balance_usd":25}}
    """#)
    assert(normalize(inc).map { $0 == (72.5, "2026-10-15T09:30:00Z") } == true)

    // Zero allowance -> nil.
    decode(#"""
    {"included":{"balance_usd":5,"allowance_usd":0,
    "period":{"until":"2026-10-15T09:30:00Z"}}}
    """#)
    assert(normalize(inc) == nil)

    // Legacy payload still wins and is untouched.
    decode(#"""
    {"included":{"session":{"remaining_percent":75,"resets_at":"a"},
    "weekly":{"remaining_percent":40,"resets_at":"b"},
    "balance_usd":1,"allowance_usd":2,"period":{"until":"c"}}}
    """#)
    assert(normalize(inc).map { $0 == (75, "a") } == true)

    // Incomplete legacy -> nil.
    decode(#"{"included":{"session":{"remaining_percent":75,"resets_at":"a"}}}"#)
    assert(normalize(inc) == nil)
}

// Call normalizationTests() inside the self-test entry point above.
