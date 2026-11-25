// Taxi Meter: a menu-bar taxi meter for what your AI coding agent costs.
// Reads Claude Code session logs (~/.claude/projects/**/*.jsonl) on this Mac. Single file, no dependencies.
// Live fare, trips per session, 5-hour shift window, log book, fare caps with alerts, plan value, receipts, CSV.
// Build: ./build.sh   Self-check: --selftest   Real totals: --scan   Renders of real data: --snapshot <dir>
// Checking the live panel: --open-panel (same path as the Option-Command-T shortcut), --print (prints a receipt)
import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

// MARK: - Pricing ($ per million tokens)

struct Price: Codable { var input, output, cacheWrite5m, cacheWrite1h, cacheRead: Double }

func price(_ i: Double, _ o: Double, read: Double? = nil) -> Price {
    Price(input: i, output: o, cacheWrite5m: i * 1.25, cacheWrite1h: i * 2, cacheRead: read ?? i * 0.1)
}

// ponytail: standard rates only. Fast mode, batch discounts and Haiku's >100K tier are not modelled;
// edit ~/Library/Application Support/TaxiMeter/prices.json to recalibrate without rebuilding.
let defaultPrices: [String: Price] = [
    "claude-fable-5-2": price(8, 40, read: 0.20), "claude-mythos-5-2": price(8, 40, read: 0.20),
    "claude-fable-5-1": price(10, 50), "claude-fable-5": price(10, 50),
    "claude-opus-5-5": price(4, 20, read: 0.20), "claude-opus-5": price(5, 25),
    "claude-opus-4": price(5, 25),
    "claude-sonnet-5-5": price(2, 10, read: 0.10), "claude-sonnet-5": price(2, 10),
    "claude-sonnet-4": price(3, 15),
    "claude-haiku-5-5": price(0.10, 0.50), "claude-haiku-4-5": price(1, 5),
]
let familyDefault = ["fable": "claude-fable-5-2", "mythos": "claude-mythos-5-2", "opus": "claude-opus-5-5",
                     "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5"]

func lookupPrice(_ model: String, in prices: [String: Price]) -> Price? {
    // Longest prefix wins, so "claude-opus-5-5" beats "claude-opus-5" and dated ids still match.
    if let k = prices.keys.filter({ model.hasPrefix($0) }).max(by: { $0.count < $1.count }) { return prices[k] }
    for (family, id) in familyDefault where model.contains(family) { return prices[id] }
    return nil
}

let pricesURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("TaxiMeter/prices.json")

func loadPrices() -> [String: Price] {
    if let d = try? Data(contentsOf: pricesURL), let p = try? JSONDecoder().decode([String: Price].self, from: d) { return p }
    try? FileManager.default.createDirectory(at: pricesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(defaultPrices).write(to: pricesURL)
    return defaultPrices
}

// MARK: - Log parsing

/// One priced API call. A message is logged several times while it streams; it is kept once, by id.
struct Call: Codable {
    var id: String, model: String, ts: Date
    var session = "", project = "", branch = ""
    var day = Date.distantPast
    var input = 0, output = 0, cw5 = 0, cw1h = 0, cr = 0
    var cost = 0.0, saved = 0.0, unpriced = false
    var tokens: Int { input + output + cw5 + cw1h + cr }

    mutating func priceWith(_ prices: [String: Price]) {
        guard let p = lookupPrice(model, in: prices) else { unpriced = true; cost = 0; saved = 0; return }
        cost = (Double(input) * p.input + Double(output) * p.output + Double(cw5) * p.cacheWrite5m
                + Double(cw1h) * p.cacheWrite1h + Double(cr) * p.cacheRead) / 1_000_000
        saved = Double(cr) * (p.input - p.cacheRead) / 1_000_000      // what those cache reads would cost as fresh input
    }
}

let isoFmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
}()

/// Reads one log line without parsing the whole thing: assistant lines can carry megabytes of content.
/// Claude Code writes `message.model` and `message.id` before the content, and `usage`, `requestId`,
/// `timestamp`, `cwd`, `sessionId`, `gitBranch` after it, so first and last matches are safe.
/// Falls back to a full JSON parse if the layout ever changes.
func parseLine(_ line: Data, _ prices: [String: Price]) -> Call? {
    func str(_ key: String, last: Bool) -> String? {
        guard let r = line.range(of: Data("\"\(key)\":\"".utf8), options: last ? .backwards : []) else { return nil }
        var i = r.upperBound
        while i < line.endIndex, line[i] != 0x22 { i += line[i] == 0x5C ? 2 : 1 }
        return String(decoding: line[r.upperBound..<min(i, line.endIndex)], as: UTF8.self)
    }
    func usageObject() -> [String: Any]? {
        guard let r = line.range(of: Data("\"usage\":{".utf8), options: .backwards) else { return nil }
        var depth = 0, inStr = false, i = r.upperBound - 1
        while i < line.endIndex {
            let b = line[i]
            if inStr { if b == 0x5C { i += 1 } else if b == 0x22 { inStr = false } }
            else if b == 0x22 { inStr = true }
            else if b == 0x7B { depth += 1 }
            else if b == 0x7D { depth -= 1; if depth == 0 { break } }
            i += 1
        }
        guard i < line.endIndex else { return nil }
        return try? JSONSerialization.jsonObject(with: line[(r.upperBound - 1)...i]) as? [String: Any]
    }
    var f: (model: String, id: String, req: String, ts: String, cwd: String, session: String, branch: String, usage: [String: Any])
    if let u = usageObject(), let model = str("model", last: false), let mid = str("id", last: false) {
        f = (model, mid, str("requestId", last: true) ?? "", str("timestamp", last: true) ?? "",
             str("cwd", last: true) ?? "", str("sessionId", last: true) ?? "", str("gitBranch", last: true) ?? "", u)
    } else {
        guard line.count < 256 << 10, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
              let model = msg["model"] as? String, let mid = msg["id"] as? String else { return nil }
        f = (model, mid, obj["requestId"] as? String ?? "", obj["timestamp"] as? String ?? "", obj["cwd"] as? String ?? "",
             obj["sessionId"] as? String ?? "", obj["gitBranch"] as? String ?? "", u)
    }
    guard f.model != "<synthetic>" else { return nil }
    let ts = isoFmt.date(from: f.ts) ?? Date()
    var c = Call(id: f.id + ":" + f.req, model: f.model, ts: ts)
    c.session = f.session
    c.project = f.cwd.isEmpty ? "unknown" : URL(fileURLWithPath: f.cwd).lastPathComponent
    c.branch = f.branch
    c.day = Calendar.current.startOfDay(for: ts)
    let u = f.usage
    c.input = u["input_tokens"] as? Int ?? 0
    c.output = u["output_tokens"] as? Int ?? 0
    c.cr = u["cache_read_input_tokens"] as? Int ?? 0
    if let cc = u["cache_creation"] as? [String: Any] {
        c.cw5 = cc["ephemeral_5m_input_tokens"] as? Int ?? 0
        c.cw1h = cc["ephemeral_1h_input_tokens"] as? Int ?? 0
    } else {
        c.cw5 = u["cache_creation_input_tokens"] as? Int ?? 0
    }
    c.priceWith(prices)
    return c
}

/// Tails every session log. Runs on its own queue; all state is private to that queue.
final class Scanner: @unchecked Sendable {
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var offsets: [String: UInt64] = [:]
    private var seen: [String: (cost: Double, tokens: Int)] = [:]
    private let prices: [String: Price]
    private let since: Date
    private var primed = false
    private let modelKey = Array("\"model\":\"".utf8)
    init(prices: [String: Price], since: Date) { self.prices = prices; self.since = since }

    /// Returns the call when it is new or its usage grew (the full record, not a delta).
    func feed(_ line: Data) -> Call? {
        guard let c = parseLine(line, prices), c.ts >= since else { return nil }
        let prev = seen[c.id] ?? (0, 0)
        guard c.cost > prev.cost || c.tokens > prev.tokens else { return nil }
        seen[c.id] = (max(c.cost, prev.cost), max(c.tokens, prev.tokens))
        return c
    }

    /// Picks up where the cache left off: those bytes are not read again.
    func restore(offsets o: [String: UInt64], calls: [Call]) {
        offsets = o
        for c in calls { seen[c.id] = (c.cost, c.tokens) }
    }

