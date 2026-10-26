import Foundation

/// Built-in app actions: the everyday ones (mail, calendar, reminders, contacts, calls, messages) done with fixed
/// scripts and frameworks, so they work the same every time. Other apps go through discovered app calls.
public enum Recipes {
    public static let all: [any ActionSpec] = [
        MailSend(), MailAccounts(), ContactsFind(), CalendarList(), CalendarAdd(), CalendarRemove(), RemindersList(),
        ReminderAdd(), ReminderComplete(), ReminderSetCompleted(), ReminderRemove(), FaceTimeCall(), MessageSend(),
        RunAppCall(), AppDelete(),
    ]

    /// How chat offers each one: its parameters and the words that make it relevant.
    public static let hints: [String: (hint: String, words: String)] = [
        "mail_send": ("to=name or address (comma-separated), subject=..., body=..., cc=..., from=one of your addresses (optional)",
                      "email mail send write reply message courriel envoie envoyer écris écrire répondre"),
        "mail_accounts": ("no args", "email mail account accounts address addresses from compte comptes adresse courriel"),
        "contacts_find": ("name=...", "contact contacts phone number address email who numéro téléphone adresse"),
        "calendar_list": ("from=the day the user said, to=... (optional), calendar=... only when the user names one",
                          "calendar agenda schedule meeting meetings event events busy free today tomorrow week calendrier réunion rendez libre occupé semaine"),
        "calendar_add": ("title=..., start=the date and time the user said, end=... (optional), allday=true (optional), calendar=... only when the user names one, location=...",
                         "calendar add schedule book meeting event appointment calendrier ajoute ajouter réunion rendez planifie"),
        "reminders_list": ("no args, or list=... only when the user names a list", "reminder reminders todo todos task tasks rappel rappels tâche tâches"),
        "reminder_add": ("title=..., due=the date and time the user said (optional), list=... only when the user names one", "remind reminder todo task add rappel rappelle rappeler tâche"),
        "reminder_complete": ("title=... (as listed)", "done complete completed finish check reminder task terminé terminer coche rappel tâche"),
        "facetime_call": ("to=name, phone or address, via=audio|video|phone (default audio)", "call phone ring facetime dial video appelle appeler appel téléphone vidéo"),
        "message_send": ("to=name, phone or address, text=...", "text message imessage sms tell texto texte dis"),
    ]

    /// The app whose discovered capabilities a built-in action replaces (not offered next to it).
    public static let apps: [String: String] = [
        "mail_send": "com.apple.mail", "mail_accounts": "com.apple.mail", "contacts_find": "com.apple.AddressBook",
        "calendar_list": "com.apple.iCal", "calendar_add": "com.apple.iCal", "reminders_list": "com.apple.reminders",
        "reminder_add": "com.apple.reminders", "reminder_complete": "com.apple.reminders", "message_send": "com.apple.MobileSMS",
        "facetime_call": "com.apple.FaceTime",
    ]

    /// The parameter a lone bare value means.
    public static let mainParam = ["contacts_find": "name", "calendar_add": "title", "reminder_add": "title",
                                   "reminder_complete": "title", "facetime_call": "to"]

    // MARK: addresses

