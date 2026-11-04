import Foundation

/// Codeforces gives one rating to an account. A contest counts for the language of most of the player's submissions in it.
nonisolated enum CodeforcesLanguage: String, Codable, CaseIterable, Identifiable {
    case cpp = "C++"
    case java = "Java"
    case python = "Python"

    var id: String { rawValue }

    /// Reads a `programmingLanguage` value such as "GNU G++20 13.2", "Java 21", or "PyPy 3-64". Other languages give nil.
    init?(submission name: String) {
        let lower = name.lowercased()
        if lower.contains("c++") || lower.contains("g++") || lower.contains("clang++") {
            self = .cpp
        } else if lower.hasPrefix("java"), !lower.hasPrefix("javascript") {
            self = .java
        } else if lower.contains("python") || lower.contains("pypy") {
            self = .python
        } else {
            return nil
        }
    }
}

nonisolated struct CodeforcesContest: Codable, Equatable {
    /// `ratingUpdateTimeSeconds`.
    var time: Int
    var oldRating: Int
    var newRating: Int
    /// Nil when the contest has no submissions in C++, Java, or Python.
    var language: CodeforcesLanguage? = nil
}

/// One read of the official Codeforces API (user.info and user.rating). `checkedAt` is ISO 8601 with `Z`.
nonisolated struct CodeforcesReading: Codable, Equatable {
    var available: Bool
    var configured: Bool
    var reason: String
    var handle: String?
    /// Current rating. Nil for an unrated user (no rated contests).
    var rating: Int?
    var maxRating: Int?
    var rank: String?
    /// Rated contests from user.rating.
    var contests: Int
    var checkedAt: Date?
    /// Rated contests, oldest first. Nil when `user.rating` failed.
    var history: [CodeforcesContest]? = nil
    /// True when `user.status` failed and a rated contest has no known language. No monthly quest is judged then.
    var languagesPending: Bool? = nil

    /// The rating after the newest contest in this language.
    func rating(in language: CodeforcesLanguage) -> Int? {
        history?.last { $0.language == language }?.newRating
    }

    static func disconnected(reason: String) -> CodeforcesReading {
        CodeforcesReading(available: false, configured: false, reason: reason, handle: nil, rating: nil, maxRating: nil, rank: nil, contests: 0, checkedAt: nil)
    }
}

/// Deterministic INT level 0...350 from the Codeforces rating in each language and the Monkeytype best.
/// Pure: the same reading always gives the same report. No network and no clock.
enum IntelligenceLevel {
    /// 800 is the lowest problem rating; 2100 is Master. 1200 ≈ 30%, 1900 ≈ 85%.
    static let ratingBand = StatLevel.Band(floor: 800, target: 2100)

    /// 40 WPM is an everyday typist. 200 is the goal.
    static let typingBand = StatLevel.Band(floor: 40, target: 200)

    enum Weight {
        static let rating = 30.0
        static let typing = 10.0
    }

    static func category(_ language: CodeforcesLanguage) -> String { "Codeforces \(language.rawValue)" }
    static let typingCategory = "Typing speed"

    static func evaluate(_ reading: CodeforcesReading, typing: MonkeytypeReading = .disconnected(reason: "")) -> StatLevelReport {
        StatLevelReport(stat: .INT, requirements: CodeforcesLanguage.allCases.map { rating(reading, language: $0) } + [typingSpeed(typing)])
    }

    /// Strict rule: 200 WPM or more on a 60 second Monkeytype test.
    private static func typingSpeed(_ reading: MonkeytypeReading) -> StatRequirement {
        guard reading.available, let best = reading.bestWpm else {
            return StatRequirement(category: typingCategory, passed: false, progress: 0, weight: Weight.typing, detail: reading.reason, hasData: false)
        }
        return StatRequirement(
            category: typingCategory,
            passed: best >= typingBand.target,
            progress: typingBand.progress(best),
            weight: Weight.typing,
            detail: "\(Int(best)) WPM best in 60 seconds; target \(Int(typingBand.target))"
        )
    }

    /// Strict rule: rating ≥ 2100 after the newest contest in the language. The peak (maxRating) shows in the detail but does not score.
    private static func rating(_ reading: CodeforcesReading, language: CodeforcesLanguage) -> StatRequirement {
        let category = category(language)
        guard reading.configured, reading.available else {
            return StatRequirement(category: category, passed: false, progress: 0, weight: Weight.rating, detail: reading.reason, hasData: false)
        }
        let who = reading.handle.map { "\($0): " } ?? ""
        guard reading.contests > 0, reading.rating != nil else {
            return StatRequirement(category: category, passed: false, progress: 0, weight: Weight.rating, detail: who + "unrated", hasData: false)
        }
        guard let current = reading.rating(in: language) else {
            return StatRequirement(category: category, passed: false, progress: 0, weight: Weight.rating, detail: who + "no rated contest in \(language.rawValue)", hasData: false)
        }
        var detail = who + "rating \(current) after the last \(language.rawValue) contest"
        if let rank = reading.rank { detail += " (\(rank))" }
        if let peak = reading.maxRating { detail += ", max \(peak)" }
        detail += ", \(reading.contests) rated contests; target \(Int(ratingBand.target))"
        return StatRequirement(
            category: category,
            passed: Double(current) >= ratingBand.target,
            progress: ratingBand.progress(Double(current)),
            weight: Weight.rating,
            detail: detail
        )
    }

    // MARK: - Self-check (runs in DEBUG at launch)