    /// `live` is false for the first pass (history), true afterwards (calls happening now). Newest files go first,
    /// and `progress` gets batches during a long pass so the meter fills in while history loads.
    func poll(progress: ((_ batch: [Call], _ done: Double) -> Void)? = nil) -> (calls: [Call], live: Bool, offsets: [String: UInt64]) {
        var out: [Call] = []
        let live = primed
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var files: [(url: URL, mod: Date, size: UInt64)] = []
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), let mod = v.contentModificationDate, mod >= since,
                      let size = v.fileSize.map(UInt64.init), size != offsets[url.path] else { continue }
                files.append((url, mod, size))
            }
        }
        files.sort { $0.mod > $1.mod }
        let total = Double(files.reduce(0) { $0 + $1.size - min($1.size, offsets[$1.url.path] ?? 0) })
        var done = 0.0, flushed = Date()
        for (url, _, size) in files {
            var pos = offsets[url.path] ?? 0
            if size < pos { pos = 0 }              // file was rewritten; ids already seen are not counted twice
            guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            try? fh.seek(toOffset: pos)
            done += Double(size - pos)
            var carry = Data()                     // read in 4 MB chunks so a 300 MB log never sits in memory whole
            while autoreleasepool(invoking: { () -> Bool in      // the read must sit inside the pool, or every chunk lingers
                    guard let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
                    carry.append(chunk)
                    var hits: [Range<Int>] = [], consumed = 0
                    carry.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in      // memchr/memmem: byte speed, no copies
                        guard let base = raw.baseAddress else { return }
                        // Only assistant lines name the model in their first bytes; user lines carry the big tool
                        // output, so they are skipped after a 512-byte look.
                        while consumed < raw.count, let nl = memchr(base + consumed, 0x0A, raw.count - consumed) {
                            let end = base.distance(to: UnsafeRawPointer(nl)), len = end - consumed
                            if len > 40, memmem(base + consumed, min(len, 512), modelKey, modelKey.count) != nil {
                                hits.append(consumed..<end)
                            }
                            consumed = end + 1
                        }
                    }
                    for r in hits { if let c = feed(carry.subdata(in: r)) { out.append(c) } }
                    pos += UInt64(consumed)
                    if consumed > 0 { carry = consumed < carry.count ? carry.subdata(in: consumed..<carry.count) : Data() }
                    if carry.count > 8 << 20 {             // one giant line (a pasted image): keep its head and tail only,
                        carry = carry.prefix(4096) + carry.suffix(16384)   // which hold every field the parser reads
                    }
                    return true
                }) {}
            offsets[url.path] = pos                // a half-written last line is re-read next poll
            if let progress, Date().timeIntervalSince(flushed) > 0.4 {
                progress(out, total > 0 ? done / total : 1); out.removeAll(); flushed = Date()
            }
        }
        primed = true
        return (out, live, offsets)
    }
}

/// Parsed calls and read positions, so a restart reads only what is new.
struct Cache: Codable {
    var version = 1
    var offsets: [String: UInt64]
    var calls: [Call]
    static let url = pricesURL.deletingLastPathComponent().appendingPathComponent("cache.plist")
    static func load() -> Cache? {
        guard let d = try? Data(contentsOf: url), let c = try? PropertyListDecoder().decode(Cache.self, from: d), c.version == 1 else { return nil }
        return c
    }
    func save() {
        let e = PropertyListEncoder(); e.outputFormat = .binary
        try? e.encode(self).write(to: Cache.url, options: .atomic)
    }
}

// MARK: - Trips, shifts, breakdowns

struct Trip: Identifiable {
    var id: String, project: String, branch: String, start: Date, end: Date
    var cost = 0.0, tokens = 0
    var models: [String: Double] = [:]
}

/// Claude's usage limits run in 5-hour windows that open with your first prompt. Estimated from local logs
/// the way ccusage does it: a window starts at the hour (UTC) of its first call and lasts five hours.
struct Shift { var start: Date; var last: Date; var cost: Double; var end: Date { start.addingTimeInterval(5 * 3600) } }

func currentShift(_ calls: [Call], now: Date) -> Shift? {
    var cur: Shift?
    for c in calls.filter({ now.timeIntervalSince($0.ts) < 24 * 3600 }).sorted(by: { $0.ts < $1.ts }) {
        if let s = cur, c.ts < s.end { cur!.cost += c.cost; cur!.last = c.ts; continue }
        cur = Shift(start: Date(timeIntervalSince1970: floor(c.ts.timeIntervalSince1970 / 3600) * 3600), last: c.ts, cost: c.cost)
    }
    guard let s = cur, now < s.end else { return nil }
    return s
}

func groupTrips(_ calls: [Call], since: Date) -> [Trip] {
    var by: [String: Trip] = [:]
    for c in calls where c.ts >= since {
        let key = c.session.isEmpty ? c.project : c.session
        var t = by[key] ?? Trip(id: key, project: c.project, branch: c.branch, start: c.ts, end: c.ts)
        t.start = min(t.start, c.ts); t.end = max(t.end, c.ts)
        t.cost += c.cost; t.tokens += c.tokens; t.models[c.model, default: 0] += c.cost
        by[key] = t
    }
    return by.values.filter { $0.cost > 0 }.sorted { $0.end > $1.end }
}

enum Span: String, CaseIterable { case week = "7 DAYS", days30 = "30 DAYS", month = "THIS MONTH" }

struct Breakdown {
    var total = 0.0, saved = 0.0, trips = 0
    var days: [(Date, Double)] = [], projects: [(String, Double)] = [], models: [(String, Double)] = []
}

// MARK: - Formatting