    static func isEmail(_ s: String) -> Bool { Re.test(#"^[^@\s<>,;]+@[^@\s<>,;]+\.[^@\s<>,;]+$"#, s) }

    static func isPhone(_ s: String) -> Bool {
        Re.test(#"^\+?[0-9][0-9 ().-]*$"#, s) && s.filter(\.isNumber).count >= 3
    }

    /// "Marie Dupont <marie@example.com>" or a bare address.
    static func address(_ s: String) -> (name: String?, value: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let m = Re.all(#"^(.*?)\s*<([^<>]+)>$"#, t).first, m.count == 3 {
            return (m[1].isEmpty ? nil : m[1], m[2].trimmingCharacters(in: .whitespaces))
        }
        return (nil, t)
    }

    static func list(_ s: String?) -> [String] {
        (s ?? "").split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Which parameters of which actions hold people, and whether a phone number will do.
    static let people: [String: (keys: [String], phone: Bool)] = [
        "action:mail_send": (["to", "cc", "bcc"], false), "action:message_send": (["to"], true), "action:facetime_call": (["to"], true),
    ]

    /// True if the user (or a result in the conversation) mentioned this name, address or number: small models
    /// copy example names and invent addresses, and an outbound step must only reach someone the user meant.
    static func mentioned(_ value: String, in said: String) -> Bool {
        if isPhone(value) && !isEmail(value) {
            let digits = value.filter(\.isNumber)
            return Re.all(#"\+?[0-9][0-9 ().-]{4,}[0-9]"#, said).compactMap(\.first).map { $0.filter(\.isNumber) }
                .contains { $0.hasSuffix(digits) || digits.hasSuffix($0) && $0.count >= 7 }
        }
        return said.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Replaces names in recipient parameters with the one address Contacts has for them, so the approval card
    /// shows exactly who gets the message or call. A recipient that wasn't mentioned in `said`, or whose name
    /// doesn't resolve to exactly one address, is taken out of the step, and the reason is filed under its field
    /// (one entry of `problems` per step, by field key).
    public static func resolveRecipients(_ steps: [PlannedStep], contacts: any ContactStore, said: String) async
        -> (steps: [PlannedStep], problems: [[String: String]]) {
        var out: [PlannedStep] = [], problems: [[String: String]] = []
        for var s in steps {
            var found: [String: String] = [:]
            defer { out.append(s); problems.append(found) }
            guard let spec = people[s.tool] else { continue }
            if s.args.count == 1, !s.args[0].contains("="), let main = mainParam[String(s.tool.dropFirst(7))] { s.args[0] = main + "=" + s.args[0] }
            for (i, a) in s.args.enumerated() {
                guard let eq = a.firstIndex(of: "=") else { continue }
                let key = a[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                guard spec.keys.contains(key) else { continue }
                var resolved: [String] = [], why: [String] = []
                for item in list(String(a[a.index(after: eq)...])) {
                    let v = address(item).value
                    guard mentioned(v, in: said) else {
                        why.append("\(v) wasn't mentioned in this conversation; who should get it?")
                        continue
                    }
                    if isEmail(v) || (spec.phone && isPhone(v)) { resolved.append(item); continue }
                    switch await lookup(v, phone: spec.phone, contacts: contacts) {
                    case .success(let r): resolved.append(r)
                    case .failure(let e): why.append(e.description)
                    }
                }
                s.args[i] = String(a[...eq]) + resolved.joined(separator: ", ")
                if !why.isEmpty { found[key] = why.joined(separator: " ") }
            }
        }
        return (out, problems)
    }

    static func lookup(_ name: String, phone: Bool, contacts: any ContactStore) async -> Result<String, ActionError> {
        let found: [ContactCard]
        do { found = try await contacts.find(name) } catch { return .failure(ActionError("couldn't look up \(name): \(error)")) }
        guard !found.isEmpty else { return .failure(ActionError("\(name) isn't in Contacts; give an address or number")) }
        guard found.count == 1, let c = found.first else {
            return .failure(ActionError("\(name) matches \(found.count) contacts (\(found.map(\.name).joined(separator: ", "))); say which"))
        }
        if phone {
            let mobile = c.phones.filter { ["mobile", "iphone", "cell"].contains($0.label.lowercased()) }
            if mobile.count == 1 { return .success("\(c.name) <\(mobile[0].number)>") }
            if c.phones.count == 1 { return .success("\(c.name) <\(c.phones[0].number)>") }
            if c.phones.isEmpty, c.emails.count == 1 { return .success("\(c.name) <\(c.emails[0])>") }
            if c.phones.isEmpty {
                return .failure(ActionError(c.emails.isEmpty ? "\(c.name) has no phone number or address in Contacts"
                                                             : "\(c.name) has several addresses (\(c.emails.joined(separator: ", "))); say which"))
            }
            let all = c.phones.map { "\($0.number) (\($0.label))" }
            return .failure(ActionError("\(c.name) has several numbers (\(all.joined(separator: ", "))); say which"))
        }
        if c.emails.count == 1 { return .success("\(c.name) <\(c.emails[0])>") }
        return .failure(ActionError(c.emails.isEmpty ? "\(c.name) has no email address in Contacts"
                                                     : "\(c.name) has several addresses (\(c.emails.joined(separator: ", "))); say which"))
    }

    // MARK: dates

    /// Calendar and list names the model wrote that the user never said ("calendar=calendar") are dropped: the
    /// default calendar or list, or all of them when listing, is what the user meant.
    public static func groundNames(_ steps: [PlannedStep], said: String) -> [PlannedStep] {
        steps.map { s in
            guard s.tool.hasPrefix("action:calendar_") || s.tool.hasPrefix("action:reminder") else { return s }
            var s = s
            s.args.removeAll { a in
                let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 && ["calendar", "list"].contains(parts[0].lowercased()) && !mentioned(parts[1], in: said)
            }
            return s
        }
    }

    /// The date parameter that the user's words set for each action.
    static let dateParams = ["reminder_add": "due", "calendar_add": "start", "calendar_list": "from"]

    /// Small models turn "demain à 9h" into a wrong absolute date. When the user's message names a date, that
    /// date is used, whatever the model wrote; an end before the new start is dropped (an hour is the default).
    public static func groundDates(_ steps: [PlannedStep], request: String, now: Date = Date()) -> [PlannedStep] {
        guard let said = DateText.find(in: request, now: now) else { return steps }
        let exact = DateText.format(said.date, time: said.hasTime)
        return steps.map { s in
            guard s.tool.hasPrefix("action:"), let key = dateParams[String(s.tool.dropFirst(7))] else { return s }
            var s = s
            s.args.removeAll { $0.lowercased().hasPrefix(key + "=") }
            s.args.append(key + "=" + exact)
            // An end the model wrote for its own (wrong) start is dropped when it doesn't fit the user's.
            if let endKey = ["start": "end", "from": "to"][key] {
                s.args.removeAll { a in
                    guard a.lowercased().hasPrefix(endKey + "="), let end = DateText.parse(String(a.dropFirst(endKey.count + 1)), now: now) else { return false }
                    return end.date <= said.date || (key == "start" && !Calendar.current.isDate(end.date, inSameDayAs: said.date))
                }
            }
            return s
        }
    }

    static func normalizeDates(_ p: Params, _ keys: [String]) -> Params {
        var p = p
        for k in keys { if let v = p[k], let d = DateText.normalize(v) { p[k] = d } }
        return p
    }

    static func date(_ p: Params, _ key: String, _ id: String) throws -> (date: Date, hasTime: Bool)? {
        guard let v = p[key], !v.isEmpty else { return nil }
        guard let d = DateText.strict(v) else { throw ActionError("\(id): \(key): must be a date like 2026-10-27 15:00, got \(v)") }
        return d
    }

    /// For something new (an event, a reminder): a date well in the past is the model's invention, not the user's.
    static func future(_ p: Params, _ key: String, _ id: String, now: Date = Date()) throws -> (date: Date, hasTime: Bool)? {
        guard let d = try date(p, key, id) else { return nil }
        let end = d.hasTime ? d.date : Calendar.current.date(byAdding: .day, value: 1, to: d.date)!
        guard end > now.addingTimeInterval(-12 * 3600) else {
            throw ActionError("\(id): \(key): \(p[key]!) is in the past; write the date as the user said it, like \"tomorrow 9am\"")
        }
        return d
    }

    static func when(_ item: CalendarItem) -> String {
        guard let s = item.start else { return "" }
        if item.allDay { return DateText.display(s, time: false) + " all day" }
        let end = item.end.map { Calendar.current.isDate($0, inSameDayAs: s) ? DateText.formatter("HH:mm").string(from: $0) : DateText.display($0, time: true) }
        return DateText.display(s, time: true) + (end.map { "–" + $0 } ?? "")
    }
}

// MARK: Mail

public struct MailSend: ActionSpec {
    public let id = "mail_send"
    public let summary = "Send an email from one of your Mail accounts"
    public var kind: String? { "outbound" }
    public var fields: [ActionField] {
        [.init("to", "To", kind: "addresses", required: true, placeholder: "names or addresses, comma-separated"),
         .init("from", "From", kind: "choice", source: "mail_accounts", placeholder: "Mail's default account"),
         .init("cc", "Cc", kind: "addresses"),
         .init("subject", "Subject"),
         .init("body", "Message", kind: "longtext", required: true)]
    }
    public init() {}

    struct Message {
        var to: [(name: String?, value: String)], cc: [(name: String?, value: String)], bcc: [(name: String?, value: String)]
        var subject: String, body: String, from: String?
    }

    func message(_ p: Params) throws -> Message {
        let parse = { (key: String) throws -> [(name: String?, value: String)] in
            try Recipes.list(p[key]).map { item in
                let a = Recipes.address(item)
                guard Recipes.isEmail(a.value) else { throw ActionError("\(key): \(item) is not an email address") }
                return a
            }
        }
        // The text first: a step whose recipient is also wrong still says what else is missing.
        let subject = p["subject"] ?? "", body = p["body"] ?? ""
        guard !subject.isEmpty || !body.isEmpty else { throw ActionError("body: the email has no text yet") }
        guard body.count <= 50_000 else { throw ActionError("body: too long") }
        let m = Message(to: try parse("to"), cc: try parse("cc"), bcc: try parse("bcc"), subject: subject, body: body,
                        from: p["from"].flatMap { $0.isEmpty ? nil : Recipes.address($0).value })
        guard !m.to.isEmpty else { throw ActionError("to: needed") }
        if let f = m.from, !Recipes.isEmail(f) { throw ActionError("from: \(f) is not an email address") }
        return m
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try message(p) }

    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let m = try message(p)
        let show = { (xs: [(name: String?, value: String)]) in
            xs.map { a in a.name.map { "\($0) <\(a.value)>" } ?? a.value }.joined(separator: ", ")
        }
        var lines = ["send an email from \(m.from ?? "Mail's default account")", "to: " + show(m.to)]
        if !m.cc.isEmpty { lines.append("cc: " + show(m.cc)) }
        if !m.bcc.isEmpty { lines.append("bcc: " + show(m.bcc)) }
        return lines + ["subject: " + m.subject, "body: " + m.body, "(sends right away; cannot be undone)"]
    }

    static let script = """
    on run argv
    \tset fromAddr to item 6 of argv
    \ttell application id "com.apple.mail"
    \t\tif fromAddr is not "" then
    \t\t\tset known to false
    \t\t\trepeat with a in accounts
    \t\t\t\tif (email addresses of a) contains fromAddr then set known to true
    \t\t\tend repeat
    \t\t\tif not known then error "no Mail account sends from " & fromAddr
    \t\tend if
    \t\tset m to make new outgoing message with properties {subject:(item 4 of argv), content:(item 5 of argv), visible:false}
    \t\ttell m
    \t\t\trepeat with x in paragraphs of (item 1 of argv)
    \t\t\t\tmake new to recipient at end of to recipients with properties {address:(contents of x)}
    \t\t\tend repeat
    \t\t\trepeat with x in paragraphs of (item 2 of argv)
    \t\t\t\tmake new cc recipient at end of cc recipients with properties {address:(contents of x)}
    \t\t\tend repeat
    \t\t\trepeat with x in paragraphs of (item 3 of argv)
    \t\t\t\tmake new bcc recipient at end of bcc recipients with properties {address:(contents of x)}
    \t\t\tend repeat
    \t\tend tell
    \t\tif fromAddr is not "" then set sender of m to fromAddr
    \t\tif not (send m) then error "Mail didn't send the message"
    \tend tell
    \treturn "sent"
    end run
    """

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let m = try message(p)
        let lines = { (xs: [(name: String?, value: String)]) in xs.map(\.value).joined(separator: "\n") }
        _ = try await env.apps.scripts.run(Self.script, args: [lines(m.to), lines(m.cc), lines(m.bcc), m.subject, m.body, m.from ?? ""],
                                           timeout: 90)
        return Outcome("sent \"\(Text.oneLine(m.subject, max: 60))\" to \(m.to.map(\.value).joined(separator: ", "))")
    }
}

public struct MailAccounts: ActionSpec {
    public let id = "mail_accounts"
    public let summary = "List your Mail accounts and the addresses they send from"
    public var kind: String? { "read-only" }
    public init() {}

    public static let script = AppScripts.helpers + """
    on run argv
    \ttell application id "com.apple.mail"
    \t\tset out to {}
    \t\trepeat with a in accounts
    \t\t\tset row to (name of a) & ": " & my joinlist(email addresses of a, ", ")
    \t\t\tif not (enabled of a) then set row to row & " (disabled)"
    \t\t\tset end of out to row
    \t\tend repeat
    \tend tell
    \treturn my joinlist(out, linefeed)
    end run
    """

    public func validate(_ p: Params, _ env: ActionEnv) throws {}
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["list the accounts in Mail   (read-only)"] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let out = try await env.apps.scripts.run(Self.script, args: [], timeout: 60)
        return Outcome("read Mail accounts", output: out.ifEmpty("Mail has no accounts"))
    }
}

// MARK: Contacts

public struct ContactsFind: ActionSpec {
    public let id = "contacts_find"
    public let summary = "Look someone up in Contacts (addresses and phone numbers)"
    public var kind: String? { "read-only" }
    public init() {}

    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try require(p, "name") }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["look up \(p["name"]!) in Contacts   (read-only)"] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let found = try await env.apps.contacts.find(p["name"]!)
        let lines = found.prefix(10).map { c in
            ([c.name] + c.emails.map { "email \($0)" } + c.phones.map { "phone (\($0.label.ifEmpty("other"))) \($0.number)" })
                .joined(separator: " — ")
        }
        return Outcome("looked up \(p["name"]!)", output: lines.isEmpty ? "nobody named \(p["name"]!) in Contacts" : lines.joined(separator: "\n"))
    }
}

// MARK: Calendar

public struct CalendarList: ActionSpec {
    public let id = "calendar_list"
    public let summary = "List calendar events in a date range (repeating events included)"
    public var kind: String? { "read-only" }
    public init() {}

    public func normalize(_ p: Params, _ env: ActionEnv) -> Params { Recipes.normalizeDates(p, ["from", "to"]) }

    func range(_ p: Params, now: Date = Date()) throws -> (Date, Date) {
        let cal = Calendar.current
        let from = try Recipes.date(p, "from", id)
        let start = from?.date ?? cal.startOfDay(for: now)
        let end = try Recipes.date(p, "to", id).map { $0.hasTime ? $0.date : cal.date(byAdding: .day, value: 1, to: $0.date)! }
            ?? cal.date(byAdding: .day, value: from == nil ? 7 : 1, to: from.map { cal.startOfDay(for: $0.date) } ?? start)!
        guard end > start else { throw ActionError("calendar_list: to is before from") }
        return (start, end)
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try range(p) }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let (s, e) = try range(p)
        return ["list events from \(DateText.format(s, time: true)) to \(DateText.format(e, time: true))"
                + (p["calendar"].map { " in \($0)" } ?? "") + "   (read-only)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let (s, e) = try range(p)
        let items = try await env.apps.calendar.events(from: s, to: e, calendar: p["calendar"].flatMap { $0.isEmpty ? nil : $0 })
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        let lines = items.prefix(100).map { i in
            "\(Recipes.when(i))  \(i.title) (\(i.calendar))" + (i.location.flatMap { $0.isEmpty ? nil : " @ " + $0 } ?? "")
        }
        return Outcome("read \(items.count) event(s)", output: lines.isEmpty ? "no events in that range" : lines.joined(separator: "\n"))
    }
}

public struct CalendarAdd: ActionSpec {
    public let id = "calendar_add"
    public let summary = "Add an event to your calendar"
    public var reversible: Bool { true }
    public var fields: [ActionField] {
        [.init("title", "Title", required: true), .init("start", "Starts", kind: "datetime", required: true),
         .init("end", "Ends", kind: "datetime", placeholder: "an hour later"), .init("allday", "All day", kind: "bool"),
         .init("calendar", "Calendar", kind: "choice", source: "calendars", placeholder: "your default calendar"),
         .init("location", "Location"), .init("notes", "Notes", kind: "longtext")]
    }
    public init() {}

    public func normalize(_ p: Params, _ env: ActionEnv) -> Params { Recipes.normalizeDates(p, ["start", "end"]) }

    func event(_ p: Params) throws -> NewEvent {
        let title = try require(p, "title")
        guard let start = try Recipes.future(p, "start", id) else { throw ActionError("calendar_add: missing parameter start") }
        let allDay = p["allday"].map { ["true", "yes"].contains($0.lowercased()) } ?? !start.hasTime
        let end = try Recipes.date(p, "end", id)?.date
            ?? (allDay ? start.date : Calendar.current.date(byAdding: .hour, value: 1, to: start.date)!)
        guard end >= start.date else { throw ActionError("end: the event ends before it starts") }
        let opt = { (k: String) in p[k].flatMap { $0.isEmpty ? nil : $0 } }
        return NewEvent(title: title, start: start.date, end: end, allDay: allDay, calendar: opt("calendar"),
                        location: opt("location"), notes: opt("notes"))
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try event(p) }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let e = try event(p)
        let item = CalendarItem(id: "", title: e.title, start: e.start, end: e.end, allDay: e.allDay, calendar: "")
        return ["add \"\(e.title)\" to \(e.calendar ?? "your default calendar"): \(Recipes.when(item))"
                + (e.location.map { " @ \($0)" } ?? ""), "(undo removes it)"]
    }

    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let item = try await env.apps.calendar.addEvent(try event(p))
        return Outcome("added \"\(item.title)\" to \(item.calendar) (\(Recipes.when(item)))",
                       undo: ActionCall("calendar_remove", ["id": item.id, "title": item.title]))
    }
}

public struct CalendarRemove: ActionSpec {
    public let id = "calendar_remove"
    public let summary = "Remove an event bibi added"
    public var selectable: Bool { false }
    public init() {}
    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try require(p, "id") }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["remove the event \"\(p["title"] ?? "")\" from your calendar"] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        try await env.apps.calendar.removeEvent(id: p["id"]!)
        return Outcome("removed \"\(p["title"] ?? "the event")\" from your calendar")
    }
}

