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
        let day = ["today": 0, "tonight": 0, "tomorrow": 1, "yesterday": -1,
                   "aujourd'hui": 0, "ce soir": 0, "demain": 1, "après-demain": 2, "hier": -1][lower.replacingOccurrences(of: "’", with: "'")]
        if let day, let d = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: now)) {
            return ["tonight", "ce soir"].contains(lower) ? (cal.date(byAdding: .hour, value: 20, to: d)!, true) : (d, false)
        }
        // "demain 15h", "demain à 9h30", "tomorrow at 3pm": a day word and a time. (The detector below would
        // read "tomorrow" from the real clock, not `now`.)
        if let m = Re.all(#"^(aujourd'hui|demain|today|tomorrow)\s+(?:à\s+|at\s+)?(\d{1,2})(?:(?:h|:)(\d{2})?|\s*(am|pm))$"#,
                          lower.replacingOccurrences(of: "’", with: "'")).first, m.count == 5,
           let base = parse(m[1], now: now), var h = Int(m[2]), h < 24 {
            if m[4] == "pm", h < 12 { h += 12 } else if m[4] == "am", h == 12 { h = 0 }
            return (cal.date(bySettingHour: h, minute: Int(m[3]) ?? 0, second: 0, of: base.date)!, true)
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let m = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = m.date else { return nil }
        let hasTime = Re.test(#"\d\s*(am|pm|a\.m\.|p\.m\.|h)\b|\d{1,2}:\d{2}|\bnoon\b|\bmidnight\b|\bmorning\b|\bafternoon\b|\bevening\b|\btonight\b"#,
                              lower)
        return (hasTime ? date : cal.startOfDay(for: date), hasTime)
    }

    /// The date the user's own words give in a whole sentence ("rappelle-moi demain à 9h", "tomorrow at 3pm",
    /// "vendredi", "à 19h"), or nil if they give none. The first time named is the one used ("de 9h à 10h" → 9:00).
    public static func find(in text: String, now: Date = Date()) -> (date: Date, hasTime: Bool)? {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\S+://\S+|\S+@\S+"#, with: " ", options: .regularExpression)
        let cal = Calendar.current, today = cal.startOfDay(for: now)
        var day: Date?
        let words: [(String, Int)] = [("après-demain", 2), ("apres-demain", 2), ("aujourd'hui", 0), ("demain", 1), ("ce soir", 0),
                                      ("tonight", 0), ("today", 0), ("tomorrow", 1)]
        if let (_, n) = words.first(where: { t.contains($0.0) }) { day = cal.date(byAdding: .day, value: n, to: today) }
        let weekdays = [["sunday", "dimanche"], ["monday", "lundi"], ["tuesday", "mardi"], ["wednesday", "mercredi"],
                        ["thursday", "jeudi"], ["friday", "vendredi"], ["saturday", "samedi"]]
        if day == nil, let i = weekdays.firstIndex(where: { $0.contains { Re.test("\\b\($0)\\b", t) } }) {
            day = cal.nextDate(after: today, matching: DateComponents(weekday: i + 1), matchingPolicy: .nextTime)
        }
        var hour: Int?, minute = 0
        if let m = Re.all(#"(?<![\d/:.-])(\d{1,2})\s*(?::|h)\s*(\d{2})?(?!\d)|(?<![\d/:.-])(\d{1,2})\s*(am|pm)\b"#, t).first {
            if !m[1].isEmpty, let h = Int(m[1]) { hour = h; minute = Int(m[2]) ?? 0 }
            else if let h = Int(m[3]) { hour = h % 12 + (m[4] == "pm" ? 12 : 0) }
        } else if Re.test(#"\b(midi|noon)\b"#, t) { hour = 12 }
        else if Re.test(#"\b(minuit|midnight)\b"#, t) { hour = 0 }
        else if Re.test("ce soir|tonight", t) { hour = 20 }
        if let h = hour, h < 24, minute < 60 {
            var d = cal.date(bySettingHour: h, minute: minute, second: 0, of: day ?? today)!
            // "à 19h" with no day: today, or tomorrow once that time has passed.
            if day == nil && d < now { d = cal.date(byAdding: .day, value: 1, to: d)! }
            return (d, true)
        }
        if let day { return (day, false) }
        return nil
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