let enUS = Locale(identifier: "en_US_POSIX"), usNumbers = Locale(identifier: "en_US")
func money(_ v: Double) -> String { v.formatted(.currency(code: "USD").locale(usNumbers)) }
func tok(_ n: Int) -> String { n.formatted(.number.locale(usNumbers)) }
func tokShort(_ n: Int) -> String { n.formatted(.number.notation(.compactName).locale(usNumbers)) }
func fmt(_ pattern: String, _ d: Date) -> String {
    let f = DateFormatter(); f.locale = enUS; f.dateFormat = pattern; return f.string(from: d).uppercased()
}
func dur(_ s: TimeInterval) -> String { let m = max(1, Int(s / 60)); return m < 60 ? "\(m)M" : "\(m / 60)H \(m % 60)M" }
func short(_ s: String) -> String { String(s.replacingOccurrences(of: "claude-", with: "").uppercased().prefix(20)) }
func csvField(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

// MARK: - Receipts

struct Receipt: Identifiable {
    let id = UUID()
    var meta: [(String, String)]
    var lines: [(String, String)]
    var total: String
    var title = "AI AGENT FARE RECEIPT"
    var totalLabel = "TOTAL FARE"
    var foot: [(String, String)] = []
    var note = "API LIST PRICES. NO TIP NEEDED."
    var file = "taxi-receipt"
}

func topLines(_ d: [String: Double], n: Int = 6) -> [(String, String)] {
    let s = d.sorted { $0.value > $1.value }
    var out = s.prefix(n).map { (short($0.key), money($0.value)) }
    if s.count > n { out.append(("OTHER", money(s.dropFirst(n).reduce(0) { $0 + $1.value }))) }
    return out
}

// MARK: - Meter state

@MainActor final class Meter: ObservableObject {
    @Published var trip = 0.0                 // since flag drop (launch or NEW TRIP)
    @Published var shown = 0.0                // eased toward trip, drives the LED
    @Published var tripTokens = 0
    @Published var lastActivity = Date.distantPast
    @Published var byModel: [String: Double] = [:]
    @Published var flagDrop = Date()
    @Published var now = Date()
    @Published var today = 0.0
    @Published var week = 0.0
    @Published var month = 0.0
    @Published var unpriced = 0
    @Published var trips: [Trip] = []
    @Published var shift: Shift?
    @Published var lastHour = [Double](repeating: 0, count: 60)   // fare per minute, oldest first
    @Published var loaded = false
    @Published var loadingDone = 0.0         // share of history read on the first pass
    @Published var printing: Receipt?
    private(set) var calls: [Call] = []
    private var index: [String: Int] = [:]
    private var recent: [(Date, Double)] = []
    private var wasHired = false
    private var lastTick = Date.distantPast
    private var lastMinute = 0
    private var lastSave = Date.distantPast
    private let queue = DispatchQueue(label: "taximeter.scan")
    private let sounds: [String: NSSound] = ["tick", "bell", "feed", "flag"].reduce(into: [:]) { d, n in
        if let u = Bundle.main.url(forResource: n, withExtension: "wav") { d[n] = NSSound(contentsOf: u, byReference: true) }
    }

    static let surge = 0.50                   // ponytail: fixed $/min threshold; make it relative if users ask
    var hired: Bool { now.timeIntervalSince(lastActivity) < 30 }
    var ratePerMin: Double { recent.filter { now.timeIntervalSince($0.0) < 60 }.reduce(0) { $0 + $1.1 } }
    var surging: Bool { hired && ratePerMin >= Meter.surge }
    var muted: Bool { UserDefaults.standard.bool(forKey: "mute") }

    static var historyStart: Date {
        let cal = Calendar.current, d0 = cal.startOfDay(for: Date())
        return min(cal.date(byAdding: .day, value: -29, to: d0)!, cal.dateInterval(of: .month, for: d0)!.start)
    }

    init(start: Bool = true) {
        guard start else { return }
        let prices = loadPrices(), since = Meter.historyStart
        let scanner = Scanner(prices: prices, since: since)
        queue.async { [weak self] in
            guard let cache = Cache.load() else { return }
            let calls = cache.calls.filter { $0.ts >= since }.map { c -> Call in var c = c; c.priceWith(prices); return c }
            scanner.restore(offsets: cache.offsets, calls: calls)
            DispatchQueue.main.async { self?.apply(calls, live: false) }
        }
        let scan = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.queue.async {
                let r = scanner.poll { batch, done in
                    DispatchQueue.main.async { self?.apply(batch, live: false); self?.loadingDone = done }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.apply(r.calls, live: r.live)
                    if !self.loaded || (!r.calls.isEmpty && Date().timeIntervalSince(self.lastSave) > 300) {
                        self.lastSave = Date()
                        let cache = Cache(offsets: r.offsets, calls: self.calls)
                        DispatchQueue.global(qos: .utility).async { cache.save() }
                    }
                    if !self.loaded, CommandLine.arguments.contains("--print") { self.printing = self.liveReceipt() }   // for checking
                    self.loaded = true; self.loadingDone = 1
                }
            }
        }
        let anim = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.step() }
        }
        RunLoop.main.add(scan, forMode: .common); RunLoop.main.add(anim, forMode: .common)
        scan.fire()
        hotKeyAction = { clickStatusItem() }
        registerHotKey()
        if CommandLine.arguments.contains("--open-panel") {     // for checking the panel: same path as the shortcut
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { clickStatusItem() }
        }
    }

    func play(_ n: String) {
        guard !muted else { return }
        if let snd = sounds[n] { snd.stop(); snd.play() } else { NSSound(named: n == "bell" ? "Glass" : "Tink")?.play() }
    }

    func apply(_ new: [Call], live: Bool) {
        guard !new.isEmpty else { return }
        for c in new {
            var delta = c.cost, dTok = c.tokens
            if let i = index[c.id] {
                var n = c; n.cost = max(c.cost, calls[i].cost)
                delta = n.cost - calls[i].cost; dTok = max(0, n.tokens - calls[i].tokens)
                calls[i] = n
            } else {
                index[c.id] = calls.count; calls.append(c)
            }
            guard live, delta > 0 || dTok > 0 else { continue }
            trip += delta; tripTokens += dTok
            byModel[c.model, default: 0] += delta
            lastActivity = Date()
            recent.append((Date(), delta))
        }
        recompute()
    }

    func recompute() {
        let cal = Calendar.current, d0 = cal.startOfDay(for: Date())
        let w0 = cal.date(byAdding: .day, value: -6, to: d0)!, m0 = cal.dateInterval(of: .month, for: d0)!.start
        var t = 0.0, w = 0.0, m = 0.0, un = 0
        for c in calls {
            if c.day >= d0 { t += c.cost; if c.unpriced { un += 1 } }
            if c.day >= w0 { w += c.cost }
            if c.day >= m0 { m += c.cost }
        }
        today = t; week = w; month = m; unpriced = un
        trips = groupTrips(calls, since: cal.date(byAdding: .day, value: -29, to: d0)!)
        shift = currentShift(calls, now: Date())
        var hour = [Double](repeating: 0, count: 60), nowT = Date()
        for c in calls where nowT.timeIntervalSince(c.ts) < 3600 && c.ts <= nowT { hour[59 - Int(nowT.timeIntervalSince(c.ts) / 60)] += c.cost }
        lastHour = hour
        if loaded { checkCaps() }
    }

    func step() {
        let t = Date()
        if t.timeIntervalSince(now) >= 1 {
            now = t; recent.removeAll { now.timeIntervalSince($0.0) > 60 }
            let minute = Int(t.timeIntervalSince1970 / 60)
            if minute != lastMinute { lastMinute = minute; if !calls.isEmpty { recompute() } }   // day rollover, shift end
        }
        if hired != wasHired { wasHired = hired; if hired { play("flag") } }
        guard shown < trip else { if shown > trip { shown = trip }; return }
        let before = Int(shown * 100), dollarsBefore = Int(shown)
        shown = min(trip, shown + max(0.01, (trip - shown) * 0.12))
        guard Int(shown * 100) != before, t.timeIntervalSince(lastTick) > 0.07 else { return }
        lastTick = t
        play(Int(shown) != dollarsBefore ? "bell" : "tick")   // bell on every whole dollar
    }

    func newTrip() { trip = 0; shown = 0; tripTokens = 0; byModel = [:]; recent = []; flagDrop = Date() }

    // MARK: fare caps

    /// Highest alert step (0.5, 0.8, 1.0) reached that was not yet announced for this period, if any.
    nonisolated static func capStep(spent: Double, cap: Double, announced: Double) -> Double? {
        guard cap > 0 else { return nil }
        return [1.0, 0.8, 0.5].first { spent >= cap * $0 && $0 > announced }
    }

    func checkCaps() {
        let d = UserDefaults.standard
        guard d.object(forKey: "alerts") == nil || d.bool(forKey: "alerts") else { return }
        for (name, spent, capKey, period) in [("Today", today, "capDay", fmt("yyyyMMdd", now)),
                                              ("This week", week, "capWeek", fmt("YYYYww", now))] {
            let key = "announced-\(capKey)-\(period)", cap = d.double(forKey: capKey)
            guard let s = Meter.capStep(spent: spent, cap: cap, announced: d.double(forKey: key)) else { continue }
            d.set(s, forKey: key)
            play("bell")
            notify(s >= 1 ? "Over your fare cap" : "Fare at \(Int(s * 100))% of cap",
                   "\(name): \(money(spent)) of \(money(cap)) at API list prices.")
        }
    }

    // MARK: breakdowns and receipts

    func breakdown(_ span: Span) -> Breakdown {
        let cal = Calendar.current, d0 = cal.startOfDay(for: now)
        let from: Date
        switch span {
        case .week: from = cal.date(byAdding: .day, value: -6, to: d0)!
        case .days30: from = cal.date(byAdding: .day, value: -29, to: d0)!
        case .month: from = cal.dateInterval(of: .month, for: d0)!.start
        }
        var b = Breakdown(), days: [Date: Double] = [:], proj: [String: Double] = [:], mod: [String: Double] = [:]
        var sessions = Set<String>()
        for c in calls where c.day >= from {
            b.total += c.cost; b.saved += c.saved
            days[c.day, default: 0] += c.cost; proj[c.project, default: 0] += c.cost; mod[c.model, default: 0] += c.cost
            if c.cost > 0 { sessions.insert(c.session) }
        }
        var d = from
        while d <= d0 { b.days.append((d, days[d] ?? 0)); d = cal.date(byAdding: .day, value: 1, to: d)! }
        b.projects = proj.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        b.models = mod.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        b.trips = sessions.count
        return b
    }

    func liveReceipt() -> Receipt? {
        guard trip > 0 else { return trips.first.map(receipt(for:)) }
        return Receipt(meta: [("DATE", fmt("dd MMM yyyy HH:mm", Date())), ("TRIP TIME", dur(Date().timeIntervalSince(flagDrop))),
                              ("TOKENS", tok(tripTokens))],
                       lines: topLines(byModel), total: money(trip), foot: [("TODAY SO FAR", money(today))])
    }

    func receipt(for t: Trip) -> Receipt {
        var meta = [("PROJECT", short(t.project))]
        if !t.branch.isEmpty && t.branch != "HEAD" { meta.append(("BRANCH", short(t.branch))) }
        meta += [("DATE", fmt("dd MMM yyyy", t.start)), ("PICKUP", fmt("HH:mm", t.start)), ("DROP-OFF", fmt("HH:mm", t.end)),
                 ("TRIP TIME", dur(t.end.timeIntervalSince(t.start))), ("TOKENS", tok(t.tokens))]
        return Receipt(meta: meta, lines: topLines(t.models), total: money(t.cost))
    }

    func dayReceipt(_ day: Date) -> Receipt {
        var proj: [String: Double] = [:], tokens = 0, saved = 0.0, total = 0.0, sessions = Set<String>()
        for c in calls where c.day == day {
            proj[c.project, default: 0] += c.cost; tokens += c.tokens; saved += c.saved; total += c.cost
            if c.cost > 0 { sessions.insert(c.session) }
        }
        return Receipt(meta: [("DATE", fmt("EEE dd MMM yyyy", day)), ("TRIPS", "\(sessions.count)"), ("TOKENS", tok(tokens))],
                       lines: topLines(proj), total: money(total), title: "DAILY FARE RECEIPT",
                       foot: [("CACHE SAVED", money(saved))], file: "taxi-day")
    }

    func statement() -> Receipt {
        let b = breakdown(.month), plan = UserDefaults.standard.double(forKey: "plan")
        var tokens = 0
        let m0 = Calendar.current.dateInterval(of: .month, for: now)!.start
        for c in calls where c.day >= m0 { tokens += c.tokens }
        var foot = [("CACHE SAVED", money(b.saved))]
        if plan > 0 { foot += [("YOUR PLAN", money(plan) + "/MO"), ("PLAN VALUE", String(format: "%.1fX", b.total / plan))] }
        return Receipt(meta: [("MONTH", fmt("MMMM yyyy", now)), ("TRIPS", "\(b.trips)"), ("TOKENS", tok(tokens))],
                       lines: topLines(Dictionary(uniqueKeysWithValues: b.projects)), total: money(b.total),
                       title: "MONTHLY STATEMENT", foot: foot, file: "taxi-statement")
    }

    func save(_ r: Receipt) {
        let url = desktop("\(r.file)-\(fmt("yyyyMMdd-HHmmss", Date())).png")
        writePNG(ReceiptView(r: r), to: url.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copy(_ r: Receipt) {
        let ren = ImageRenderer(content: ReceiptView(r: r)); ren.scale = 2
        guard let img = ren.nsImage else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img])
    }

    func exportCSV() {
        var s = "date,pickup,drop_off,minutes,project,branch,models,tokens,fare_usd\n"
        for t in trips {
            let models = t.models.sorted { $0.value > $1.value }.map(\.key).joined(separator: " ")
            s += [fmt("yyyy-MM-dd", t.start), fmt("HH:mm", t.start), fmt("HH:mm", t.end), "\(Int(t.end.timeIntervalSince(t.start) / 60))",
                  csvField(t.project), csvField(t.branch), csvField(models), "\(t.tokens)", String(format: "%.4f", t.cost)]
                .joined(separator: ",") + "\n"
        }
        let url = desktop("taxi-trips-\(fmt("yyyyMMdd", Date())).csv")
        try? s.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

func desktop(_ name: String) -> URL {
    FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
}

func notify(_ title: String, _ body: String) {
    let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

func askNotifications() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }

// MARK: - Global shortcut (Option-Command-T opens the meter)

nonisolated(unsafe) var hotKeyAction: (() -> Void)?

func registerHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { hotKeyAction?() }; return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(cmdKey | optionKey), EventHotKeyID(signature: 0x5441_5849, id: 1),
                        GetApplicationEventTarget(), 0, &ref)
}

