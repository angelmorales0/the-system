import AppKit
import CoreGraphics
import Observation

/// Counts active Mac time per quest day and sends the running total to the screen time Worker.
/// Every 15 seconds: if the screen is on and unlocked and there was input in the last 5 minutes, the time since the
/// last check counts. Every Mac counts as work. Nothing about apps, windows, or websites is read.
/// It also marks which minutes of the day were active, so the Worker counts a minute used on two Macs once.
@MainActor @Observable
final class FocusTracker {
    static let tickSeconds: TimeInterval = 15
    /// No keyboard or mouse input for this long stops the count.
    static let idleLimit: TimeInterval = 5 * 60
    /// How often a changed total is sent. A failed send waits this long too.
    static let sendSeconds: TimeInterval = 15 * 60
    /// Days older than this are deleted from the Mac.
    static let keepDays = 30
    static let dayStartHour = 5
    /// One slot per minute of a quest day, 25 hours so the fall DST day fits. Matches the Worker's 188 bytes.
    static let daySlots = 1504
    /// A minute is marked active once this much of it counted.
    static let markSeconds = 30
    /// Per-minute detail is kept only for recent days; older days keep their total.
    static let keepSlotDays = 3

    /// dayKey → active seconds.
    private(set) var seconds: [String: Double] = [:]
    /// dayKey → counted seconds in each minute of the day (0...60).
    private var slots: [String: [UInt8]] = [:]
    /// dayKey → minutes the Worker last accepted.
    private(set) var sent: [String: Int] = [:]
    /// dayKey → marked minutes the Worker last accepted.
    private var sentMarks: [String: Int] = [:]
    private(set) var lastSent: Date?
    private(set) var sendError: String?
    private(set) var paused = false

    let deviceID: String
    let deviceName: String

