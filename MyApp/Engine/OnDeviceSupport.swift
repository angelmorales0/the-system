import Foundation

// Shared parts of the on-device clients: JSON access, small HTTP calls, and time parsing.
// They replace the Python backend's dict access, urllib calls, and datetime helpers.

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// A whole number, like Python's `isinstance(value, int)` after JSON decoding.
    var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }

    var isNull: Bool { self == .null }

    /// Python truthiness: nil, null, false, 0, "", [] and {} are false.
    var truthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): !value.isEmpty
        case .array(let value): !value.isEmpty
        case .object(let value): !value.isEmpty
        }
    }

    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Any Codable value as JSON, dates as ISO 8601, like the phone sent it to the backend.
    static func from<T: Encodable>(_ value: T) -> JSONValue? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return parse(data)
    }

    /// Sorted keys, so the same value gives the same bytes on every call (the prompt cache needs this).
    func sortedData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }

    func sortedString() -> String {
        sortedData().flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// Decodes this value as `T`, dates as ISO 8601.
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = sortedData() else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

/// Builds a JSON object from optional values. A nil value is left out, like the Python summaries do.
func jsonObject(_ pairs: KeyValuePairs<String, JSONValue?>) -> JSONValue {
    var object: [String: JSONValue] = [:]
    for (key, value) in pairs {
        if let value { object[key] = value }
    }
    return .object(object)
}

extension Optional where Wrapped == JSONValue {
    var truthy: Bool { self?.truthy ?? false }
}

/// Short GET and POST calls with no cookies and no cache. Errors return nil; no body or key is logged.
enum OnDeviceHTTP {
    static let timeout: TimeInterval = 8

    static func session(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// The HTTP status and the decoded body. Nil when the request did not complete.
    static func get(_ url: URL, headers: [String: String], timeout: TimeInterval = 8) async -> (status: Int, json: JSONValue?)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await session(timeout: timeout).data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, JSONValue.parse(data))
    }

    /// The decoded body of a 2xx reply, or nil.
    static func getJSON(_ url: URL, headers: [String: String], timeout: TimeInterval = 8) async -> JSONValue? {
        guard let reply = await get(url, headers: headers, timeout: timeout), (200..<300).contains(reply.status) else { return nil }
        return reply.json
    }

    /// Form POST to an OAuth token endpoint. Adds `expires_at` from `expires_in`, like the backend.
    static func postForm(_ url: URL, body: [String: String], timeout: TimeInterval = 8, now: Date = .now) async -> (status: Int, json: JSONValue?)? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncoded(body).utf8)
        guard let (data, response) = try? await session(timeout: timeout).data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard var object = JSONValue.parse(data)?.objectValue else { return (http.statusCode, nil) }
        if let seconds = object["expires_in"]?.doubleValue {
            object["expires_at"] = .number((now.timeIntervalSince1970 + seconds).rounded(.down))
        }
        return (http.statusCode, .object(object))
    }

    static func formEncoded(_ body: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return body.keys.sorted().map { key in
            let value = body[key] ?? ""
            return "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    /// `base` plus query items, or nil.
    static func url(_ base: String, _ query: [(String, String)] = []) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // `+` in an ISO time would read as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url
    }
}

/// Time helpers from the backend: ISO 8601 parsing, `YYYY-MM-DDTHH:MM:SSZ` output, and local day bounds.
enum OnDeviceTime {
    static let losAngeles = TimeZone(identifier: "America/Los_Angeles") ?? .current

    /// Any ISO 8601 time: with or without fractional seconds, `Z` or an offset. A time with no zone reads as UTC.
    static func parse(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        // Microseconds and other long fractions: drop the fraction.
        if let range = value.range(of: #"\.\d+"#, options: .regularExpression) {
            var trimmed = value
            trimmed.removeSubrange(range)
            if let date = plain.date(from: trimmed) { return date }
        }
        // No zone: read as UTC.
        let bare = DateFormatter()
        bare.locale = Locale(identifier: "en_US_POSIX")
        bare.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            bare.dateFormat = format
            if let date = bare.date(from: value) { return date }
        }
        return nil
    }

    /// `2026-10-02T14:00:00Z`.
    static func utcString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Local midnight to the next local midnight for `dayKey` ("YYYY-MM-DD") in `zone`, like the backend's `day_bounds`.
    static func dayBounds(_ dayKey: String, zone: TimeZone) -> (start: Date, end: Date)? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let calendar = calendar(zone)
        guard let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    /// "YYYY-MM-DD" of `date` in `zone`.
    static func dayKey(_ date: Date, zone: TimeZone) -> String {
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Whole days from `earlier` to `later`, both "YYYY-MM-DD".
    static func daysBetween(_ earlier: String, _ later: String) -> Int {
        guard let start = dayBounds(earlier, zone: TimeZone(identifier: "UTC") ?? .current)?.start,
              let end = dayBounds(later, zone: TimeZone(identifier: "UTC") ?? .current)?.start else { return 0 }
        return Int((end.timeIntervalSince(start) / 86_400).rounded())
    }

    /// "YYYY-MM-DD" plus `days`.
    static func addDays(_ dayKey: String, _ days: Int) -> String {
        let utc = TimeZone(identifier: "UTC") ?? .current
        guard let start = dayBounds(dayKey, zone: utc)?.start,
              let moved = calendar(utc).date(byAdding: .day, value: days, to: start) else { return dayKey }
        return self.dayKey(moved, zone: utc)
    }
}