/// MenuBarExtra has no API to open its window, so press its status-bar button.
func clickStatusItem() {
    func find(_ v: NSView?) -> NSStatusBarButton? {
        guard let v else { return nil }
        if let b = v as? NSStatusBarButton { return b }
        for s in v.subviews { if let b = find(s) { return b } }
        return nil
    }
    for w in NSApp.windows { if let b = find(w.contentView) { b.performClick(nil); return } }
}

// MARK: - Self-check and entry point

@MainActor func selftest() {
    func line(_ id: String, out: Int) -> Data {
        Data(#"{"timestamp":"2099-01-01T10:00:00.000Z","requestId":"r1","sessionId":"s1","cwd":"/x/shop","gitBranch":"main","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":1000000,"output_tokens":\#(out),"cache_read_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000000}}}}"#.utf8)
    }
    let s = Scanner(prices: defaultPrices, since: .distantPast)
    // opus-5-5: 1M in ($4) + 1M cache read ($0.20) + 1M 1h cache write ($8) + 0.5M out ($10) = $22.20
    let c1 = s.feed(line("m1", out: 500_000))!
    precondition(abs(c1.cost - 22.20) < 1e-9, "cost \(c1.cost)")
    precondition(abs(c1.saved - 3.80) < 1e-9, "cache saving \(c1.saved)")
    precondition(c1.project == "shop" && c1.session == "s1" && c1.branch == "main", "fields")
    precondition(s.feed(line("m1", out: 500_000)) == nil, "duplicate line counted twice")
    let c2 = s.feed(line("m1", out: 1_000_000))!          // same message, final usage
    precondition(abs(c2.cost - 32.20) < 1e-9, "final \(c2.cost)")
    let m = Meter(start: false)
    m.apply([c1], live: true); m.apply([c2], live: true)
    precondition(m.calls.count == 1 && abs(m.trip - 32.20) < 1e-9, "upsert or live delta wrong: \(m.trip)")
    precondition(groupTrips(m.calls, since: .distantPast).first?.cost == m.calls[0].cost, "trip grouping")

    func at(_ iso: String, _ cost: Double) -> Call { var c = Call(id: iso, model: "x", ts: isoFmt.date(from: iso)!); c.cost = cost; return c }
    let calls = [at("2099-01-01T10:20:00.000Z", 1), at("2099-01-01T14:50:00.000Z", 2), at("2099-01-01T15:10:00.000Z", 4)]
    let sh = currentShift(calls, now: isoFmt.date(from: "2099-01-01T15:30:00.000Z")!)!
    precondition(sh.start == isoFmt.date(from: "2099-01-01T15:00:00.000Z")! && sh.cost == 4, "shift split")
    precondition(currentShift(Array(calls.prefix(2)), now: isoFmt.date(from: "2099-01-01T14:55:00.000Z")!)!.cost == 3, "shift sum")
    precondition(currentShift(calls, now: isoFmt.date(from: "2099-01-01T20:30:00.000Z")!) == nil, "shift expiry")

    precondition(Meter.capStep(spent: 41, cap: 50, announced: 0) == 0.8, "cap 80%")
    precondition(Meter.capStep(spent: 41, cap: 50, announced: 0.8) == nil, "cap repeat")
    precondition(Meter.capStep(spent: 60, cap: 50, announced: 0.8) == 1.0, "cap over")
    precondition(Meter.capStep(spent: 60, cap: 0, announced: 0) == nil, "cap off")
    precondition(csvField("a\"b") == "\"a\"\"b\"", "csv escape")

    precondition(lookupPrice("claude-opus-5", in: defaultPrices)!.input == 5, "prefix picked wrong model")
    precondition(lookupPrice("claude-haiku-4-5-20251001", in: defaultPrices)!.input == 1, "dated id")
    precondition(lookupPrice("opus", in: defaultPrices)!.input == 4, "alias")
    precondition(lookupPrice("gpt-9", in: defaultPrices) == nil, "unknown model priced")
    precondition(s.feed(Data("not json at all, definitely longer than forty bytes".utf8)) == nil)
    print("selftest ok")
}

/// Loads real history synchronously (for --scan and --snapshot).
@MainActor func loadNow() -> Meter {
    let m = Meter(start: false)
    let r = Scanner(prices: loadPrices(), since: Meter.historyStart).poll()
    m.loaded = true
    m.apply(r.calls, live: false)
    return m
}

nonisolated(unsafe) var renderingStill = false   // true while rendering PNGs: views skip entrance animations

@main struct TaxiMeterApp: App {
    @StateObject private var meter = Meter()
    init() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { MainActor.assumeIsolated { selftest() }; exit(0) }
        if args.contains("--scan") {
            MainActor.assumeIsolated {
                let t0 = Date(), m = loadNow()
                print("loaded \(m.calls.count) calls in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                print("today", money(m.today), "week", money(m.week), "month", money(m.month), "unpriced today", m.unpriced)
                print("trips (30d)", m.trips.count, "latest", m.trips.first.map { "\($0.project) \(money($0.cost))" } ?? "-")
                if let s = m.shift { print("shift since", fmt("HH:mm", s.start), money(s.cost), "ends", fmt("HH:mm", s.end)) }
                for (p, c) in m.breakdown(.days30).projects.prefix(5) { print("  ", p, money(c)) }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
            MainActor.assumeIsolated { writePNG(IconView(), to: args[i + 1], scale: 1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {   // renders of this Mac's real data
            let dir = args[i + 1]
            renderingStill = true
            MainActor.assumeIsolated {
                let m = loadNow()
                if let t = m.trips.first {      // show the most recent real trip on the meter, mid-ride
                    m.trip = t.cost; m.shown = t.cost; m.tripTokens = t.tokens; m.byModel = t.models
                    m.flagDrop = t.start; m.lastActivity = Date(); m.now = Date()
                }
                for tab in Tab.allCases { writePNG(Panel(meter: m, tab: tab), to: "\(dir)/panel-\(tab.slug).png") }
                if let r = m.liveReceipt() { writePNG(ReceiptView(r: r), to: "\(dir)/receipt-trip.png") }
                writePNG(ReceiptView(r: m.statement()), to: "\(dir)/receipt-statement.png")
                writePNG(ReceiptView(r: m.dayReceipt(Calendar.current.startOfDay(for: Date()))), to: "\(dir)/receipt-day.png")
            }
            exit(0)
        }
    }
    var body: some Scene {
        MenuBarExtra {
            Panel(meter: meter)
        } label: {
            HStack(spacing: 4) { Image(systemName: meter.hired ? "car.fill" : "car"); Text(money(meter.shown)).monospacedDigit() }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Look

let ledRed = Color(red: 1, green: 0.14, blue: 0.08)
let cabYellow = Color(red: 1, green: 0.78, blue: 0.05)
let amber = Color(red: 1, green: 0.52, blue: 0.04)
let paper = Color(red: 0.97, green: 0.96, blue: 0.92)
func mono(_ s: CGFloat, _ w: Font.Weight = .bold) -> Font { .system(size: s, weight: w, design: .monospaced) }

extension View {
    func label() -> some View { font(mono(9)).tracking(1.3).foregroundColor(.white.opacity(0.45)) }
}

// MARK: Seven-segment display

let segMap: [Character: String] = ["0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg",
                                   "5": "acdfg", "6": "acdefg", "7": "abc", "8": "abcdefg", "9": "abcdfg"]

struct LEDMetrics {
    let h, w, t, gap, dotW, slant: CGFloat
    let digits: Int
    init(_ size: CGSize, digits: Int) {
        h = size.height; slant = h * 0.09; gap = size.width * 0.03
        w = (size.width - slant - gap * CGFloat(digits - 1)) / (CGFloat(digits) + 0.34)
        t = w * 0.17; dotW = w * 0.34; self.digits = digits
    }
    func x(_ i: Int) -> CGFloat { CGFloat(i) * (w + gap) + (i >= digits - 2 ? dotW : 0) }
    var dot: CGRect { CGRect(x: CGFloat(digits - 2) * (w + gap) - gap + (gap + dotW - t) / 2, y: h - t, width: t, height: t) }
}

func hexBar(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> Path {
    let k = t / 2
    var p = Path()
    if a.y == b.y {
        p.addLines([a, CGPoint(x: a.x + k, y: a.y - k), CGPoint(x: b.x - k, y: b.y - k), b,
                    CGPoint(x: b.x - k, y: b.y + k), CGPoint(x: a.x + k, y: a.y + k)])
    } else {
        p.addLines([a, CGPoint(x: a.x + k, y: a.y + k), CGPoint(x: b.x + k, y: b.y - k), b,
                    CGPoint(x: b.x - k, y: b.y - k), CGPoint(x: a.x - k, y: a.y + k)])
    }
    p.closeSubpath()
    return p
}

func segPath(_ s: Character, _ x: CGFloat, _ m: LEDMetrics) -> Path {
    let (w, h, t) = (m.w, m.h, m.t), g = t * 0.14, mid = h / 2
    func hz(_ y: CGFloat) -> Path { hexBar(CGPoint(x: x + t / 2 + g, y: y), CGPoint(x: x + w - t / 2 - g, y: y), t) }
    func vt(_ xx: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Path { hexBar(CGPoint(x: xx, y: y0 + g), CGPoint(x: xx, y: y1 - g), t) }
    switch s {
    case "a": return hz(t / 2)
    case "g": return hz(mid)
    case "d": return hz(h - t / 2)
    case "f": return vt(x + t / 2, t / 2, mid)
    case "b": return vt(x + w - t / 2, t / 2, mid)
    case "e": return vt(x + t / 2, mid, h - t / 2)
    default: return vt(x + w - t / 2, mid, h - t / 2)
    }
}

struct DigitGlyph: View {
    let ch: Character, m: LEDMetrics, color: Color
    var body: some View {
        Canvas { ctx, _ in for seg in segMap[ch, default: ""] { ctx.fill(segPath(seg, 0, m), with: .color(color)) } }
    }
}

/// Cab-meter display: fixed digit field, unlit segments ghosted, two decimals. Each digit rolls up like a drum
/// when it changes.
struct LED: View {
    var value: Double
    var digits = 6
    var color = ledRed

    var body: some View {
        GeometryReader { g in
            let m = LEDMetrics(g.size, digits: digits)
            let cap = pow(10, Double(digits - 2)) - 0.01
            let cents = String(format: "%.2f", min(max(value, 0), cap)).replacingOccurrences(of: ".", with: "")
            let chars = Array(repeating: Character(" "), count: max(0, digits - cents.count)) + Array(cents)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for i in 0..<digits { for seg in "abcdefg" { ctx.fill(segPath(seg, m.x(i), m), with: .color(color.opacity(0.075))) } }
                    ctx.fill(Path(ellipseIn: m.dot), with: .color(color))
                }
                ForEach(0..<digits, id: \.self) { i in
                    ZStack {
                        DigitGlyph(ch: chars[i], m: m, color: color).id(chars[i])
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .move(edge: .top).combined(with: .opacity)))
                    }
                    .frame(width: m.w, height: m.h, alignment: .topLeading).clipped()
                    .offset(x: m.x(i))
                    .animation(.easeOut(duration: 0.16), value: chars[i])
                }
            }
            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -m.slant / max(m.h, 1), d: 1, tx: m.slant, ty: 0))
        }
        .shadow(color: color.opacity(0.75), radius: 7)
    }
}

// MARK: Cab parts

/// The black-and-yellow checker band cabs wear.
struct Checker: View {
    var rows = 2
    var body: some View {
        Canvas { ctx, size in
            let s = size.height / CGFloat(rows)
            for r in 0..<rows {
                for c in 0..<Int(size.width / s) + 1 where (r + c) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(c) * s, y: CGFloat(r) * s, width: s, height: s)), with: .color(.black))
                }
            }
        }.background(cabYellow)
    }
}