// MARK: Reminders

public struct RemindersList: ActionSpec {
    public let id = "reminders_list"
    public let summary = "List your open reminders"
    public var kind: String? { "read-only" }
    public init() {}
    public func validate(_ p: Params, _ env: ActionEnv) throws {}
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["list \(p["completed"] == "true" ? "all" : "open") reminders" + (p["list"].map { " in \($0)" } ?? "") + "   (read-only)"]
    }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let items = try await env.apps.calendar.reminders(list: p["list"].flatMap { $0.isEmpty ? nil : $0 }, includeCompleted: p["completed"] == "true")
            .sorted { ($0.start ?? .distantFuture, $0.title) < ($1.start ?? .distantFuture, $1.title) }
        let lines = items.prefix(100).map { r in
            "- \(r.title)" + (r.start.map { " (due \(DateText.display($0, time: !r.allDay)))" } ?? "") + " [\(r.calendar)]"
                + (r.completed == true ? " done" : "")
        }
        return Outcome("read \(items.count) reminder(s)", output: lines.isEmpty ? "no reminders" : lines.joined(separator: "\n"))
    }
}

public struct ReminderAdd: ActionSpec {
    public let id = "reminder_add"
    public let summary = "Add a reminder"
    public var reversible: Bool { true }
    public var fields: [ActionField] {
        [.init("title", "Reminder", required: true), .init("due", "Due", kind: "datetime"),
         .init("list", "List", kind: "choice", source: "reminder_lists", placeholder: "your default list"),
         .init("notes", "Notes", kind: "longtext")]
    }
    public init() {}

