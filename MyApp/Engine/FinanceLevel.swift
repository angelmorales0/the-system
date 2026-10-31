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
}

/// Deterministic FIN (finance) level 0...350.
/// Pure: the same months always give the same report. No network and no clock.
enum FinanceLevel {
    // Floors are the level 0 limits; targets are the max level rules.
    static let savingsBand = StatLevel.Band(floor: 0, target: 0.30)       // share of post-tax income
    static let incomeBand = StatLevel.Band(floor: 0, target: 25_000)      // USD per month, post-tax
    /// Dollars over budget at level 0, as a share of the budget. The target is $0 over.
    static let budgetFloorShare = 0.5
    /// Rounding slack for "$0 over": half a cent.
    static let budgetTolerance = 0.005

    enum Weight {
        static let savings = 60.0
        static let budget = 30.0
        static let income = 10.0
    }

    /// Scores the newest complete month. A month in progress does not count.
    static func evaluate(months: [FinanceMonth]) -> StatLevelReport {
        guard let month = months.filter(\.complete).max(by: { $0.month < $1.month }) else {
            let none = "no complete month yet"
            return StatLevelReport(stat: .FIN, requirements: [
                StatRequirement(category: "Savings rate", passed: false, progress: 0, weight: Weight.savings, detail: none, hasData: false),
                StatRequirement(category: "Budget adherence", passed: false, progress: 0, weight: Weight.budget, detail: none, hasData: false),
                StatRequirement(category: "Monthly income", passed: false, progress: 0, weight: Weight.income, detail: none, hasData: false),
            ])
        }
        return StatLevelReport(stat: .FIN, requirements: [
            savingsRate(month),
            budgetAdherence(month),
            monthlyIncome(month),
        ])
    }

    // MARK: - Requirements

    /// (income − spending) / income. Negative clamps to 0. No income gives 0.
    static func rate(_ month: FinanceMonth) -> Double {
        guard month.postTaxIncomeUsd > 0 else { return 0 }
        return max((month.postTaxIncomeUsd - month.spendingUsd) / month.postTaxIncomeUsd, 0)
    }

    /// Strict rule: the month saved 30% or more of post-tax income.
    private static func savingsRate(_ month: FinanceMonth) -> StatRequirement {
        let value = rate(month)
        let saved = month.postTaxIncomeUsd - month.spendingUsd
        let detail: String
        if month.postTaxIncomeUsd <= 0 {
            detail = "no income in \(month.month) (\(usd(month.spendingUsd)) spent)"
        } else if saved < 0 {
            detail = "spent \(usd(-saved)) more than \(usd(month.postTaxIncomeUsd)) income in \(month.month)"
        } else {
            detail = "saved \(percent(value)) (\(usd(saved)) of \(usd(month.postTaxIncomeUsd))) in \(month.month)"
        }
        return StatRequirement(
            category: "Savings rate",
            passed: value >= savingsBand.target,
            progress: savingsBand.progress(value),
            weight: Weight.savings,
            detail: detail
        )
    }

    /// Strict rule: $0 over `MONTHLY_BUDGET_USD`. Without a budget there is nothing to score, so the rule drops out.
    private static func budgetAdherence(_ month: FinanceMonth) -> StatRequirement {
        guard let budget = month.budgetUsd, budget > 0 else {
            return StatRequirement(category: "Budget adherence", passed: false, progress: 0, weight: Weight.budget, detail: "budget not set (MONTHLY_BUDGET_USD)", hasData: false)
        }
        let over = max(0, month.spendingUsd - budget)
        let band = StatLevel.Band(floor: budgetFloorShare * budget, target: 0)
        let detail = over <= budgetTolerance
            ? "\(usd(month.spendingUsd)) of \(usd(budget)) budget in \(month.month)"
            : "\(usd(over)) over \(usd(budget)) budget in \(month.month)"
        return StatRequirement(
            category: "Budget adherence",
            passed: over <= budgetTolerance,
            progress: band.progress(over),
            weight: Weight.budget,
            detail: detail
        )
    }

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

    /// A complete month that meets every the max level requirement: 34% saved, $500 under budget, $25,000 income.
    static func perfectMonth() -> FinanceMonth {
        FinanceMonth(month: "2026-09", postTaxIncomeUsd: 25_000, spendingUsd: 16_500, budgetUsd: 17_000, complete: true)
    }