/// Indicator lamp. Flickers when it switches; `pulse` makes a lit lamp breathe.
struct Lamp: View {
    var label: String, color: Color, on: Bool, pulse = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(on && pulse) || renderingStill)) { tl in
            let breathe = on && pulse && !renderingStill ? 0.72 + 0.28 * sin(tl.date.timeIntervalSince1970 * 3) : 1
            HStack(spacing: 6) {
                Circle().fill(on ? color : color.opacity(0.16)).frame(width: 9, height: 9)
                    .shadow(color: on ? color.opacity(breathe) : .clear, radius: 6 * breathe)
                    .opacity(on ? 0.55 + 0.45 * breathe : 1)
                Text(label).font(mono(9.5)).tracking(1)
                    .foregroundColor(on ? .white : .white.opacity(0.3))
            }
        }
        .animation(.easeInOut(duration: 0.06).repeatCount(5, autoreverses: true), value: on)
    }
}

/// The meter's hire flag: up when free, swung down when the meter runs.
struct Flag: View {
    var down: Bool
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Text("FOR\nHIRE").font(.system(size: 7.5, weight: .black, design: .rounded)).multilineTextAlignment(.center)
                    .foregroundColor(.black).frame(width: 36, height: 22)
                    .background(cabYellow).cornerRadius(3)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.35), lineWidth: 1))
                Rectangle().fill(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.4)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 4, height: 14)
            }
            .rotationEffect(.degrees(down ? -90 : 0), anchor: .bottom)
            Circle().fill(Color(white: 0.55)).frame(width: 9, height: 9).offset(y: 4)
        }
        .frame(width: 44, height: 36)
        .padding(.bottom, 14)                // room for the plate when it swings down
        .animation(.spring(response: 0.5, dampingFraction: 0.45), value: down)
    }
}

struct Keycap: ButtonStyle {
    var accent = false
    func makeBody(configuration: Configuration) -> some View {
        KeycapBody(configuration: configuration, accent: accent)
    }
    struct KeycapBody: View {
        let configuration: Configuration, accent: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(mono(9.5)).tracking(1)
                .foregroundColor(accent ? .black : .white.opacity(0.88))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(accent
                            ? LinearGradient(colors: [cabYellow, cabYellow.opacity(configuration.isPressed ? 0.7 : 0.85)], startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [Color(white: configuration.isPressed ? 0.13 : (hover ? 0.3 : 0.25)), Color(white: 0.14)],
                                             startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.14)))
                .cornerRadius(5)
                .offset(y: configuration.isPressed ? 1 : (hover ? -1 : 0))
                .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.5), radius: 0, y: configuration.isPressed ? 0 : 2)
                .animation(.easeOut(duration: 0.12), value: hover)
                .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
                .onHover { hover = $0 }
        }
    }
}

