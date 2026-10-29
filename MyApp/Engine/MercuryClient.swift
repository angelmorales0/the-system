import Foundation

/// Mercury settings the backend read from its environment or a JSON file. Not secret, so they stay in UserDefaults.
/// The Read Only token is not here: it is in the Keychain.
nonisolated struct MercurySettings: Codable, Equatable {
    static let key = "com.angelmorales.thesystem.mercury.settings"
    static let categoryTags: Set<String> = ["necessary", "discretionary", "transfer", "income", "ignore"]

    /// Monthly budget in USD. Nil shows budget adherence as not configured.
    var monthlyBudgetUsd: Double?
    /// When the budget was last set. A budget stays locked for `budgetLockMonths` after it, so it cannot be
    /// raised in a bad month. Nil for a save from before the lock, which can be set once.
    var budgetSetAt: Date?
    /// Share of income held back for taxes, 0 to 0.6.
    var taxReserveRate: Double = 0
    /// Local hour (America/Los_Angeles) after which today's spend counts as settled.
    var settleHour: Int = 21
    /// Count only credits from counterparties that match. Empty counts every other credit.
    var incomeCounterpartyRegex: String = ""
    /// Mercury category name → necessary, discretionary, transfer, income, or ignore.
    var categoryMap: [String: String] = [:]
    /// Empty uses production. A sandbox host must be https.
    var baseURL: String = ""

    static func load(from defaults: UserDefaults = .standard) -> MercurySettings {
        guard let data = defaults.data(forKey: key), let settings = try? JSONDecoder().decode(MercurySettings.self, from: data) else { return MercurySettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    var budget: Double? { monthlyBudgetUsd.flatMap { $0 > 0 ? $0 : nil } }

    static let budgetLockMonths = 3

    /// The day the budget can change again, or nil when it was never set.
    func budgetUnlockDate(calendar: Calendar = .current) -> Date? {
        guard budget != nil, let setAt = budgetSetAt else { return nil }
        return calendar.date(byAdding: .month, value: Self.budgetLockMonths, to: setAt)
    }

    func canSetBudget(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let unlock = budgetUnlockDate(calendar: calendar) else { return true }
        return now >= unlock
    }

    /// Sets the budget and starts its 3-month lock. False, and no change, while the lock holds or the amount is not positive.
    mutating func setBudget(_ amount: Double, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard amount > 0, amount.isFinite, canSetBudget(now: now, calendar: calendar) else { return false }
        monthlyBudgetUsd = amount
        budgetSetAt = now
        return true
    }
    var taxRate: Double { min(max(taxReserveRate, 0), 0.6) }
    var hour: Int { min(max(settleHour, 0), 23) }
    var overrides: [String: String] { categoryMap.filter { Self.categoryTags.contains($0.value) } }

    var base: String {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if raw.hasPrefix("https://"), !raw.contains(" "), !raw.contains("@") { return raw }
        return "https://api.mercury.com/api/v1"
    }

    /// `Restaurants=necessary` lines, for the settings text box.
    var categoryText: String {
        categoryMap.keys.sorted().map { "\($0)=\(categoryMap[$0] ?? "")" }.joined(separator: "\n")
    }

    static func categoryMap(from text: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, categoryTags.contains(parts[1].lowercased()) {
                map[parts[0]] = parts[1].lowercased()
            }
        }
        return map
    }
}

/// The cached Mercury data: account balances and slim transactions. No token, no account or routing numbers.
nonisolated struct MercuryLedger: Codable, Equatable {
    var accounts: [JSONValue] = []
    var transactions: [JSONValue] = []
    var syncedAt: Date?
}

/// Mercury Read Only API from the phone. Port of backend/mercury.py without webhooks: the phone polls transactions,
/// caches summaries on the device, and builds the day and month FIN summaries from that cache.
enum MercuryClient {
    static let defaultBase = "https://api.mercury.com/api/v1"
    static let ytdGoalUsd = 500_000.0
    // Undecided defaults, not a locked budget.
    static let dailySoftCapUsd = 40.0
    static let weeklySoftCapUsd = 280.0
    static let balanceHardFloorUsd = 500.0
    static let paceNormal = 0.75
    static let paceCaution = 1.00
    static let paceWarning = 1.25
    static let defaultSettleHour = 21
    static let pageLimit = 1000
    static let maxPages = 30
    static let maxTaxReserveRate = 0.6
    /// A new sync runs when the cache is older than this.
    static let syncSeconds: TimeInterval = 15 * 60

    static let necessary: Set<String> = [
        "Grocery", "Utilities", "Insurance", "Medical", "Taxes", "FacilitiesExpenses", "GovernmentServices", "InternetAndTelephone",
        "Legal", "Education", "FuelAndGas", "VehicleExpenses", "Fees", "ProfessionalServices", "Shipping", "OfficeSupplies",
    ]
    static let discretionary: Set<String> = [
        "Restaurants", "Entertainment", "AlcoholAndBars", "Retail", "FoodDelivery", "Clothing", "Gambling", "Lodging", "Airlines",
        "CarRental", "OtherTravel", "RideshareAndTaxis", "Electronics", "BooksAndNewspaper", "Memberships", "Conferences", "Software",
        "Advertising", "Charity", "Political", "Parking", "GroundTransportation", "Other",
    ]
    static let transferKinds: Set<String> = ["internalTransfer", "treasuryTransfer"]
    static let ignoredKinds: Set<String> = ["interestPayment"]
    static let deadStatuses: Set<String> = ["cancelled", "failed", "blocked", "reversed"]
    static let incomeStatuses: Set<String> = ["sent"]
    static let rentHints = ["rent", "landlord"]

    static var la: TimeZone { OnDeviceTime.losAngeles }

    // MARK: - Network

    /// Today's snapshot and the two FIN months. Syncs first when the cache is stale.
    static func load(dayKey: String, months: [String], now: Date = .now) async -> (day: MercuryDayReading, months: [FinanceMonth]) {
        let settings = MercurySettings.load()
        guard let token = SecretStore.read(.mercuryToken) else {
            return (empty(dayKey, reason: "TODO: Type a Mercury Read Only token in Status → Connections.", configured: false), [])
        }
        var ledger = loadLedger()
        if ledger.syncedAt.map({ now.timeIntervalSince($0) > syncSeconds }) ?? true {
            if let fresh = await sync(token: token, settings: settings, now: now) {
                ledger = fresh
            }
        }
        guard ledger.syncedAt != nil else {
            return (empty(dayKey, reason: "TODO: Mercury token is set, but the first sync failed. Test it in Status → Connections.", configured: true), [])
        }
        let day = snapshot(ledger: ledger, day: dayKey, settings: settings, now: now)
        let finance = months.map { monthSummary(ledger.transactions, month: $0, settings: settings, now: now) }.map(\.financeMonth)
        return (day, finance)
    }

    static func test() async -> (ok: Bool, message: String) {
        guard let token = SecretStore.read(.mercuryToken) else { return (false, "Type the token first.") }
        let settings = MercurySettings.load()
        guard let url = OnDeviceHTTP.url("\(settings.base)/accounts"), let reply = await OnDeviceHTTP.get(url, headers: StravaClient.bearer(token), timeout: 20) else {
            return (false, "Cannot reach Mercury.")
        }
        guard (200..<300).contains(reply.status) else {
            return (false, reply.status == 401 ? "Mercury refused the token." : "Mercury answered with HTTP \(reply.status).")
        }
        guard let ledger = await sync(token: token, settings: settings, now: .now) else { return (false, "Mercury accounts answered, but the transaction sync failed.") }
        return (true, "Connected. \(ledger.accounts.count) accounts, \(ledger.transactions.count) transactions since \(syncStart(.now)).")
    }

    /// Lists accounts and transactions from the sync start through tomorrow, then saves the slim cache.
    static func sync(token: String, settings: MercurySettings, now: Date) async -> MercuryLedger? {
        let end = OnDeviceTime.addDays(OnDeviceTime.dayKey(now, zone: la), 1)
        guard let accounts = await listRemote("/accounts", token: token, base: settings.base, query: [], itemKey: "accounts"),
              let transactions = await listRemote("/transactions", token: token, base: settings.base, query: [("start", syncStart(now)), ("end", end)], itemKey: "transactions") else {
            return nil
        }
        let ledger = MercuryLedger(accounts: accounts.map(publicAccount), transactions: transactions.map(slimTransaction), syncedAt: now)
        saveLedger(ledger)
        return ledger
    }

    private static func listRemote(_ path: String, token: String, base: String, query: [(String, String)], itemKey: String) async -> [JSONValue]? {
        var failed = false
        var items: [JSONValue] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<maxPages {
            var params = query + [("limit", String(pageLimit)), ("order", "asc")]
            if let cursor { params.append(("start_after", cursor)) }
            guard let url = OnDeviceHTTP.url(base + path, params),
                  let payload = await OnDeviceHTTP.getJSON(url, headers: StravaClient.bearer(token), timeout: 20),
                  let batch = payload[itemKey]?.arrayValue else {
                failed = true
                break
            }
            let rows = batch.filter { $0.objectValue != nil }
            items += rows
            let next = payload["page"]?["nextPage"]?.stringValue
            guard let next, !next.isEmpty, !seen.contains(next), !rows.isEmpty else { break }
            seen.insert(next)
            cursor = next
        }
        return failed ? nil : items
    }

    /// Walks a `start_after` / `page.nextPage` cursor. Stops on a repeat or an empty page. Pure, for the self-check.
    static func collectCursorPages(maxPages: Int = maxPages, _ fetch: (String?) -> ([JSONValue], String?)) -> [JSONValue] {
        var items: [JSONValue] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<maxPages {
            let (batch, next) = fetch(cursor)
            items += batch
            guard let next, !seen.contains(next), !batch.isEmpty else { break }
            seen.insert(next)
            cursor = next
        }
        return items
    }

    // MARK: - Cache (Application Support, not the App Group, never the token)

    static var ledgerURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("mercury_ledger.json")
    }

    static func loadLedger() -> MercuryLedger {
        guard let url = ledgerURL, let data = try? Data(contentsOf: url) else { return MercuryLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MercuryLedger.self, from: data)) ?? MercuryLedger()
    }

    static func saveLedger(_ ledger: MercuryLedger) {
        guard var url = ledgerURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(ledger) else { return }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func deleteLedger() {
        if let url = ledgerURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Pure summaries

    static func publicAccount(_ account: JSONValue) -> JSONValue {
        jsonObject([
            "id": account["id"],
            "name": .string(account["name"]?.stringValue ?? account["nickname"]?.stringValue ?? ""),
            "kind": .string(account["kind"]?.stringValue ?? ""),
            "availableBalance": account["availableBalance"],
            "currentBalance": account["currentBalance"],
        ])
    }

    static func slimTransaction(_ txn: JSONValue) -> JSONValue {
        let category = categoryName(txn)
        return jsonObject([
            "id": txn["id"],
            "amount": txn["amount"],
            "mercuryCategory": category.isEmpty ? nil : .string(category),
            "kind": txn["kind"],
            "status": txn["status"],
            "postedAt": txn["postedAt"],
            "createdAt": txn["createdAt"],
            "counterpartyName": .string(txn["counterpartyName"]?.stringValue ?? ""),
            "accountId": txn["accountId"],
        ])
    }

    static func categoryName(_ txn: JSONValue) -> String {
        switch txn["mercuryCategory"] {
        case .object(let raw): return raw["name"]?.stringValue ?? ""
        case .string(let raw): return raw
        default: return txn["merchant"]?["mercuryCategory"]?.stringValue ?? ""
        }
    }

    static func amount(_ txn: JSONValue) -> Double? {
        switch txn["amount"] {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .null, nil: return 0
        default: return nil
        }
    }

    static func incomeAllowed(_ txn: JSONValue, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return true }
        let name = txn["counterpartyName"]?.stringValue ?? ""
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Necessary, discretionary, income, transfer, or ignore. Negative amounts are money out.
    /// Internal transfers and interest never count as income or spend.
    static func classify(_ txn: JSONValue, overrides: [String: String], incomePattern: String = "") -> String {
        let kind = txn["kind"]?.stringValue ?? ""
        if transferKinds.contains(kind) { return "transfer" }
        if ignoredKinds.contains(kind) { return "ignore" }
        let status = txn["status"]?.stringValue ?? ""
        if deadStatuses.contains(status) { return "ignore" }
        guard let amount = amount(txn) else { return "ignore" }
        if amount > 0 {
            if !status.isEmpty, !incomeStatuses.contains(status) { return "ignore" }
            return incomeAllowed(txn, pattern: incomePattern) ? "income" : "ignore"
        }
        if amount == 0 { return "ignore" }
        let category = categoryName(txn)
        if let mapped = overrides[category], !mapped.isEmpty { return mapped }
        let name = (txn["counterpartyName"]?.stringValue ?? "").lowercased()
        if rentHints.contains(where: { name.contains($0) }) { return "necessary" }
        if necessary.contains(category) { return "necessary" }
        return "discretionary"
    }

    /// The America/Los_Angeles day of an ISO time, or the text itself when it is already a date.
    static func localDay(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }
        if let date = OnDeviceTime.parse(text) { return OnDeviceTime.dayKey(date, zone: la) }
        if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return text }
        return ""
    }

    static func when(_ txn: JSONValue) -> String {
        let posted = txn["postedAt"]?.stringValue ?? ""
        return localDay(posted.isEmpty ? (txn["createdAt"]?.stringValue ?? "") : posted)
    }

    static func laParts(_ now: Date) -> (day: String, hour: Int, minute: Int) {
        let parts = OnDeviceTime.calendar(la).dateComponents([.hour, .minute], from: now)
        return (OnDeviceTime.dayKey(now, zone: la), parts.hour ?? 0, parts.minute ?? 0)
    }

    static func dayFraction(_ day: String, now: Date) -> Double {
        let local = laParts(now)
        if local.day > day { return 1 }
        if local.day < day { return 1.0 / 24 }
        return max(Double(local.hour * 60 + local.minute) / (24 * 60), 1.0 / 24)
    }

    /// NORMAL / CAUTION / WARNING / CRITICAL from burn against the soft caps. A balance under the floor is at least WARNING.
    static func paceState(discretionaryToday: Double, discretionary7d: Double, availableBalance: Double?, fraction: Double) -> String {
        let dailyBudget = dailySoftCapUsd * max(fraction, 1.0 / 24)
        let ratio = max(dailyBudget > 0 ? discretionaryToday / dailyBudget : 0, discretionary7d / weeklySoftCapUsd)
        let state = ratio < paceNormal ? "NORMAL" : ratio < paceCaution ? "CAUTION" : ratio < paceWarning ? "WARNING" : "CRITICAL"
        if let availableBalance, availableBalance < balanceHardFloorUsd, state == "NORMAL" || state == "CAUTION" { return "WARNING" }
        return state
    }

    static func isSettled(_ day: String, now: Date, settleHour: Int) -> Bool {
        let local = laParts(now)
        if local.day > day { return true }
        if local.day < day { return false }
        return local.hour >= settleHour
    }

    static func lowestAvailable(_ accounts: [JSONValue]) -> Double? {
        accounts.compactMap { $0["availableBalance"]?.doubleValue }.min()
    }

    static func empty(_ dayKey: String, reason: String, configured: Bool) -> MercuryDayReading {
        var reading = MercuryDayReading.disconnected(dayKey: dayKey, reason: reason)
        reading.configured = configured
        return reading
    }

    /// The day's spend split, 7-day discretionary, YTD income, pace, and settlement.
    static func summarize(_ transactions: [JSONValue], day: String, accounts: [JSONValue], settings: MercurySettings, now: Date) -> MercuryDayReading {
        let overrides = settings.overrides
        let yearStart = "\(day.prefix(4))-01-01"
        let windowStart = OnDeviceTime.addDays(day, -6)
        var discretionaryToday = 0.0, necessaryToday = 0.0, discretionary7d = 0.0, income = 0.0
        for txn in transactions where txn.objectValue != nil {
            let tag = classify(txn, overrides: overrides, incomePattern: settings.incomeCounterpartyRegex)
            let date = when(txn)
            guard let amount = amount(txn) else { continue }
            if tag == "income", yearStart <= date, date <= day { income += amount }
            if tag == "discretionary", date == day { discretionaryToday += abs(amount) }
            if tag == "necessary", date == day { necessaryToday += abs(amount) }
            if tag == "discretionary", windowStart <= date, date <= day { discretionary7d += abs(amount) }
        }
        let state = paceState(discretionaryToday: discretionaryToday, discretionary7d: discretionary7d,
                              availableBalance: lowestAvailable(accounts), fraction: dayFraction(day, now: now))
        return MercuryDayReading(
            available: true, configured: true, reason: "", dayKey: day,
            discretionarySpendUsd: round2(discretionaryToday), necessarySpendUsd: round2(necessaryToday), capUsd: dailySoftCapUsd,
            paceState: state, ytdIncomeUsd: round2(income), ytdGoalUsd: ytdGoalUsd, discretionary7dUsd: round2(discretionary7d),
            underCap: discretionaryToday <= dailySoftCapUsd + 0.001, settled: isSettled(day, now: now, settleHour: settings.hour), synced: true
        )
    }

    static func snapshot(ledger: MercuryLedger, day: String, settings: MercurySettings, now: Date) -> MercuryDayReading {
        summarize(ledger.transactions, day: day, accounts: ledger.accounts, settings: settings, now: now)
    }

    /// January 1, or the first day of last month when that is earlier (in January the newest complete month is December).
    static func syncStart(_ now: Date) -> String {
        let today = OnDeviceTime.dayKey(now, zone: la)
        let yearStart = "\(today.prefix(4))-01-01"
        let firstOfMonth = "\(today.prefix(7))-01"
        let lastMonth = "\(OnDeviceTime.addDays(firstOfMonth, -1).prefix(7))-01"
        return min(yearStart, lastMonth)
    }

    // MARK: - Monthly FIN summary
    //
    // Data limits: Mercury sees deposits, not taxes, so post-tax income is income times (1 - tax reserve rate).
    // It sees Mercury accounts only, so spend elsewhere is invisible. It has no budget: the settings give one.

    struct MonthSummary: Equatable {
        var month: String
        var incomeUsd: Double
        var postTaxIncomeUsd: Double
        var spendingUsd: Double
        var necessaryUsd: Double
        var discretionaryUsd: Double
        var budgetUsd: Double?
        var taxReserveRate: Double
        var complete: Bool

        var financeMonth: FinanceMonth {
            FinanceMonth(month: month, postTaxIncomeUsd: postTaxIncomeUsd, spendingUsd: spendingUsd, budgetUsd: budgetUsd, complete: complete)
        }
    }

    static func validMonth(_ month: String) -> Bool {
        month.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil
    }

    static func nextMonth(_ month: String) -> String {
        let year = Int(month.prefix(4)) ?? 1970
        let number = Int(month.dropFirst(5).prefix(2)) ?? 1
        return number == 12 ? String(format: "%04d-01", year + 1) : String(format: "%04d-%02d", year, number + 1)
    }

    /// True when the month has ended in America/Los_Angeles.
    static func monthComplete(_ month: String, now: Date) -> Bool {
        OnDeviceTime.dayKey(now, zone: la) >= "\(nextMonth(month))-01"
    }

    static func monthSummary(_ transactions: [JSONValue], month: String, settings: MercurySettings, now: Date) -> MonthSummary {
        let overrides = settings.overrides
        let rate = settings.taxRate
        var income = 0.0, necessaryTotal = 0.0, discretionaryTotal = 0.0
        for txn in transactions where txn.objectValue != nil {
            guard when(txn).prefix(7) == month, let amount = amount(txn) else { continue }
            switch classify(txn, overrides: overrides, incomePattern: settings.incomeCounterpartyRegex) {
            case "income": income += amount
            case "necessary": necessaryTotal += abs(amount)
            case "discretionary": discretionaryTotal += abs(amount)
            default: break
            }
        }
        return MonthSummary(
            month: month, incomeUsd: round2(income), postTaxIncomeUsd: round2(income * (1 - rate)),
            spendingUsd: round2(necessaryTotal + discretionaryTotal), necessaryUsd: round2(necessaryTotal), discretionaryUsd: round2(discretionaryTotal),
            budgetUsd: settings.budget, taxReserveRate: rate, complete: monthComplete(month, now: now)
        )
    }

    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: - Self-check (runs in DEBUG at launch). Fixtures from backend/mercury.py.

    static func check() -> [String] {
        var errors: [String] = []
        let calendar = Calendar(identifier: .gregorian)
        let day1 = Date(timeIntervalSince1970: 1_780_000_000)
        var settings = MercurySettings()
        if !settings.canSetBudget(now: day1) || !settings.setBudget(2_000, now: day1, calendar: calendar) || settings.budget != 2_000 {
            errors.append("a budget should be settable once")
        }
        let later = calendar.date(byAdding: .day, value: 60, to: day1)!
        let unlocked = calendar.date(byAdding: .month, value: 3, to: day1)!
        if settings.canSetBudget(now: later, calendar: calendar) || settings.setBudget(5_000, now: later, calendar: calendar) || settings.budget != 2_000 {
            errors.append("a budget should stay locked for 3 months")
        }
        if settings.budgetUnlockDate(calendar: calendar) != unlocked || !settings.canSetBudget(now: unlocked, calendar: calendar)
            || !settings.setBudget(2_500, now: unlocked, calendar: calendar) || settings.budget != 2_500 {
            errors.append("the budget should unlock 3 months after it was set")
        }
        if settings.setBudget(0, now: unlocked.addingTimeInterval(1), calendar: calendar) || settings.setBudget(-5, now: unlocked.addingTimeInterval(1), calendar: calendar) {
            errors.append("a budget must be positive")
        }
        var old = MercurySettings()
        old.monthlyBudgetUsd = 1_500
        if !old.canSetBudget(now: day1) {
            errors.append("a budget saved before the lock existed can be set once")
        }
        func txn(_ id: String, _ amount: Double, _ kind: String, _ when: String, _ category: String = "", status: String = "sent", name: String = "") -> JSONValue {
            .object(["id": .string(id), "amount": .number(amount), "kind": .string(kind), "status": .string(status), "postedAt": .string(when),
                     "mercuryCategory": .string(category), "counterpartyName": .string(name)])
        }
        let grocery = txn("g", -42.5, "debitCardTransaction", "2026-10-01T18:00:00Z", "Grocery")
        let dinner = txn("d", -18, "debitCardTransaction", "2026-10-01T20:00:00Z", "Restaurants")
        if classify(grocery, overrides: [:]) != "necessary" { errors.append("grocery should be necessary") }
        if classify(dinner, overrides: [:]) != "discretionary" { errors.append("restaurants should be discretionary") }
        if classify(dinner, overrides: ["Restaurants": "necessary"]) != "necessary" { errors.append("a category override should win") }
        let payroll = txn("p", 8000, "incomingDomesticWire", "2026-06-01T15:00:00Z", name: "Payroll")
        let transfer = txn("t", 500, "internalTransfer", "2026-06-02T15:00:00Z")
        let interest = txn("i", 3, "interestPayment", "2026-06-03T15:00:00Z")
        if classify(payroll, overrides: [:]) != "income" || classify(transfer, overrides: [:]) != "transfer" || classify(interest, overrides: [:]) != "ignore" {
            errors.append("income rules should keep credits and drop transfers")
        }
        if classify(payroll, overrides: [:], incomePattern: "^Client") != "ignore" {
            errors.append("an income pattern should drop other counterparties")
        }
        let noon = OnDeviceTime.parse("2026-10-01T19:00:00Z") ?? .now  // 12:00 in Los Angeles
        let summary = summarize([grocery, dinner, payroll, transfer, interest], day: "2026-10-01", accounts: [.object(["availableBalance": .number(4000)])],
                                settings: MercurySettings(), now: noon)
        if summary.necessarySpendUsd != 42.5 || summary.discretionarySpendUsd != 18 {
            errors.append("Mercury spend split wrong")
        }
        if summary.ytdIncomeUsd != 8000 || summary.ytdGoalUsd != 500_000 || !summary.underCap || summary.settled {
            errors.append("YTD should count the credit only, the cap should hold, and noon is not settled")
        }
        let paces = [(20.0, 20.0, 4000.0), (32, 32, 4000), (42, 42, 4000), (50, 50, 4000), (0, 0, 100)].map {
            paceState(discretionaryToday: $0.0, discretionary7d: $0.1, availableBalance: $0.2, fraction: 1)
        }
        if paces != ["NORMAL", "CAUTION", "WARNING", "CRITICAL", "WARNING"] {
            errors.append("pace states wrong: \(paces)")
        }
        let pages: [String?: ([JSONValue], String?)] = [nil: ([.object(["id": .string("a")])], "a"), "a": ([.object(["id": .string("b")])], nil)]
        if collectCursorPages({ pages[$0] ?? ([], nil) }).compactMap({ $0["id"]?.stringValue }) != ["a", "b"] {
            errors.append("Mercury pagination dropped a page")
        }
        let slim = slimTransaction(.object(["id": .string("x"), "amount": .number(-5), "accountNumber": .string("123456789"), "routingNumber": .string("987654321")]))
        if slim.sortedString().contains("accountNumber") || slim.sortedString().contains("routingNumber") {
            errors.append("the Mercury cache must not keep bank numbers")
        }

        let rows = [
            txn("pay", 10000, "incomingDomesticWire", "2026-09-15T17:00:00Z", name: "Payroll"),
            txn("save", -3000, "treasuryTransfer", "2026-09-16T17:00:00Z"),
            txn("move", 2000, "internalTransfer", "2026-09-17T17:00:00Z"),
            txn("rent", -2500, "outgoingPayment", "2026-09-01T17:00:00Z", "Other", name: "Landlord LLC"),
            txn("food", -300, "debitCardTransaction", "2026-09-10T17:00:00Z", "Grocery"),
            txn("fun", -700, "debitCardTransaction", "2026-09-20T17:00:00Z", "Restaurants"),
            txn("dead", -900, "debitCardTransaction", "2026-09-21T17:00:00Z", "Retail", status: "cancelled"),
            txn("oct", -400, "debitCardTransaction", "2026-10-02T17:00:00Z", "Retail"),
            txn("aug", 5000, "incomingDomesticWire", "2026-08-31T17:00:00Z", name: "Payroll"),
            // 2026-10-01T05:00Z is 22:00 on 2026-09-30 in Los Angeles: a September spend.
            txn("late", -100, "debitCardTransaction", "2026-10-01T05:00:00Z", "Restaurants"),
            txn("int", 12, "interestPayment", "2026-09-30T17:00:00Z"),
        ]
        let october = OnDeviceTime.parse("2026-10-17T19:00:00Z") ?? .now
        var budgeted = MercurySettings()
        budgeted.monthlyBudgetUsd = 6000
        budgeted.taxReserveRate = 0.3
        let september = monthSummary(rows, month: "2026-09", settings: budgeted, now: october)
        let expected = MonthSummary(month: "2026-09", incomeUsd: 10000, postTaxIncomeUsd: 7000, spendingUsd: 3600, necessaryUsd: 2800,
                                    discretionaryUsd: 800, budgetUsd: 6000, taxReserveRate: 0.3, complete: true)
        if september != expected {
            errors.append("Mercury month summary wrong: \(september)")
        }
        let current = monthSummary(rows, month: "2026-10", settings: MercurySettings(), now: october)
        if current.complete || current.spendingUsd != 400 || current.budgetUsd != nil {
            errors.append("the month in progress should be incomplete with only October spend")
        }
        var greedy = MercurySettings()
        greedy.taxReserveRate = 0.9
        if monthSummary(rows, month: "2026-09", settings: greedy, now: october).postTaxIncomeUsd != 4000 {
            errors.append("the tax reserve rate should clamp to 0.6")
        }
        let firstMinute = OnDeviceTime.parse("2026-10-01T07:01:00Z") ?? .now  // 00:01 in Los Angeles
        let lastMinute = OnDeviceTime.parse("2026-10-01T06:59:00Z") ?? .now   // 23:59 on Sept 30
        if !monthComplete("2026-09", now: firstMinute) || monthComplete("2026-09", now: lastMinute) {
            errors.append("a month should complete at local midnight on the 1st")
        }
        if nextMonth("2026-12") != "2027-01" || !validMonth("2026-09") || validMonth("2026-13") || validMonth("2026-9") {
            errors.append("Mercury month helpers wrong")
        }
        if syncStart(OnDeviceTime.parse("2026-01-10T20:00:00Z") ?? .now) != "2025-12-01" || syncStart(october) != "2026-01-01" {
            errors.append("the Mercury sync should reach back to last month in January")
        }
        if MercurySettings.categoryMap(from: "Restaurants = necessary\nbad line\nSoftware=nope") != ["Restaurants": "necessary"] {
            errors.append("the category map text should keep only known tags")
        }
        return errors
    }
}
