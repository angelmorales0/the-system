import AppKit
import CoreGraphics
import Observation

/// Counts active Mac time per quest day and saves finished days to iCloud.
/// Every 15 seconds: if the screen is on and unlocked and there was input in the last 5 minutes, the time since the
/// last check counts. It counts as social when the front app is a social app, or Safari or Chrome shows a social site.
@MainActor @Observable
final class FocusTracker {
    static let tickSeconds: TimeInterval = 15
    /// A failed or skipped upload waits this long before the next try.
    static let retrySeconds: TimeInterval = 10 * 60
    /// Days older than this are deleted from the Mac.
    static let keepDays = 60

    private(set) var days: [String: MacScreenDay] = [:]
    private(set) var uploaded: Set<String> = []
    private(set) var lastSync: Date?
    private(set) var syncError: String?
    /// True after macOS refused Automation for a browser, so social sites in it do not count.
    private(set) var browserBlocked = false
    private(set) var paused = false

    let deviceID: String
    let deviceName: String

    private var timer: Timer?
    private var lastTick = Date()
    private var lastUploadAttempt = Date.distantPast
    private var unsavedTicks = 0
    private var observers: [NSObjectProtocol] = []

    init() {
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

    var today: MacScreenDay { days[MacScreenTime.dayKey(for: Date())] ?? emptyDay(MacScreenTime.dayKey(for: Date())) }

    /// Finished days not yet in iCloud.
    var pending: [MacScreenDay] {
        days.values.filter { $0.complete && !uploaded.contains($0.dayKey) }.sorted { $0.dayKey < $1.dayKey }
    }

    func tick(now: Date) {
        let key = MacScreenTime.dayKey(for: now)
        // Count only the time since the last check, and never more than two checks: a gap means the Mac slept.
        let elapsed = min(max(now.timeIntervalSince(lastTick), 0), Self.tickSeconds * 2)
        lastTick = now
        closeDays(before: key)

        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if !paused, idle < MacScreenTime.idleLimit, elapsed > 0 {
            var day = days[key] ?? emptyDay(key)
            day.screenSeconds += elapsed
            if frontIsSocial() { day.socialSeconds += elapsed }
            days[key] = day
            unsavedTicks += 1
        }
        if unsavedTicks >= 4 { save() }
        uploadIfDue(now: now)
    }

    /// Uploads now, ignoring the retry wait.
    func syncNow() {
        lastUploadAttempt = .distantPast
        uploadIfDue(now: Date())
    }

    // MARK: - Social detection

    private static let browserScripts = [
        "com.apple.Safari": "tell application id \"com.apple.Safari\" to get URL of front document",
        "com.google.Chrome": "tell application id \"com.google.Chrome\" to get URL of active tab of front window",
    ]

    private func frontIsSocial() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        if MacScreenTime.socialBundleIDs.contains(bundleID) { return true }
        // The browser is in front, so it is already running: the script never launches it.
        guard let source = Self.browserScripts[bundleID], let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int {
            // -1743: the user has not allowed Automation for this browser.
            if code == -1743 { browserBlocked = true }
            return false
        }
        browserBlocked = false
        guard let address = result.stringValue, let host = URL(string: address)?.host() else { return false }
        return MacScreenTime.isSocial(host: host)
    }

    // MARK: - Days

    private func emptyDay(_ key: String) -> MacScreenDay {
        MacScreenDay(dayKey: key, screenSeconds: 0, socialSeconds: 0, complete: false, deviceID: deviceID, deviceName: deviceName)
    }

    /// Every day before `key` is finished. Old days are dropped.
    private func closeDays(before key: String) {
        var changed = false
        for (dayKey, day) in days where dayKey < key && !day.complete {
            days[dayKey]?.complete = true
            changed = true
        }
        for old in days.keys.sorted().dropLast(Self.keepDays) {
            days.removeValue(forKey: old)
            uploaded.remove(old)
            changed = true
        }
        if changed { save() }
    }

    private func uploadIfDue(now: Date) {
        let batch = pending
        guard !batch.isEmpty, now.timeIntervalSince(lastUploadAttempt) >= Self.retrySeconds else { return }
        lastUploadAttempt = now
        #if CLOUDKIT_SYNC
        Task {
            do {
                try await MacScreenTimeCloud.upload(batch)
                uploaded.formUnion(batch.map(\.dayKey))
                lastSync = Date()
                syncError = nil
                save()
            } catch {
                // Offline or iCloud is busy: the days stay pending and the next try is in 10 minutes.
                syncError = error.localizedDescription
            }
        }
        #else
        syncError = "iCloud is off in this build. Sign the app with your team to sync."
        #endif
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
                    if !pause { self.syncNow() }
                }
            })
        }
    }

    // MARK: - Storage

    private struct Stored: Codable {
        var days: [MacScreenDay]
        var uploaded: [String]
    }

    private static var fileURL: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "FocusTracker", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "days.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        days = Dictionary(stored.days.map { ($0.dayKey, $0) }, uniquingKeysWith: { first, _ in first })
        uploaded = Set(stored.uploaded)
    }

    private func save() {
        unsavedTicks = 0
        let stored = Stored(days: days.values.sorted { $0.dayKey < $1.dayKey }, uploaded: uploaded.sorted())
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Saves the open day before the app quits.
    func flush() { save() }
}
