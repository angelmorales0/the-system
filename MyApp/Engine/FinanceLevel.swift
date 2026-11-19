import Foundation

/// One calendar month of Mercury totals from `GET /v1/integrations/mercury/month?month=YYYY-MM`.
/// The backend JSON has more keys (incomeUsd, necessaryUsd, available, reason, ...). Decoding ignores them.
///
/// Data limits:
/// - Mercury sees deposits, not taxes. `postTaxIncomeUsd` is income that the backend classifier allows,
///   less the optional `MONTHLY_TAX_RESERVE_RATE`. It is not real tax data.
/// - Mercury sees Mercury accounts only. Spend on other cards or banks is invisible.
/// - Mercury has no budget. `budgetUsd` comes from `MONTHLY_BUDGET_USD` and is nil when it is not set.
/// - Transfers to Mercury savings or treasury are neither income nor spending.
nonisolated struct FinanceMonth: Codable, Equatable {
    /// "YYYY-MM" in America/Los_Angeles.
    var month: String
    var postTaxIncomeUsd: Double
    /// Necessary + discretionary spend.
    var spendingUsd: Double
    var budgetUsd: Double?
    /// True when the month has ended. The month in progress never scores.
    var complete: Bool
    var necessaryUsd: Double? = nil
    var discretionaryUsd: Double? = nil
    /// The part of the spending that paid a credit card bill. Mercury does not see the purchases on the card.
    var cardBillUsd: Double? = nil
    /// True when the month ended after the last good Mercury sync, so its last days are missing.
    /// The FIN level still reads it, as before.
    var missingLastDays: Bool? = nil
}

/// Deterministic FIN (finance) level 0...350. One target: post-tax income in the newest complete month.
/// Budget adherence and the savings rate were removed on 2026-11-18. `FinanceMonth` still decodes their inputs.
/// Pure: the same months always give the same report. No network and no clock.
enum FinanceLevel {
    // The floor is the level 0 limit; the target is the max level rule.
    static let incomeBand = StatLevel.Band(floor: 0, target: 25_000)      // USD per month, post-tax

    enum Weight {
        static let income = 100.0
    }

    /// Scores the newest complete month. A month in progress does not count.
    static func evaluate(months: [FinanceMonth]) -> StatLevelReport {
        guard let month = months.filter(\.complete).max(by: { $0.month < $1.month }) else {
            return StatLevelReport(stat: .FIN, requirements: [
                StatRequirement(category: "Monthly income", passed: false, progress: 0, weight: Weight.income, detail: "no complete month yet", hasData: false),
            ])
        }
        return StatLevelReport(stat: .FIN, requirements: [monthlyIncome(month)])
    }

    // MARK: - Requirements

    /// Strict rule: $25,000 or more post-tax income in the month.
    private static func monthlyIncome(_ month: FinanceMonth) -> StatRequirement {
        StatRequirement(
            category: "Monthly income",
            passed: month.postTaxIncomeUsd >= incomeBand.target,
            progress: incomeBand.progress(month.postTaxIncomeUsd),
            weight: Weight.income,
            detail: "\(usd(month.postTaxIncomeUsd)) post-tax in \(month.month) (target \(usd(incomeBand.target)))"
        )
    }

    // MARK: - Formatting

    /// Whole dollars with commas, no locale: 8500 → "$8,500", -12.4 → "-$12".
    static func usd(_ value: Double) -> String {
        let whole = Int(abs(value).rounded())
        var digits = String(whole)
        var parts: [String] = []
        while digits.count > 3 {
            parts.insert(String(digits.suffix(3)), at: 0)
            digits = String(digits.dropLast(3))
        }
        parts.insert(digits, at: 0)
        return (value < 0 && whole > 0 ? "-$" : "$") + parts.joined(separator: ",")
    }