    public func normalize(_ p: Params, _ env: ActionEnv) -> Params { Recipes.normalizeDates(p, ["due"]) }
    public func validate(_ p: Params, _ env: ActionEnv) throws {
        _ = try require(p, "title")
        _ = try Recipes.future(p, "due", id)
    }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let due = try Recipes.future(p, "due", id)
        return ["add the reminder \"\(p["title"]!)\" to \(p["list"].flatMap { $0.isEmpty ? nil : $0 } ?? "your default list")"
                + (due.map { ", due \(DateText.display($0.date, time: $0.hasTime))" } ?? ""), "(undo removes it)"]
    }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let due = try Recipes.future(p, "due", id)
        let r = try await env.apps.calendar.addReminder(title: p["title"]!, due: due?.date, dueHasTime: due?.hasTime ?? false,
                                                        list: p["list"].flatMap { $0.isEmpty ? nil : $0 },
                                                        notes: p["notes"].flatMap { $0.isEmpty ? nil : $0 })
        return Outcome("added the reminder \"\(r.title)\" to \(r.calendar)", undo: ActionCall("reminder_remove", ["id": r.id, "title": r.title]))
    }
}

public struct ReminderComplete: ActionSpec {
    public let id = "reminder_complete"
    public let summary = "Mark a reminder as done"
    public var reversible: Bool { true }
    public init() {}
    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try require(p, "title") }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["mark the reminder \"\(p["title"]!)\" as done", "(undo reopens it)"] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let title = p["title"]!
        let open = try await env.apps.calendar.reminders(list: p["list"].flatMap { $0.isEmpty ? nil : $0 }, includeCompleted: false)
        let hits = open.filter { Contacts.same($0.title, title) }
        guard hits.count == 1, let r = hits.first else {
            throw ActionError(hits.isEmpty ? "no open reminder is called \"\(title)\"" : "\(hits.count) open reminders are called \"\(title)\"; name the list")
        }
        _ = try await env.apps.calendar.setCompleted(id: r.id, true)
        return Outcome("marked \"\(r.title)\" as done", undo: ActionCall("reminder_set_completed", ["id": r.id, "title": r.title, "done": "false"]))
    }
}