    static func reading(rating: Int?, maxRating: Int? = nil, contests: Int = 20) -> CodeforcesReading {
        var reading = CodeforcesReading(available: true, configured: true, reason: "", handle: "tester", rating: rating, maxRating: maxRating ?? rating, rank: nil, contests: contests, checkedAt: Date(timeIntervalSince1970: 0))
        if let rating, contests > 0 {
            reading.history = CodeforcesLanguage.allCases.map { CodeforcesContest(time: 1, oldRating: rating, newRating: rating, language: $0) }
        }
        return reading
    }

    static func check() -> [String] {
        var errors: [String] = []
        func typing(_ wpm: Double) -> MonkeytypeReading {
            MonkeytypeReading(available: true, configured: true, reason: "", username: "t", bestWpm: wpm)
        }

        let top = evaluate(reading(rating: 2100), typing: typing(200))
        if !top.isMaxLevel || top.level != StatLevel.maxLevel || abs(top.score - 100) > 0.001 {
            errors.append("rating 2100 should be the max level and score 100, got level \(top.level) score \(top.score)")
        }
        if top.stat != .INT || top.requirements.count != 4 || top.requirements.reduce(0, { $0 + $1.weight }) != 100 {
            errors.append("INT should have three languages and typing, with weights that add to 100")
        }
        for (name, language) in [("GNU G++20 13.2 (64 bit, winlibs)", CodeforcesLanguage.cpp), ("C++23 (GCC 14-64, msys2)", .cpp), ("Java 21 64bit", .java), ("PyPy 3-64", .python), ("Python 3", .python)] {
            if CodeforcesLanguage(submission: name) != language { errors.append("\(name) should read as \(language.rawValue)") }
        }
        if CodeforcesLanguage(submission: "JavaScript V8") != nil || CodeforcesLanguage(submission: "Rust 1.75") != nil {
            errors.append("other languages should not count")
        }
        var cppOnly = reading(rating: 2100)
        cppOnly.history = [CodeforcesContest(time: 1, oldRating: 2000, newRating: 2100, language: .cpp)]
        let oneLanguage = evaluate(cppOnly)
        if oneLanguage.requirements.filter(\.hasData).map(\.category) != ["Codeforces C++"] {
            errors.append("a language with no rated contest should have no data")
        }
        var early = cppOnly
        early.history?.append(CodeforcesContest(time: 2, oldRating: 2100, newRating: 1500, language: .java))
        if early.rating(in: .cpp) != 2100 || early.rating(in: .java) != 1500 || early.rating(in: .python) != nil {
            errors.append("each language should keep the rating of its own newest contest")
        }
        let typed = evaluate(reading(rating: 2100), typing: typing(120))
        if abs((typed.requirements.last?.progress ?? 0) - 0.5) > 0.0001 || typed.isMaxLevel {
            errors.append("120 WPM should be half the typing band and hold INT under the max")
        }

        let almost = evaluate(reading(rating: 2099), typing: typing(200))
        if almost.isMaxLevel || almost.level > StatLevel.maxLevel - 1 {
            errors.append("rating 2099 should stay at one under the max level or lower, got \(almost.level)")
        }

        for floor in [800, 600] {
            let report = evaluate(reading(rating: floor), typing: typing(40))
            if report.level != 0 || report.score != 0 {
                errors.append("rating \(floor) should be level 0, got level \(report.level)")
            }
        }

        // 1450 is halfway between 800 and 2100, and 120 WPM is halfway between 40 and 200: score 50, level 175.
        let half = evaluate(reading(rating: 1450), typing: typing(120))
        if abs((half.requirements.first?.progress ?? 0) - 0.5) > 0.0001 || half.level != 175 {
            errors.append("rating 1450 should be band 0.5 and level 175, got \(half.requirements.first?.progress ?? -1) level \(half.level)")
        }

        // The current rating scores, not the peak.
        let fallen = evaluate(reading(rating: 1900, maxRating: 2200))
        if fallen.isMaxLevel || fallen.requirements.first?.passed != false {
            errors.append("max rating 2200 with current 1900 should not pass")
        }
        if fallen.requirements.first?.detail.contains("max 2200") != true {
            errors.append("the detail should show the max rating, got \(fallen.requirements.first?.detail ?? "")")
        }

        for unrated in [reading(rating: nil, contests: 0), reading(rating: 1500, contests: 0)] {
            let report = evaluate(unrated)
            if report.level != 0 || report.requirements.first?.detail.contains("unrated") != true {
                errors.append("an unrated user should be level 0 with detail unrated, got \(report.level) \(report.requirements.first?.detail ?? "")")
            }
        }

        let reason = "TODO: Set CODEFORCES_HANDLE on the backend."
        let off = evaluate(.disconnected(reason: reason))
        if off.level != 0 || off.isMaxLevel || off.requirements.first?.detail != reason {
            errors.append("a disconnected reading should be level 0 with the TODO reason, got \(off.level) \(off.requirements.first?.detail ?? "")")
        }

        // The phone decodes the backend JSON with ISO 8601 dates.
        let json = #"{"available":true,"configured":true,"reason":"","handle":"tourist","rating":2150,"maxRating":2300,"rank":"master","contests":2,"checkedAt":"2026-10-17T12:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(CodeforcesReading.self, from: Data(json.utf8)) {
            if decoded.rating != 2150 || decoded.checkedAt == nil {
                errors.append("decoded backend reading should be rating 2150, got \(decoded)")
            }
        } else {
            errors.append("backend Codeforces JSON should decode")
        }
        let unratedJSON = #"{"available":true,"configured":true,"reason":"","handle":"newbie","rating":null,"maxRating":null,"rank":null,"contests":0,"checkedAt":null}"#
        if (try? decoder.decode(CodeforcesReading.self, from: Data(unratedJSON.utf8))) == nil {
            errors.append("unrated backend JSON with nulls should decode")
        }
        return errors
    }
}