    private var timer: Timer?
    private var lastTick = Date()
    private var lastSendAttempt = Date.distantPast
    private var sending = false
    private var unsavedTicks = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        #if DEBUG
        let problems = Self.check()
        precondition(problems.isEmpty, problems.joined(separator: "\n"))
        #endif
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "deviceID") {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "deviceID")
        }
        deviceName = Host.current().localizedName ?? "Mac"
        load()
        observeSystem()
        let timer = Timer(timeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(now: Date()) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick(now: Date())
    }

    var todayMinutes: Int { Self.minutes(seconds[Self.dayKey(for: Date())] ?? 0) }

    var isSetUp: Bool { TrackerSettings.load() != nil }

    func tick(now: Date) {
        let key = Self.dayKey(for: now)
        // Count only the time since the last check, and never more than two checks: a gap means the Mac slept.
        let elapsed = min(max(now.timeIntervalSince(lastTick), 0), Self.tickSeconds * 2)
        lastTick = now
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if !paused, idle < Self.idleLimit, elapsed > 0 {
            seconds[key, default: 0] += elapsed
            if let slot = Self.slot(for: now) {
                var day = slots[key] ?? [UInt8](repeating: 0, count: Self.daySlots)
                day[slot] = UInt8(min(60, Double(day[slot]) + elapsed.rounded()))
                slots[key] = day
            }
            unsavedTicks += 1
        }
        if unsavedTicks >= 4 { save() }
        sendIfDue(now: now)
    }

    /// Sends now, ignoring the 15-minute wait.
    func sendNow() {
        lastSendAttempt = .distantPast
        sendIfDue(now: Date())
    }

    // MARK: - Sending

    /// Days whose total or marked minutes changed since the Worker last accepted them, oldest first.
    private var unsent: [(dayKey: String, minutes: Int, active: Data?)] {
        seconds.keys.sorted().compactMap { key in
            let minutes = Self.minutes(seconds[key] ?? 0)
            let active = slots[key].map(Self.bitmap)
            let marks = active.map(Self.popcount) ?? 0
            return sent[key] == minutes && (sentMarks[key] ?? 0) == marks ? nil : (key, minutes, active)
        }
    }

    private func sendIfDue(now: Date) {
        guard !sending, let settings = TrackerSettings.load(), now.timeIntervalSince(lastSendAttempt) >= Self.sendSeconds else { return }
        let batch = unsent
        guard !batch.isEmpty else { return }
        lastSendAttempt = now
        sending = true
        Task {
            defer { sending = false }
            do {
                for day in batch {
                    try await TrackerClient.send(day.minutes, active: day.active, dayKey: day.dayKey, deviceID: deviceID, deviceName: deviceName, settings: settings)
                    sent[day.dayKey] = day.minutes
                    sentMarks[day.dayKey] = day.active.map(Self.popcount) ?? 0
                }
                lastSent = Date()
                sendError = nil
                save()
            } catch {
                // Offline or blocked: the totals stay on this Mac and the next try is in 15 minutes.
                sendError = error.localizedDescription
            }
        }
    }

    // MARK: - Pause on lock and sleep

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pauses: [(NotificationCenter, Notification.Name, Bool)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, true),
            (workspace, NSWorkspace.screensDidWakeNotification, false),
            (workspace, NSWorkspace.willSleepNotification, true),
            (workspace, NSWorkspace.didWakeNotification, false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, false),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), true),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), false),
        ]
        for (center, name, pause) in pauses {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Close the open interval first, so time before a lock still counts and time after it does not.
                    if pause { self.tick(now: Date()) }
                    self.paused = pause
                    self.lastTick = Date()
                }
            })
        }
    }

    // MARK: - Storage

    private struct Stored: Codable {
        var seconds: [String: Double]
        var sent: [String: Int]
        /// Optional: files saved before minute detail existed have none.
        var slots: [String: [UInt8]]?
        var sentMarks: [String: Int]?
    }

    private static var fileURL: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "FocusTracker", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "minutes.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        seconds = stored.seconds
        sent = stored.sent
        slots = stored.slots ?? [:]
        sentMarks = stored.sentMarks ?? [:]
    }

    private func save() {
        unsavedTicks = 0
        for old in seconds.keys.sorted().dropLast(Self.keepDays) {
            seconds.removeValue(forKey: old)
            sent.removeValue(forKey: old)
            sentMarks.removeValue(forKey: old)
        }
        for old in slots.keys.sorted().dropLast(Self.keepSlotDays) {
            slots.removeValue(forKey: old)
        }
        guard let data = try? JSONEncoder().encode(Stored(seconds: seconds, sent: sent, slots: slots, sentMarks: sentMarks)) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Saves the open day before the app quits.
    func flush() { save() }

    // MARK: - Day keys

    static func minutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded(.down)) }

    /// Same rule as `QuestDay.key` in the iPhone app: a quest day runs from 5:00 to 5:00 local time.
    static func dayKey(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let local = calendar.component(.hour, from: date) < dayStartHour
            ? calendar.date(byAdding: .day, value: -1, to: date) ?? date
            : date
        let parts = calendar.dateComponents([.year, .month, .day], from: local)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// The minute of the quest day that `date` falls in: 0 at 5:00 local time.
    static func slot(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int? {
        let base = calendar.component(.hour, from: date) < dayStartHour
            ? calendar.date(byAdding: .day, value: -1, to: date) ?? date
            : date
        guard let start = calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: base) else { return nil }
        let slot = Int(date.timeIntervalSince(start) / 60)
        return (0..<daySlots).contains(slot) ? slot : nil
    }

    /// Bit i set when minute i counted at least `markSeconds`. Byte i >> 3, bit 1 << (i & 7), as the Worker reads it.
    static func bitmap(_ day: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: daySlots / 8)
        for (index, seconds) in day.enumerated() where Int(seconds) >= markSeconds && index < daySlots {
            bytes[index >> 3] |= 1 << UInt8(index & 7)
        }
        return Data(bytes)
    }

    static func popcount(_ data: Data) -> Int {
        data.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    static func check() -> [String] {
        var errors: [String] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let early = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 4, minute: 59)) ?? .now
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 5)) ?? .now
        if dayKey(for: early, calendar: calendar) != "2026-10-24" || dayKey(for: morning, calendar: calendar) != "2026-10-25" {
            errors.append("4:59 should be the day before and 5:00 the new day")
        }
        let nineTen = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9, minute: 10, second: 40)) ?? .now
        if slot(for: morning, calendar: calendar) != 0 || slot(for: nineTen, calendar: calendar) != 250 || slot(for: early, calendar: calendar) != 1439 {
            errors.append("5:00 should be minute 0, 9:10 minute 250, and 4:59 minute 1439")
        }
        var day = [UInt8](repeating: 0, count: daySlots)
        day[0] = 60; day[9] = 30; day[10] = 29
        let bits = bitmap(day)
        if bits.count != 188 || bits[0] != 1 || bits[1] != 2 || popcount(bits) != 2 {
            errors.append("only minutes with 30 s or more should be marked, at byte i >> 3, bit i & 7")
        }
        if minutes(3_659) != 60 || minutes(59) != 0 {
            errors.append("minutes should round down")
        }
        if TrackerSettings(endpoint: "https://x.workers.dev/", token: "t").baseURL?.absoluteString != "https://x.workers.dev"
            || TrackerSettings(endpoint: "http://x.workers.dev", token: "t").baseURL != nil
            || TrackerSettings(endpoint: "https://x.workers.dev", token: " ").baseURL != nil {
            errors.append("only an https endpoint with a token should be accepted")
        }
        return errors
    }
}

