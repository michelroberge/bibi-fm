import Foundation

/// Dates in app actions. The model writes them in the user's words ("tomorrow 3pm"); bibi turns them into one
/// exact form when it proposes the step, so the card shows the exact time and the run doesn't depend on when it runs.
public enum DateText {
    /// The stored forms: "2026-10-27 15:00" (a time) or "2026-10-27" (a whole day), in local time.
    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    /// Parses the stored forms only (what validation accepts).
    public static func strict(_ text: String) -> (date: Date, hasTime: Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if Re.test(#"^\d{4}-\d{2}-\d{2}$"#, t), let d = formatter("yyyy-MM-dd").date(from: t) { return (d, false) }
        for f in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            if let d = formatter(f).date(from: t) { return (d, true) }
        }
        return nil
    }

    /// Parses the stored forms or natural language ("tomorrow at 3pm", "next friday", "oct 30 9:30").
    public static func parse(_ text: String, now: Date = Date()) -> (date: Date, hasTime: Bool)? {
        if let s = strict(text) { return s }
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current
        let day = ["today": 0, "tonight": 0, "tomorrow": 1, "yesterday": -1][lower]
        if let day, let d = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: now)) {
            return lower == "tonight" ? (cal.date(byAdding: .hour, value: 20, to: d)!, true) : (d, false)
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = m.date else { return nil }
        let hasTime = Re.test(#"\d\s*(am|pm|a\.m\.|p\.m\.|h)\b|\d{1,2}:\d{2}|\bnoon\b|\bmidnight\b|\bmorning\b|\bafternoon\b|\bevening\b|\btonight\b"#,
                              lower)
        return (hasTime ? date : cal.startOfDay(for: date), hasTime)
    }

    public static func format(_ d: Date, time: Bool) -> String {
        formatter(time ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd").string(from: d)
    }

    /// The stored form of `text`, or nil if it isn't a date.
    public static func normalize(_ text: String, now: Date = Date()) -> String? {
        parse(text, now: now).map { format($0.date, time: $0.hasTime) }
    }

    /// "Tue Oct 27 15:00" for answers.
    public static func display(_ d: Date, time: Bool) -> String {
        formatter(time ? "EEE MMM d HH:mm" : "EEE MMM d").string(from: d)
    }
}
