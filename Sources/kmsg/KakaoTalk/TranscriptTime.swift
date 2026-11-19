import Foundation

/// Pure helpers for turning KakaoTalk time labels and `--since` arguments into dates.
enum TranscriptTime {
    /// Minute of day for "오전 10:34", "오후 1:32", or "13:05".
    static func minuteOfDay(from timeRaw: String?) -> Int? {
        guard let timeRaw else { return nil }
        let trimmed = timeRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let meridiemRange = trimmed.range(
            of: #"(오전|오후)\s*([1-9]|1[0-2]):([0-5][0-9])"#,
            options: .regularExpression
        ) {
            let token = String(trimmed[meridiemRange])
                .replacingOccurrences(of: "오전", with: "")
                .replacingOccurrences(of: "오후", with: "")
                .trimmingCharacters(in: .whitespaces)
            let parts = token.split(separator: ":")
            guard parts.count == 2,
                  let hourPart = Int(parts[0]),
                  let minutePart = Int(parts[1])
            else {
                return nil
            }

            var hour = hourPart % 12
            if trimmed.contains("오후") {
                hour += 12
            }
            return hour * 60 + minutePart
        }

        if let range = trimmed.range(
            of: #"([01]?[0-9]|2[0-3]):([0-5][0-9])"#,
            options: .regularExpression
        ) {
            let token = String(trimmed[range])
            let parts = token.split(separator: ":")
            guard parts.count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1])
            else {
                return nil
            }
            return hour * 60 + minute
        }

        return nil
    }

    /// The time of a message's own time label ("오전 10:34", "오후 1:32", "13:05").
    /// KakaoTalk may prefix the label with a read-receipt count line ("1\n오후 1:17");
    /// that line is dropped and only the time is returned. Any other mixed text
    /// (bodies or quotes that mention a time, a bare count like "1") is rejected.
    static func timeLabel(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let candidate: String
        switch lines.count {
        case 1:
            candidate = lines[0]
        case 2 where lines[0].range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil:
            candidate = lines[1]
        default:
            return nil
        }
        let patterns = [
            #"^(오전|오후)\s*([1-9]|1[0-2]):[0-5][0-9]$"#,
            #"^([01]?[0-9]|2[0-3]):[0-5][0-9]$"#,
        ]
        for pattern in patterns where candidate.range(of: pattern, options: .regularExpression) != nil {
            return candidate
        }
        return nil
    }

    /// Start of the local day for a "YYYY-MM-DD" message date.
    static func localDay(_ date: String?, calendar: Calendar = .current) -> Date? {
        guard let date else { return nil }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Local timestamp for a message's `date` ("YYYY-MM-DD") plus `time_raw` ("오전 10:34").
    static func localDate(date: String?, timeRaw: String?, calendar: Calendar = .current) -> Date? {
        guard let day = localDay(date, calendar: calendar),
              let minute = minuteOfDay(from: timeRaw)
        else {
            return nil
        }
        return calendar.date(byAdding: .minute, value: minute, to: day)
    }

    /// Start of day for a date separator label such as "2026년 11월 10일 월요일".
    /// The whole label must match, so sentences that mention a date are ignored.
    static func separatorDay(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.range(
                  of: #"^(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일(?:\s+\S+요일)?$"#,
                  options: .regularExpression
              ) != nil
        else {
            return nil
        }
        let numbers = trimmed.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 3 else { return nil }
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2]))
    }

    /// Message times only have minute precision, so compare against the start of `since`'s minute.
    static func minuteFloor(_ date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }
}

enum SinceParser {
    /// Parses `--since`: ISO 8601 ("2026-11-18T07:00:00+09:00"; local time when no offset)
    /// or a relative span ("90m", "24h", "2d").
    static func parse(_ raw: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let relative = parseRelative(trimmed, now: now) {
            return relative
        }

        for options in [
            ISO8601DateFormatter.Options.withInternetDateTime,
            [.withInternetDateTime, .withFractionalSeconds],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        for format in [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    static func parseRelative(_ raw: String, now: Date = Date()) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let unit = trimmed.last, "mhd".contains(unit) else { return nil }
        let number = trimmed.dropLast()
        guard !number.isEmpty, number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber),
              let amount = Int(number), amount > 0
        else {
            return nil
        }
        let seconds: TimeInterval
        switch unit {
        case "m": seconds = 60
        case "h": seconds = 3_600
        default: seconds = 86_400
        }
        return now.addingTimeInterval(-Double(amount) * seconds)
    }

    /// Local-offset ISO 8601 rendering used in JSON output ("2026-11-18T07:00:00+09:00").
    static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

enum UnreadBadgeParser {
    /// Parses a chat-list unread badge ("3", "1,024", "999+") into a count and
    /// whether KakaoTalk capped the displayed number.
    static func parse(_ raw: String?) -> (count: Int, capped: Bool)? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.filter { $0 != "+" && $0 != "," }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(digits) else {
            return nil
        }
        return (count, trimmed.contains("+"))
    }
}
