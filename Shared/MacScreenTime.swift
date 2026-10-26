import Foundation

#if CLOUDKIT_SYNC
import CloudKit
#endif

/// One quest day of Mac use from the FocusTracker menu-bar app. Compiled into the iPhone app and the Mac tracker.
/// Only these totals leave the Mac: no app names, window titles, or web addresses.
nonisolated struct MacScreenDay: Codable, Equatable, Sendable {
    /// "YYYY-MM-DD". The quest day runs from 5:00 to 5:00 local time, the same as `QuestDay` in the app.
    var dayKey: String
    /// Active seconds: screen unlocked and input within `MacScreenTime.idleLimit`.
    var screenSeconds: Double
    /// Active seconds in a social app, or in Safari or Chrome on a social site.
    var socialSeconds: Double
    /// True after the day's 5:00 end. Only complete days are uploaded and scored.
    var complete: Bool
    var deviceID: String
    var deviceName: String

    var screenMinutes: Int { Int((screenSeconds / 60).rounded(.down)) }
    var socialMinutes: Int { Int((socialSeconds / 60).rounded(.down)) }
}

nonisolated enum MacScreenTime {
    /// The iCloud container in both apps' entitlements. Only this Apple ID can read its private database.
    static let containerID = "iCloud.com.angelmorales.thesystem"
    static let dayRecordType = "MacScreenDay"
    static let devicesRecordType = "MacDevices"
    /// One record lists every Mac's device id, so the iPhone can fetch day records by name without a query index.
    static let devicesRecordName = "mac-devices"
    /// Days the iPhone asks for: the FOC window.
    static let fetchDays = 30
    static let dayStartHour = 5
    /// No keyboard or mouse input for this long stops the count.
    static let idleLimit: TimeInterval = 5 * 60

    static func recordName(dayKey: String, deviceID: String) -> String { "\(dayKey)|\(deviceID)" }

    /// Same rule as `QuestDay.key` in the app: before 5:00 is still the day before.
    static func dayKey(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let local = calendar.component(.hour, from: date) < dayStartHour
            ? calendar.date(byAdding: .day, value: -1, to: date) ?? date
            : date
        let parts = calendar.dateComponents([.year, .month, .day], from: local)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// The `count` day keys before `dayKey`, newest first. `dayKey` itself is not included.
    static func previousDayKeys(_ count: Int, before dayKey: String, calendar: Calendar = .autoupdatingCurrent) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let base = formatter.date(from: dayKey) else { return [] }
        return (1...max(count, 1)).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: base).map { formatter.string(from: $0) }
        }
    }

    /// Social sites. A host matches itself and its subdomains, so "m.facebook.com" counts.
    static let socialDomains: Set<String> = [
        "x.com", "twitter.com", "instagram.com", "facebook.com", "reddit.com",
        "tiktok.com", "youtube.com", "threads.net", "snapchat.com", "linkedin.com",
        "pinterest.com", "tumblr.com", "bsky.app", "discord.com",
    ]

    /// Mac apps that count as social media.
    static let socialBundleIDs: Set<String> = [
        "com.hnc.Discord", "com.facebook.archon", "maccatalyst.com.atebits.Tweetie2",
    ]

    static func isSocial(host: String) -> Bool {
        let host = host.lowercased()
        return socialDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - Self-check

    static func check() -> [String] {
        var errors: [String] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let early = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 4, minute: 59)) ?? .now
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 5)) ?? .now
        if dayKey(for: early, calendar: calendar) != "2026-10-24" || dayKey(for: morning, calendar: calendar) != "2026-10-25" {
            errors.append("4:59 should be the day before and 5:00 the new day")
        }
        if previousDayKeys(2, before: "2026-03-01", calendar: calendar) != ["2026-02-28", "2026-02-27"] {
            errors.append("previous day keys should cross the month, got \(previousDayKeys(2, before: "2026-03-01", calendar: calendar))")
        }
        if !isSocial(host: "www.YouTube.com") || !isSocial(host: "x.com") || isSocial(host: "box.com") || isSocial(host: "notx.com") {
            errors.append("social host matching is wrong")
        }
        let day = MacScreenDay(dayKey: "2026-10-24", screenSeconds: 3_659, socialSeconds: 59, complete: true, deviceID: "a", deviceName: "Mac")
        if day.screenMinutes != 60 || day.socialMinutes != 0 {
            errors.append("minutes should round down, got \(day.screenMinutes) and \(day.socialMinutes)")
        }
        return errors
    }
}