struct Bar: View {
    var fraction: Double, color: Color, height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: g.size.width * min(max(fraction, 0), 1))
                    .shadow(color: color.opacity(0.6), radius: 3)
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: fraction)
    }
}

struct Segmented<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { o in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = o.0 } } label: {
                    Text(o.1).font(mono(9)).tracking(0.6)
                        .foregroundColor(selection == o.0 ? .black : .white.opacity(0.65))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background {
                            if selection == o.0 { RoundedRectangle(cornerRadius: 4).fill(cabYellow).matchedGeometryEffect(id: "seg", in: ns) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(3).background(Color.black.opacity(0.55)).cornerRadius(6)
    }
}

struct SwitchRow: View {
    var label: String
    @Binding var on: Bool
    var body: some View {
        Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { on.toggle() } } label: {
            HStack {
                Text(label).font(mono(10, .semibold)).foregroundColor(.white.opacity(0.85))
                Spacer()
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? cabYellow : Color.white.opacity(0.12)).frame(width: 34, height: 18)
                    Circle().fill(on ? Color.black : Color.white.opacity(0.6)).frame(width: 14, height: 14).padding(2)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// ScrollView in the app; a plain stack when rendering PNGs (ImageRenderer cannot draw scroll views).
struct Scroll<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        if renderingStill { VStack(spacing: 0) { content; Spacer(minLength: 0) } } else { ScrollView(showsIndicators: false) { content } }
    }
}

/// Fades and lifts content in on first appearance, staggered by `order`.
struct Entrance: ViewModifier {
    var order = 0
    @State private var shown = renderingStill
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown ? 0 : 8)
            .onAppear { withAnimation(.easeOut(duration: 0.35).delay(Double(min(order, 14)) * 0.03)) { shown = true } }
    }
}
extension View { func entrance(_ order: Int = 0) -> some View { modifier(Entrance(order: order)) } }

// MARK: - Panel

enum Tab: String, CaseIterable {
    case meter = "METER", trips = "TRIPS", log = "LOG BOOK", settings = "SETTINGS"
    var slug: String { rawValue.lowercased().replacingOccurrences(of: " ", with: "-") }
}

struct Panel: View {
    @ObservedObject var meter: Meter
    @State private var tab: Tab
    @Namespace private var ns
    init(meter: Meter, tab: Tab = .meter) { self.meter = meter; _tab = State(initialValue: tab) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text("TAXI").font(.system(size: 20, weight: .black, design: .rounded)).tracking(10)
                        .foregroundColor(.black).padding(.top, 8).padding(.bottom, 4).padding(.leading, 10)
                    Checker().frame(height: 10)
                }
                .frame(maxWidth: .infinity).background(cabYellow)
                tabBar
                    .overlay(alignment: .bottom) {
                        if !meter.loaded { Bar(fraction: meter.loadingDone, color: cabYellow, height: 2).transition(.opacity) }
                    }
                ZStack {
                    switch tab {
                    case .meter: MeterTab(meter: meter) { go(.settings) }.transition(slide)
                    case .trips: TripsTab(meter: meter).transition(slide)
                    case .log: LogTab(meter: meter) { go(.settings) }.transition(slide)
                    case .settings: SettingsTab(meter: meter).transition(slide)
                    }
                }
                .frame(height: 560, alignment: .top).clipped()
            }
            .background(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
            if let r = meter.printing { PrintOut(r: r, meter: meter).transition(.opacity) }
        }
        .frame(width: 360)
        .animation(.easeOut(duration: 0.2), value: meter.printing?.id)
        .environment(\.colorScheme, .dark)
    }

    var slide: AnyTransition { .asymmetric(insertion: .opacity.combined(with: .offset(x: 18)), removal: .opacity) }
    func go(_ t: Tab) { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { tab = t } }

    var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { go(t) } label: {
                    VStack(spacing: 6) {
                        Text(t.rawValue).font(mono(9.5)).tracking(1.1)
                            .foregroundColor(tab == t ? cabYellow : .white.opacity(0.45))
                        ZStack {
                            if tab == t { Capsule().fill(cabYellow).frame(height: 2).matchedGeometryEffect(id: "tab", in: ns) }
                            else { Color.clear.frame(height: 2) }
                        }
                    }
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.top, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }
}

// MARK: Meter tab

struct MeterTab: View {
    @ObservedObject var meter: Meter
    var openSettings: () -> Void
    @AppStorage("capDay") private var capDay = 0.0
    @AppStorage("capWeek") private var capWeek = 0.0
    @AppStorage("mute") private var mute = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Lamp(label: "FOR HIRE", color: .green, on: !meter.hired, pulse: true)
                Lamp(label: "HIRED", color: ledRed, on: meter.hired)
                Lamp(label: "SURGE", color: amber, on: meter.surging, pulse: true)
                Spacer()
                Flag(down: meter.hired)
            }
            display
            HStack(alignment: .top) {
                readout("TODAY", money(meter.today)); Spacer()
                readout("7 DAYS", money(meter.week)); Spacer()
                readout("RATE/MIN", money(meter.ratePerMin)); Spacer()
                readout("TOKENS", tokShort(meter.tripTokens))
            }
            shiftCard
            Tape(buckets: meter.lastHour)
            caps
            if meter.unpriced > 0 {
                Text("\(meter.unpriced) CALLS FROM UNKNOWN MODELS NOT PRICED. EDIT PRICES IN SETTINGS.")
                    .font(mono(8.5, .medium)).foregroundColor(amber)
            }
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Button("NEW TRIP") { meter.newTrip() }
                Button("RECEIPT") { meter.printing = meter.liveReceipt() }
                Button(mute ? "SOUND OFF" : "SOUND ON") { mute.toggle() }
            }.buttonStyle(Keycap())
        }
        .padding(16)
    }

    var display: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !meter.surging || renderingStill)) { tl in
            let glow = meter.surging ? 0.5 + 0.5 * sin(tl.date.timeIntervalSince1970 * 6) : 0
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FARE").font(mono(9)).tracking(1.5)
                    Text("$").font(mono(24))
                }.foregroundColor(.white.opacity(0.55))
                LED(value: meter.shown).frame(height: 62)
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
            .background(Color.black)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(meter.surging ? amber.opacity(0.4 + 0.6 * glow) : Color.white.opacity(0.12),
                                                             lineWidth: meter.surging ? 1.5 : 1))
            .cornerRadius(6)
            .shadow(color: amber.opacity(0.45 * glow), radius: 10)
        }
    }

    func readout(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k).label()
            Text(v).font(mono(13.5, .semibold)).foregroundColor(cabYellow)
        }
    }

    @ViewBuilder var shiftCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = meter.shift, meter.now < s.end {
                let elapsed = meter.now.timeIntervalSince(s.start), left = s.end.timeIntervalSince(meter.now)
                let pace = s.cost / max(elapsed / 60, 1)
                HStack {
                    Text("SHIFT · 5H WINDOW").label()
                    Spacer()
                    Text("\(dur(left)) LEFT").font(mono(10)).foregroundColor(.white.opacity(0.85))
                }
                Bar(fraction: elapsed / (5 * 3600), color: cabYellow)
                HStack(alignment: .top) {
                    stat("SO FAR", money(s.cost)); Spacer()
                    stat("AT THIS PACE", money(s.cost + pace * left / 60)); Spacer()
                    stat("RESETS", fmt("HH:mm", s.end))
                }
            } else {
                Text("SHIFT · 5H WINDOW").label()
                Text(meter.loaded ? "NO WINDOW OPEN. YOUR NEXT PROMPT STARTS ONE." : "READING YOUR LOGS… \(Int(meter.loadingDone * 100))%")
                    .font(mono(10, .medium)).foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045)).cornerRadius(6)
    }

    func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(mono(8)).tracking(1).foregroundColor(.white.opacity(0.4))
            Text(v).font(mono(11.5, .semibold)).foregroundColor(.white.opacity(0.9))
        }
    }

    @ViewBuilder var caps: some View {
        if capDay <= 0 && capWeek <= 0 {
            Button(action: openSettings) {
                HStack {
                    Text("SET A DAILY OR WEEKLY FARE CAP").font(mono(9.5)).tracking(0.8)
                    Spacer(); Image(systemName: "arrow.right")
                }
                .foregroundColor(cabYellow.opacity(0.85)).padding(.horizontal, 12).padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(cabYellow.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        } else {
            VStack(spacing: 9) {
                if capDay > 0 { capRow("TODAY CAP", meter.today, capDay) }
                if capWeek > 0 { capRow("7-DAY CAP", meter.week, capWeek) }
            }
        }
    }

    func capRow(_ k: String, _ spent: Double, _ cap: Double) -> some View {
        let f = spent / cap
        let color = f >= 1 ? ledRed : (f >= 0.8 ? amber : cabYellow)
        return VStack(spacing: 5) {
            HStack {
                Text(k).label()
                if f >= 1 { Text("OVER CAP").font(mono(8.5)).tracking(1).foregroundColor(ledRed) }
                Spacer()
                Text("\(money(spent)) / \(money(cap))").font(mono(10, .semibold)).foregroundColor(.white.opacity(0.85))
            }
            Bar(fraction: f, color: color)
        }
    }
}

/// The last hour of fare, one bar per minute; the newest minute is lit red.
struct Tape: View {
    var buckets: [Double]
    var body: some View {
        let top = max(buckets.max() ?? 0, 0.01)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("METER TAPE · LAST 60 MIN").label()
                Spacer()
                Text(money(buckets.reduce(0, +))).font(mono(10)).foregroundColor(.white.opacity(0.85))
            }
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(buckets.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i == buckets.count - 1 ? ledRed : cabYellow.opacity(buckets[i] > 0 ? 0.85 : 0.12))
                        .frame(height: max(2, 38 * buckets[i] / top))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 38, alignment: .bottom)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: buckets)
            HStack {
                Text("60 MIN AGO").font(mono(7.5)).foregroundColor(.white.opacity(0.35))
                Spacer()
                Text("NOW").font(mono(7.5)).foregroundColor(ledRed.opacity(0.8))
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045)).cornerRadius(6)
    }
}

