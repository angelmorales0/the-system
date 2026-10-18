import Foundation

/// The backend's `GET /v1/integrations/codeforces/snapshot` reply. The backend reads the
/// official Codeforces API (user.info and user.rating); the phone never calls Codeforces.
/// `checkedAt` is ISO 8601 with `Z`.
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

    static func disconnected(reason: String) -> CodeforcesReading {
        CodeforcesReading(available: false, configured: false, reason: reason, handle: nil, rating: nil, maxRating: nil, rank: nil, contests: 0, checkedAt: nil)
    }
}

/// Deterministic INT level 0...350 from one Codeforces reading.
/// Pure: the same reading always gives the same report. No network and no clock.
enum IntelligenceLevel {
    /// 800 is the lowest problem rating; 2100 is Master. 1200 ≈ 30%, 1900 ≈ 85%.
    static let ratingBand = StatLevel.Band(floor: 800, target: 2100)

    enum Weight {
        static let rating = 100.0
    }

    static func evaluate(_ reading: CodeforcesReading) -> StatLevelReport {
        StatLevelReport(stat: .INT, requirements: [rating(reading)])
    }

    /// Strict rule: current rating ≥ 2100. The peak (maxRating) shows in the detail but does not score.
    private static func rating(_ reading: CodeforcesReading) -> StatRequirement {
        let category = "Codeforces rating"
        guard reading.configured, reading.available else {
            return StatRequirement(category: category, passed: false, progress: 0, weight: Weight.rating, detail: reading.reason)
        }
        let who = reading.handle.map { "\($0): " } ?? ""
        guard reading.contests > 0, let current = reading.rating else {
            return StatRequirement(category: category, passed: false, progress: 0, weight: Weight.rating, detail: who + "unrated")
        }
        var detail = who + "rating \(current)"
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
        CodeforcesReading(available: true, configured: true, reason: "", handle: "tester", rating: rating, maxRating: maxRating ?? rating, rank: nil, contests: contests, checkedAt: Date(timeIntervalSince1970: 0))
    }

    static func check() -> [String] {
        var errors: [String] = []

        let top = evaluate(reading(rating: 2100))
        if !top.isMaxLevel || top.level != StatLevel.maxLevel || abs(top.score - 100) > 0.001 {
            errors.append("rating 2100 should be the max level and score 100, got level \(top.level) score \(top.score)")
        }
        if top.stat != .INT || top.requirements.count != 1 || top.requirements.reduce(0, { $0 + $1.weight }) != 100 {
            errors.append("INT should have one requirement with weight 100")
        }

        let almost = evaluate(reading(rating: 2099))
        if almost.isMaxLevel || almost.level > StatLevel.maxLevel - 1 {
            errors.append("rating 2099 should stay at one under the max level or lower, got \(almost.level)")
        }

        for floor in [800, 600] {
            let report = evaluate(reading(rating: floor))
            if report.level != 0 || report.score != 0 {
                errors.append("rating \(floor) should be level 0, got level \(report.level)")
            }
        }

        // 1450 is halfway between 800 and 2100: progress 0.5, score 50, level 175.
        let half = evaluate(reading(rating: 1450))
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
            if decoded.rating != 2150 || decoded.checkedAt == nil || !evaluate(decoded).isMaxLevel {
                errors.append("decoded backend reading should be rating 2150 and the max level, got \(decoded)")
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