/// Undo for reminder_complete.
public struct ReminderSetCompleted: ActionSpec {
    public let id = "reminder_set_completed"
    public let summary = "Reopen or complete a reminder"
    public var selectable: Bool { false }
    public init() {}
    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try require(p, "id") }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        ["mark the reminder \"\(p["title"] ?? "")\" as \(p["done"] == "true" ? "done" : "not done")"]
    }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let r = try await env.apps.calendar.setCompleted(id: p["id"]!, p["done"] == "true")
        return Outcome("marked \"\(r.title)\" as \(p["done"] == "true" ? "done" : "not done")")
    }
}

public struct ReminderRemove: ActionSpec {
    public let id = "reminder_remove"
    public let summary = "Remove a reminder bibi added"
    public var selectable: Bool { false }
    public init() {}
    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try require(p, "id") }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] { ["remove the reminder \"\(p["title"] ?? "")\""] }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        try await env.apps.calendar.removeReminder(id: p["id"]!)
        return Outcome("removed the reminder \"\(p["title"] ?? "")\"")
    }
}

// MARK: calls and messages

public struct FaceTimeCall: ActionSpec {
    public let id = "facetime_call"
    public let summary = "Call someone with FaceTime (audio or video) or through your iPhone"
    public var kind: String? { "outbound" }
    public var fields: [ActionField] {
        [.init("to", "Call", required: true, placeholder: "name, phone number or address"),
         .init("via", "How", kind: "choice", options: ["audio", "video", "phone"], placeholder: "audio")]
    }
    public init() {}