#if CLOUDKIT_SYNC
/// Reads and writes Mac days in the private iCloud database. Built only when the app is signed with the iCloud entitlement:
/// CloudKit stops the app when the entitlement is missing, so unsigned check builds leave `CLOUDKIT_SYNC` off.
nonisolated enum MacScreenTimeCloud {
    private static var database: CKDatabase { CKContainer(identifier: MacScreenTime.containerID).privateCloudDatabase }

    /// Saves complete days and adds this Mac to the device list. Saving a day again replaces its record.
    static func upload(_ days: [MacScreenDay]) async throws {
        guard let first = days.first else { return }
        try await register(deviceID: first.deviceID)
        let records = days.map { day -> CKRecord in
            let record = CKRecord(recordType: MacScreenTime.dayRecordType, recordID: CKRecord.ID(recordName: MacScreenTime.recordName(dayKey: day.dayKey, deviceID: day.deviceID)))
            record["dayKey"] = day.dayKey as NSString
            record["screenSeconds"] = day.screenSeconds as NSNumber
            record["socialSeconds"] = day.socialSeconds as NSNumber
            record["complete"] = (day.complete ? 1 : 0) as NSNumber
            record["deviceID"] = day.deviceID as NSString
            record["deviceName"] = day.deviceName as NSString
            return record
        }
        let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys)
        for (_, saved) in result.saveResults {
            _ = try saved.get()
        }
    }

    /// Every Mac's complete days in the `MacScreenTime.fetchDays` before `todayKey`. Missing days are skipped.
    static func fetchDays(before todayKey: String) async throws -> [MacScreenDay] {
        let deviceIDs = try await registeredDevices()
        guard !deviceIDs.isEmpty else { return [] }
        let dayKeys = MacScreenTime.previousDayKeys(MacScreenTime.fetchDays, before: todayKey)
        let ids = deviceIDs.flatMap { device in dayKeys.map { CKRecord.ID(recordName: MacScreenTime.recordName(dayKey: $0, deviceID: device)) } }
        let results = try await database.records(for: ids)
        return results.values.compactMap { result -> MacScreenDay? in
            guard let record = try? result.get(),
                  let dayKey = record["dayKey"] as? String,
                  let deviceID = record["deviceID"] as? String else { return nil }
            return MacScreenDay(
                dayKey: dayKey,
                screenSeconds: (record["screenSeconds"] as? NSNumber)?.doubleValue ?? 0,
                socialSeconds: (record["socialSeconds"] as? NSNumber)?.doubleValue ?? 0,
                complete: ((record["complete"] as? NSNumber)?.intValue ?? 0) == 1,
                deviceID: deviceID,
                deviceName: record["deviceName"] as? String ?? "Mac"
            )
        }
    }

    private static func registeredDevices() async throws -> [String] {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: MacScreenTime.devicesRecordName))
            return record["deviceIDs"] as? [String] ?? []
        } catch let error as CKError where error.code == .unknownItem {
            return []
        }
    }

    private static func register(deviceID: String) async throws {
        let devices = try await registeredDevices()
        guard !devices.contains(deviceID) else { return }
        let record = CKRecord(recordType: MacScreenTime.devicesRecordType, recordID: CKRecord.ID(recordName: MacScreenTime.devicesRecordName))
        record["deviceIDs"] = (devices + [deviceID]) as NSArray
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }
}
#endif