    /// Rounds down to 0.1% so a failing 29.96% never reads as 30%: 0.34 → "34%", 0.299 → "29.9%".
    static func percent(_ share: Double) -> String {
        let tenths = (share * 1000 + 1e-9).rounded(.down) / 10
        return tenths == tenths.rounded() ? String(format: "%.0f%%", tenths) : String(format: "%.1f%%", tenths)
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    /// A complete month that meets the max level rule: $25,000 post-tax income, high spending.
    static func perfectMonth() -> FinanceMonth {
        FinanceMonth(month: "2026-09", postTaxIncomeUsd: 25_000, spendingUsd: 30_000, budgetUsd: 1_000, complete: true)
    }

    static func check() -> [String] {
        var errors: [String] = []
        let report = evaluate(months: [perfectMonth()])
        if report.requirements.map(\.category) != ["Monthly income"] || report.requirements.map(\.weight) != [100] {
            errors.append("FIN should have Monthly income only at 100, got \(report.requirements.map(\.category))")
        }
        if !report.isMaxLevel || report.level != StatLevel.maxLevel || abs(report.score - 100) > 0.001 || report.stat != .FIN {
            errors.append("$25,000 income should reach the max level whatever the spending, got \(report.score) level \(report.level)")
        }

        let empty = evaluate(months: [])
        if empty.level != 0 || empty.requirements.first?.detail != "no complete month yet" {
            errors.append("no months must be level 0 with \"no complete month yet\", got level \(empty.level)")
        }

        // $24,999 fails the strict rule and caps one under the max. Half the target is half the score.
        var nearly = perfectMonth()
        nearly.postTaxIncomeUsd = 24_999
        if evaluate(months: [nearly]).level != StatLevel.maxLevel - 1 {
            errors.append("$24,999 should cap one under the max level, got \(evaluate(months: [nearly]).level)")
        }
        var half = perfectMonth()
        half.postTaxIncomeUsd = 12_500
        if abs(evaluate(months: [half]).score - 50) > 0.001 {
            errors.append("$12,500 should score 50, got \(evaluate(months: [half]).score)")
        }

        // The month in progress never counts; the newest complete month wins, whatever the array order.
        let inProgress = FinanceMonth(month: "2026-10", postTaxIncomeUsd: 30_000, spendingUsd: 1_000, budgetUsd: nil, complete: false)
        let older = FinanceMonth(month: "2026-08", postTaxIncomeUsd: 1_000, spendingUsd: 0, budgetUsd: nil, complete: true)
        if !evaluate(months: [inProgress]).requirements.allSatisfy({ $0.detail == "no complete month yet" }) {
            errors.append("only a month in progress should read \"no complete month yet\"")
        }
        if !evaluate(months: [older, perfectMonth(), inProgress]).isMaxLevel || evaluate(months: [inProgress, older]).isMaxLevel {
            errors.append("the newest complete month should be scored")
        }

        // The phone decodes the backend JSON; extra keys are ignored.
        let json = #"{"month":"2026-09","incomeUsd":10000,"postTaxIncomeUsd":7000,"spendingUsd":3600,"necessaryUsd":2800,"discretionaryUsd":800,"budgetUsd":null,"complete":true,"available":true,"configured":true,"reason":""}"#
        let decoded = try? JSONDecoder().decode(FinanceMonth.self, from: Data(json.utf8))
        if decoded != FinanceMonth(month: "2026-09", postTaxIncomeUsd: 7000, spendingUsd: 3600, budgetUsd: nil, complete: true, necessaryUsd: 2800, discretionaryUsd: 800) {
            errors.append("backend month JSON should decode, got \(String(describing: decoded))")
        }

        if usd(8500) != "$8,500" || usd(1_234_567.4) != "$1,234,567" || usd(-420) != "-$420" || usd(0) != "$0" {
            errors.append("usd format wrong: \(usd(8500)) \(usd(1_234_567.4)) \(usd(-420)) \(usd(0))")
        }
        if percent(0.34) != "34%" || percent(0.2999) != "29.9%" || percent(0) != "0%" {
            errors.append("percent format wrong: \(percent(0.34)) \(percent(0.2999)) \(percent(0))")
        }
        return errors
    }
}