// MARK: Trips tab

struct TripsTab: View {
    @ObservedObject var meter: Meter

    var body: some View {
        let groups = Dictionary(grouping: meter.trips) { Calendar.current.startOfDay(for: $0.end) }
            .sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TRIPS · ONE PER AGENT SESSION").label()
                Spacer()
                Text("\(meter.trips.count) IN 30 DAYS").label()
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            if meter.trips.isEmpty {
                Text(meter.loaded ? "NO TRIPS YET. RUN YOUR AGENT AND THE METER STARTS." : "READING YOUR LOGS… \(Int(meter.loadingDone * 100))%")
                    .font(mono(10, .medium)).foregroundColor(.white.opacity(0.6)).padding(16)
                Spacer()
            } else {
                Scroll {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.key) { day, trips in
                            Section(header: header(day, trips)) {
                                ForEach(Array(trips.enumerated()), id: \.element.id) { i, t in
                                    TripRow(trip: t) { meter.printing = meter.receipt(for: t) }.entrance(i)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func header(_ day: Date, _ trips: [Trip]) -> some View {
        let cal = Calendar.current
        let name = cal.isDateInToday(day) ? "TODAY" : cal.isDateInYesterday(day) ? "YESTERDAY" : fmt("EEE dd MMM", day)
        return HStack {
            Text(name).font(mono(9)).tracking(1.3).foregroundColor(cabYellow)
            Spacer()
            Text(money(trips.reduce(0) { $0 + $1.cost })).font(mono(9)).foregroundColor(cabYellow)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color(white: 0.1))
    }
}

struct TripRow: View {
    var trip: Trip
    var onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.project).font(mono(12)).foregroundColor(.white).lineLimit(1)
                    Text([fmt("HH:mm", trip.start) + "–" + fmt("HH:mm", trip.end), dur(trip.end.timeIntervalSince(trip.start)),
                          trip.branch.isEmpty || trip.branch == "HEAD" ? nil : trip.branch].compactMap { $0 }.joined(separator: " · "))
                        .font(mono(9, .medium)).foregroundColor(.white.opacity(0.45)).lineLimit(1)
                    HStack(spacing: 4) {
                        ForEach(trip.models.sorted { $0.value > $1.value }.prefix(3).map(\.key), id: \.self) { m in
                            Text(short(m)).font(mono(7.5)).tracking(0.5).foregroundColor(.white.opacity(0.7))
                                .padding(.horizontal, 5).padding(.vertical, 2).background(Color.white.opacity(0.08)).cornerRadius(3)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(money(trip.cost)).font(mono(14, .semibold)).foregroundColor(cabYellow)
                    Text(tokShort(trip.tokens) + " TOK").font(mono(8.5, .medium)).foregroundColor(.white.opacity(0.4))
                    Image(systemName: "printer").font(.system(size: 9)).foregroundColor(cabYellow.opacity(hover ? 0.9 : 0))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.white.opacity(hover ? 0.06 : 0))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1).padding(.leading, 16) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: Log book tab

struct LogTab: View {
    @ObservedObject var meter: Meter
    var openSettings: () -> Void
    @State private var span: Span = .week
    @AppStorage("plan") private var plan = 0.0

    var body: some View {
        let b = meter.breakdown(span)
        Scroll {
            VStack(alignment: .leading, spacing: 15) {
                Segmented(options: Span.allCases.map { ($0, $0.rawValue) }, selection: $span)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FARE · \(span.rawValue)").label()
                        LED(value: b.total, digits: 7, color: cabYellow).frame(width: 178, height: 34)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 7) {
                        kv("PER DAY", money(b.total / Double(max(b.days.count, 1))))
                        kv("TRIPS", "\(b.trips)")
                        kv("CACHE SAVED", money(b.saved))
                    }
                }
                DayBars(days: b.days) { meter.printing = meter.dayReceipt($0) }
                section("TOP PROJECTS", b.projects.prefix(5).map { ($0.0, $0.1) }, max: b.projects.first?.1 ?? 1)
                section("BY MODEL", b.models.prefix(4).map { (short($0.0), $0.1) }, max: b.models.first?.1 ?? 1)
                planCard
                HStack(spacing: 7) {
                    Button("MONTH STATEMENT") { meter.printing = meter.statement() }.buttonStyle(Keycap(accent: true))
                    Button("EXPORT CSV") { meter.exportCSV() }.buttonStyle(Keycap())
                }
            }
            .padding(16)
        }
    }

    func kv(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(mono(8.5)).tracking(1).foregroundColor(.white.opacity(0.4))
            Text(v).font(mono(11, .semibold)).foregroundColor(.white.opacity(0.9)).lineLimit(1).fixedSize()
        }
    }

    func section(_ title: String, _ rows: [(String, Double)], max: Double) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).label()
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                VStack(spacing: 4) {
                    HStack {
                        Text(r.0).font(mono(10, .semibold)).foregroundColor(.white.opacity(0.88)).lineLimit(1)
                        Spacer()
                        Text(money(r.1)).font(mono(10, .semibold)).foregroundColor(cabYellow)
                    }
                    Bar(fraction: r.1 / Swift.max(max, 0.01), color: cabYellow.opacity(0.85), height: 4)
                }.entrance(i)
            }
        }
    }

    @ViewBuilder var planCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if plan > 0 {
                Text("YOUR \(money(plan))/MO PLAN RODE").label()
                HStack(alignment: .firstTextBaseline) {
                    Text(money(meter.month)).font(mono(22, .heavy)).foregroundColor(cabYellow)
                    Text("OF API FARE THIS MONTH").font(mono(9, .medium)).foregroundColor(.white.opacity(0.6))
                }
                Text(String(format: "%.1fX ITS PRICE", meter.month / plan)).font(mono(11)).tracking(1).foregroundColor(.white)
            } else {
                Text("PLAN VALUE").label()
                Button(action: openSettings) {
                    Text("ON A PRO OR MAX PLAN? PICK IT IN SETTINGS TO SEE WHAT IT IS WORTH →")
                        .font(mono(9.5, .medium)).foregroundColor(cabYellow.opacity(0.85)).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045)).cornerRadius(6)
    }
}

/// Fare per day. Bars grow in; tap one to print that day's receipt.
struct DayBars: View {
    var days: [(Date, Double)]
    var onTap: (Date) -> Void
    @State private var grown = renderingStill
    @State private var hovered: Date?