    func target(_ p: Params) throws -> (url: String, shown: String, via: String) {
        let a = Recipes.address(try require(p, "to"))
        let via = (p["via"] ?? "audio").lowercased()
        guard ["audio", "video", "phone"].contains(via) else { throw ActionError("via: must be audio, video or phone") }
        let email = Recipes.isEmail(a.value)
        guard email || Recipes.isPhone(a.value) else { throw ActionError("to: \(a.value) is not a phone number or address") }
        if via == "phone" && email { throw ActionError("to: a phone call needs a phone number") }
        let handle = email ? a.value : String(a.value.filter { $0.isNumber || $0 == "+" })
        let scheme = ["audio": "facetime-audio://", "video": "facetime://", "phone": "tel:"][via]!
        return (scheme + handle, a.name.map { "\($0) (\(a.value))" } ?? a.value, via)
    }

    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try target(p) }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let t = try target(p)
        let how = ["audio": "a FaceTime audio call", "video": "a FaceTime video call", "phone": "a phone call through your iPhone"][t.via]!
        return ["start \(how) to \(t.shown)", "(macOS may ask you to confirm before it dials)"]
    }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let t = try target(p)
        try await env.apps.opener.open(t.url)
        return Outcome("calling \(t.shown)")
    }
}

public struct MessageSend: ActionSpec {
    public let id = "message_send"
    public let summary = "Send an iMessage with Messages"
    public var kind: String? { "outbound" }
    public var fields: [ActionField] {
        [.init("to", "To", required: true, placeholder: "name, phone number or address"), .init("text", "Message", kind: "longtext", required: true)]
    }
    public init() {}