    /// A complete month at every level 0 floor: no income, spending 50% over budget.
    static func floorMonth() -> FinanceMonth {
        FinanceMonth(month: "2026-09", postTaxIncomeUsd: 0, spendingUsd: 3_000, budgetUsd: 2_000, complete: true)
    }

    static func check() -> [String] {
        var errors: [String] = []
        let perfect = perfectMonth()
        let report = evaluate(months: [perfect])
        if !report.isMaxLevel {
            errors.append("perfect month should reach the max level, failing: " + report.failing.map { "\($0.category): \($0.detail)" }.joined(separator: " | "))
        }
        if report.requirements.count != 3 {
            errors.append("FIN should have 3 requirements, got \(report.requirements.count)")
        }
        let weights = report.requirements.map(\.weight)
        if weights != [60, 30, 10] {
            errors.append("weights should be 60/30/10, got \(weights)")
        }
        if report.level != StatLevel.maxLevel || abs(report.score - 100) > 0.001 || report.stat != .FIN {
            errors.append("perfect month should score 100 and the max level, got \(report.score) level \(report.level)")
        }
        let savedDetail = report.requirements.first?.detail
        if savedDetail != "saved 34% ($8,500 of $25,000) in 2026-09" {
            errors.append("savings detail wrong: \(String(describing: savedDetail))")
        }

        let empty = evaluate(months: [])
        if empty.isMaxLevel || empty.level != 0 || empty.score != 0 || !empty.requirements.allSatisfy({ $0.detail == "no complete month yet" }) {
            errors.append("no months must be level 0 with \"no complete month yet\", got level \(empty.level) score \(empty.score)")
        }

        let floorReport = evaluate(months: [floorMonth()])
        if floorReport.level != 0 || floorReport.score > 0.001 {
            errors.append("floor month should be level 0, got level \(floorReport.level) score \(floorReport.score): " + floorReport.requirements.map { "\($0.category) \($0.points)" }.joined(separator: ", "))
        }

        @discardableResult
        func failsOnly(_ category: String, _ edit: (inout FinanceMonth) -> Void, line: Int = #line) -> StatLevelReport {
            var month = perfect
            edit(&month)
            let edited = evaluate(months: [month])
            let failing = edited.failing.map(\.category)
            if failing != [category] {
                errors.append("line \(line): expected only \(category) to fail, got \(failing)")
            }
            if edited.level >= StatLevel.maxLevel {
                errors.append("line \(line): a failing \(category) must stay under the max level, got \(edited.level)")
            }
            if edited.topGains(1).first?.category != category {
                errors.append("line \(line): \(category) should be the top gain, got \(edited.topGains(1).map(\.category))")
            }
            return edited
        }

        // Each requirement at its floor alone. Budget stays met by raising the budget with spending.
        let noSavings = failsOnly("Savings rate") { $0.spendingUsd = 25_000; $0.budgetUsd = 25_000 }
        let overBudget = failsOnly("Budget adherence") { $0.budgetUsd = 11_000 }   // $5,500 over = 50% of budget
        let lowIncome = failsOnly("Monthly income") { $0.postTaxIncomeUsd = 0.01; $0.spendingUsd = 0 }
        if !(noSavings.level < overBudget.level && overBudget.level < lowIncome.level) {
            errors.append("savings failing alone should cost the most levels, then budget, then income: \(noSavings.level) \(overBudget.level) \(lowIncome.level)")
        }

        // 29.9% saved misses 30%: strict rule fails and the level caps one under the max.
        let nearly = failsOnly("Savings rate") { $0.spendingUsd = 17_525; $0.budgetUsd = 18_000 }
        if nearly.level != StatLevel.maxLevel - 1 || nearly.requirements[0].detail.hasPrefix("saved 29.9%") != true {
            errors.append("29.9% saved should cap at one under the max level and read 29.9%, got level \(nearly.level) \(nearly.requirements[0].detail)")
        }
        // Exactly 30% passes.
        var exact = perfect
        exact.spendingUsd = 17_500
        exact.budgetUsd = 17_500
        if !evaluate(months: [exact]).isMaxLevel {
            errors.append("exactly 30% saved and $0 over should pass")
        }

        // $420 over a $6,000 budget: progress is 1 − 420 / 3,000.
        let over = failsOnly("Budget adherence") { $0.spendingUsd = 6_420; $0.budgetUsd = 6_000 }
        let overRow = over.requirements[1]
        if abs(overRow.progress - (1 - 420.0 / 3_000)) > 0.0001 || overRow.detail != "$420 over $6,000 budget in 2026-09" {
            errors.append("$420 over $6,000 should give progress 0.86, got \(overRow)")
        }

        // No MONTHLY_BUDGET_USD: the budget rule has no data. It drops out, the TODO detail stays, and savings and income
        // share its weight (60/10 → 85.7/14.3). A perfect month without a budget is still the max level.
        var noBudgetMonth = perfect
        noBudgetMonth.budgetUsd = nil
        let noBudget = evaluate(months: [noBudgetMonth])
        let budgetRow = noBudget.requirements[1]
        if budgetRow.hasData || budgetRow.progress != 0 || budgetRow.detail != "budget not set (MONTHLY_BUDGET_USD)" {
            errors.append("a missing budget should have no data and read \"budget not set (MONTHLY_BUDGET_USD)\", got \(budgetRow)")
        }
        if !noBudget.isMaxLevel || noBudget.failing.map(\.category) != [] || noBudget.counted.map(\.category) != ["Savings rate", "Monthly income"]
            || abs((noBudget.counted.first?.weight ?? 0) - 600.0 / 7) > 0.001 {
            errors.append("without a budget the other two rules should score alone at 85.7/14.3, got \(noBudget.counted.map { "\($0.category) \($0.weight)" }) level \(noBudget.level)")
        }
        var noBudgetWeak = noBudgetMonth
        noBudgetWeak.spendingUsd = 25_000
        if evaluate(months: [noBudgetWeak]).level != 50 {
            errors.append("no savings and no budget should be income alone: 100/7 points = level 50, got \(evaluate(months: [noBudgetWeak]).level)")
        }

        // $24,999 income fails.
        failsOnly("Monthly income") { $0.postTaxIncomeUsd = 24_999; $0.spendingUsd = 16_000 }

        // The month in progress never counts, even when it is newer and better.
        let inProgress = FinanceMonth(month: "2026-10", postTaxIncomeUsd: 30_000, spendingUsd: 1_000, budgetUsd: 17_000, complete: false)
        let weak = FinanceMonth(month: "2026-09", postTaxIncomeUsd: 10_000, spendingUsd: 9_000, budgetUsd: 8_000, complete: true)
        let ignored = evaluate(months: [inProgress, weak])
        if ignored.isMaxLevel || ignored.failing.count != 3 {
            errors.append("the month in progress should not score, got failing \(ignored.failing.map(\.category))")
        }
        if !evaluate(months: [inProgress]).requirements.allSatisfy({ $0.detail == "no complete month yet" }) {
            errors.append("only a month in progress should read \"no complete month yet\"")
        }

        // The newest complete month wins over an older one, whatever the array order.
        let older = FinanceMonth(month: "2026-08", postTaxIncomeUsd: 25_000, spendingUsd: 10_000, budgetUsd: 17_000, complete: true)
        if evaluate(months: [weak, older]).isMaxLevel || !evaluate(months: [older, perfect]).isMaxLevel || !evaluate(months: [perfect, older]).isMaxLevel {
            errors.append("the newest complete month should be scored, not an older one")
        }

        // Overspending clamps to 0, never negative.
        var overspent = perfect
        overspent.spendingUsd = 30_000
        if rate(overspent) != 0 || evaluate(months: [overspent]).requirements[0].progress != 0 {
            errors.append("spending over income should clamp the savings rate to 0")
        }

        // The phone decodes the backend JSON; extra keys are ignored.
        let json = #"{"month":"2026-09","incomeUsd":10000,"postTaxIncomeUsd":7000,"spendingUsd":3600,"necessaryUsd":2800,"discretionaryUsd":800,"budgetUsd":null,"complete":true,"available":true,"configured":true,"reason":""}"#
        let decoded = try? JSONDecoder().decode(FinanceMonth.self, from: Data(json.utf8))
        if decoded != FinanceMonth(month: "2026-09", postTaxIncomeUsd: 7000, spendingUsd: 3600, budgetUsd: nil, complete: true) {
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