    var body: some View {
        let top = Swift.max(days.map(\.1).max() ?? 0, 0.01)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("PER DAY · TAP A BAR FOR ITS RECEIPT").label()
                Spacer()
                if let h = hovered, let v = days.first(where: { $0.0 == h })?.1 {
                    Text("\(fmt("EEE dd", h)) \(money(v))").font(mono(9)).foregroundColor(.white)
                }
            }
            HStack(alignment: .bottom, spacing: days.count > 14 ? 2 : 6) {
                ForEach(days, id: \.0) { d in
                    let today = Calendar.current.isDateInToday(d.0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(today ? ledRed : cabYellow.opacity(d.1 > 0 ? (hovered == d.0 ? 1 : 0.8) : 0.15))
                        .frame(height: grown ? Swift.max(2, 84 * d.1 / top) : 2)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onHover { h in hovered = h ? d.0 : (hovered == d.0 ? nil : hovered) }
                        .onTapGesture { onTap(d.0) }
                }
            }
            .frame(height: 84, alignment: .bottom)
            HStack {
                Text(days.first.map { fmt("dd MMM", $0.0) } ?? "").font(mono(8)).foregroundColor(.white.opacity(0.4))
                Spacer()
                Text("TODAY").font(mono(8)).foregroundColor(ledRed.opacity(0.8))
            }
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) { grown = true } }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: days.map(\.1))
    }
}

// MARK: Settings tab

struct SettingsTab: View {
    @ObservedObject var meter: Meter
    @AppStorage("plan") private var plan = 0.0
    @AppStorage("capDay") private var capDay = 0.0
    @AppStorage("capWeek") private var capWeek = 0.0
    @AppStorage("alerts") private var alerts = true
    @AppStorage("mute") private var mute = false
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Scroll {
            VStack(alignment: .leading, spacing: 17) {
                group("YOUR PLAN") {
                    Segmented(options: [(0.0, "API"), (20.0, "PRO $20"), (100.0, "MAX $100"), (200.0, "MAX $200")], selection: $plan)
                    hint("THE LOG BOOK SHOWS HOW MUCH API FARE YOUR PLAN COVERED.")
                }
                group("FARE CAPS") {
                    HStack(spacing: 10) { capField("DAILY", $capDay); capField("7-DAY", $capWeek) }
                    hint("0 TURNS A CAP OFF. YOU GET AN ALERT AT 50, 80 AND 100%.")
                }
                group("METER") {
                    SwitchRow(label: "CAP ALERTS", on: $alerts)
                    SwitchRow(label: "TICK AND BELL SOUNDS", on: Binding(get: { !mute }, set: { mute = !$0 }))
                    SwitchRow(label: "OPEN AT LOGIN", on: Binding(get: { login }, set: { v in
                        do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                        login = SMAppService.mainApp.status == .enabled
                    }))
                }
                group("SHORTCUT") {
                    HStack(spacing: 5) {
                        ForEach(["⌥", "⌘", "T"], id: \.self) { k in
                            Text(k).font(mono(11)).foregroundColor(.white).frame(width: 24, height: 22)
                                .background(Color.white.opacity(0.1)).cornerRadius(4)
                        }
                        Text("OPENS THE METER FROM ANY APP").font(mono(9, .medium)).foregroundColor(.white.opacity(0.6)).padding(.leading, 4)
                    }
                }
                group("PRICES") {
                    hint("API LIST PRICES IN $ PER MILLION TOKENS, IN A FILE YOU CAN EDIT WHEN THEY CHANGE. RESTART TO APPLY.")
                    Button("EDIT PRICES") { NSWorkspace.shared.open(pricesURL) }.buttonStyle(Keycap())
                }
                hint("READS ~/.CLAUDE/PROJECTS ON THIS MAC. NO ACCOUNT, NO NETWORK. ON A SUBSCRIPTION, THE FARE IS WHAT THE SAME USE WOULD COST ON THE API.")
                Button("QUIT TAXI METER") { NSApp.terminate(nil) }.buttonStyle(Keycap())
            }
            .padding(16)
        }
    }

    func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) { Text(title).label(); c() }
    }

    func hint(_ s: String) -> some View {
        Text(s).font(mono(8.5, .medium)).foregroundColor(.white.opacity(0.42)).fixedSize(horizontal: false, vertical: true)
    }

    func capField(_ k: String, _ v: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(k).font(mono(9)).foregroundColor(.white.opacity(0.5))
            Text("$").font(mono(12)).foregroundColor(cabYellow)
            Group {
                if renderingStill { Text(v.wrappedValue.formatted(.number.locale(enUS))) }
                else { TextField("0", value: v, format: .number.locale(enUS)).textFieldStyle(.plain) }
            }
            .font(mono(12, .semibold)).foregroundColor(cabYellow)
            .onChange(of: v.wrappedValue) { if $0 > 0 { askNotifications() } }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.black.opacity(0.55)).cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))
    }
}

// MARK: - Receipt printer

/// The receipt feeds out of a slot at the top of the panel, with the printer's motor sound.
struct PrintOut: View {
    let r: Receipt
    @ObservedObject var meter: Meter
    @State private var fed = renderingStill
    @State private var done = renderingStill
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.72).onTapGesture { close() }
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black).frame(width: 310, height: 10)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.18)))
                    .padding(.top, 26)
                ZStack(alignment: .top) {
                    ReceiptPaper(r: r).scaleEffect(0.92, anchor: .top).offset(y: fed ? 0 : -560)
                }
                .frame(width: 310, height: 470, alignment: .top).clipped()
                HStack(spacing: 7) {
                    Button("SAVE PNG") { meter.save(r) }.buttonStyle(Keycap(accent: true))
                    Button(copied ? "COPIED" : "COPY") { meter.copy(r); withAnimation { copied = true } }.buttonStyle(Keycap())
                    Button("CLOSE") { close() }.buttonStyle(Keycap())
                }
                .padding(.horizontal, 25).padding(.top, 6)
                .opacity(done ? 1 : 0).offset(y: done ? 0 : 6)
            }
        }
        .onAppear {
            guard !fed else { return }
            meter.play("feed")
            withAnimation(.timingCurve(0.3, 0.1, 0.7, 1, duration: 1.35)) { fed = true }
            withAnimation(.easeOut(duration: 0.25).delay(1.3)) { done = true }
        }
    }

    func close() { meter.printing = nil }
}

/// Torn thermal-paper edge.
struct Zigzag: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = Int(r.width / 8)
        let step = r.width / CGFloat(n)
        p.move(to: CGPoint(x: 0, y: 0))
        for i in 0..<n {
            p.addLine(to: CGPoint(x: (CGFloat(i) + 0.5) * step, y: r.height))
            p.addLine(to: CGPoint(x: CGFloat(i + 1) * step, y: 0))
        }
        p.closeSubpath()
        return p
    }
}

struct ReceiptPaper: View {
    var r: Receipt
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                Text("TAXI METER").font(.system(size: 21, weight: .black, design: .rounded)).tracking(6)
                Checker(rows: 1).frame(height: 7)
                Text(r.title).font(mono(10)).tracking(2)
                rule
                rows(r.meta)
                rule
                rows(r.lines)
                rule
                HStack {
                    Text(r.totalLabel).font(mono(14, .heavy))
                    Spacer()
                    Text(r.total).font(mono(22, .heavy))
                }
                rows(r.foot)
                rule
                Text(r.note).font(mono(8.5, .medium)).tracking(1)
                Text("THANK YOU FOR RIDING").font(mono(10.5)).tracking(2)
            }
            .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 15)
            .background(paper)
            Zigzag().fill(paper).frame(height: 7)
        }
        .foregroundColor(Color(white: 0.1))
        .frame(width: 300)
    }

    var rule: some View {
        Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 260, y: 0)) }
            .stroke(Color(white: 0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1)
    }

    func rows(_ items: [(String, String)]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, kv in
            HStack { Text(kv.0); Spacer(); Text(kv.1) }.font(mono(10.5, .medium))
        }
    }
}

/// Receipt as saved to PNG: paper on a dark ground.
struct ReceiptView: View {
    var r: Receipt
    var body: some View { ReceiptPaper(r: r).padding(28).background(Color(white: 0.09)) }
}

/// App icon: the meter's display in a dark body under the cab roof plate.
struct IconView: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                cabYellow
                Text("TAXI").font(.system(size: 150, weight: .black, design: .rounded)).tracking(50)
                    .foregroundColor(.black).padding(.leading, 50).padding(.bottom, 96)
                Checker().frame(height: 80)
            }.frame(height: 330)
            ZStack {
                LinearGradient(colors: [Color(white: 0.14), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                LED(value: 4.20, digits: 3).frame(width: 560, height: 300)
                    .padding(50).background(Color.black).cornerRadius(40)
            }
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .padding(100)                       // macOS icon grid: 824 body inside 1024
    }
}

@MainActor func writePNG<V: View>(_ view: V, to path: String, scale: CGFloat = 2) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    if let t = r.nsImage?.tiffRepresentation,
       let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