    func message(_ p: Params) throws -> (to: (name: String?, value: String), text: String) {
        let text = try require(p, "text")
        guard text.count <= 5000 else { throw ActionError("text: too long") }
        let a = Recipes.address(try require(p, "to"))
        guard Recipes.isEmail(a.value) || Recipes.isPhone(a.value) else { throw ActionError("to: \(a.value) is not a phone number or address") }
        return (a, text)
    }

    static let script = """
    on run argv
    \ttell application id "com.apple.MobileSMS"
    \t\tset svc to 1st account whose service type = iMessage
    \t\tset p to participant (item 1 of argv) of svc
    \t\tsend (item 2 of argv) to p
    \tend tell
    \treturn "sent"
    end run
    """

    public func validate(_ p: Params, _ env: ActionEnv) throws { _ = try message(p) }
    public func plan(_ p: Params, _ env: ActionEnv) throws -> [String] {
        let m = try message(p)
        return ["send an iMessage to \(m.to.name.map { "\($0) (\(m.to.value))" } ?? m.to.value)", "text: " + m.text,
                "(sends right away; cannot be undone)"]
    }
    public func execute(_ p: Params, _ env: ActionEnv) async throws -> Outcome {
        let m = try message(p)
        _ = try await env.apps.scripts.run(Self.script, args: [m.to.value, m.text], timeout: 60)
        return Outcome("sent the message to \(m.to.name ?? m.to.value)")
    }
}