/// The Worker address and token, typed in the setup window. Stored in this Mac's preferences.
struct TrackerSettings: Equatable {
    static let endpointKey = "endpoint"
    static let tokenKey = "token"

    var endpoint: String
    var token: String

    /// HTTPS only, trailing slash removed. Nil when the address or token is missing.
    var baseURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URL(string: trimmed), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    static func load(from defaults: UserDefaults = .standard) -> TrackerSettings? {
        let settings = TrackerSettings(endpoint: defaults.string(forKey: endpointKey) ?? "", token: defaults.string(forKey: tokenKey) ?? "")
        return settings.baseURL == nil ? nil : settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.endpointKey)
        defaults.set(token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.tokenKey)
    }
}

enum TrackerClient {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    static func send(_ minutes: Int, active: Data?, dayKey: String, deviceID: String, deviceName: String, settings: TrackerSettings) async throws {
        guard let base = settings.baseURL else { throw Failure(errorDescription: "Not set up") }
        var request = URLRequest(url: base.appending(path: "v1/screentime/mac"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["deviceID": deviceID, "deviceName": deviceName, "dayKey": dayKey, "minutes": minutes]
        if let active { body["active"] = active.base64EncodedString() }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try check(try await URLSession.shared.data(for: request).1)
    }

    /// Reaches /health without the token, then the snapshot with it, so the window can say which part failed.
    static func test(_ settings: TrackerSettings) async -> String {
        guard let base = settings.baseURL else { return "Enter an https address and the token." }
        do {
            try check(try await URLSession.shared.data(from: base.appending(path: "health")).1)
        } catch {
            return "This Mac cannot reach the Worker: \(error.localizedDescription)"
        }
        var components = URLComponents(url: base.appending(path: "v1/integrations/screentime/snapshot"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "day", value: FocusTracker.dayKey(for: Date()))]
        guard let url = components?.url else { return "The address is not valid." }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        do {
            try check(try await URLSession.shared.data(for: request).1)
            return "Connected. Minutes will be sent every 15 minutes."
        } catch {
            return "The Worker answered, but the token was refused: \(error.localizedDescription)"
        }
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure(errorDescription: "No answer") }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(errorDescription: http.statusCode == 401 ? "Wrong token (401)" : "HTTP \(http.statusCode)")
        }
    }
}
