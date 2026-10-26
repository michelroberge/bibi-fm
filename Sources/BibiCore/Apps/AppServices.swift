import Contacts
import EventKit
import Foundation

/// What app actions need from the Mac: AppleScript for Mail, Messages and discovered apps, EventKit for Calendar
/// and Reminders, the Contacts framework for names, and URLs for FaceTime. Tests swap in fakes.
public struct AppServices: Sendable {
    public var scripts: any ScriptRunner
    public var calendar: any CalendarStore
    public var contacts: any ContactStore
    public var opener: any URLOpener
    public var catalog: AppCatalog

    public init(scripts: any ScriptRunner = OSAScriptRunner(), calendar: any CalendarStore = EventKitStore(),
                contacts: any ContactStore = SystemContacts(), opener: any URLOpener = SystemOpener(),
                catalog: AppCatalog = AppCatalog()) {
        self.scripts = scripts; self.calendar = calendar; self.contacts = contacts; self.opener = opener; self.catalog = catalog
    }

    public static let system = AppServices()
}

// MARK: AppleScript

public protocol ScriptRunner: Sendable {
    /// Runs AppleScript `source`; `args` arrive as the run handler's argv, so user text never becomes script source.
    func run(_ source: String, args: [String], timeout: Double) async throws -> String
}

public struct OSAScriptRunner: ScriptRunner {
    public init() {}

    public func run(_ source: String, args: [String], timeout: Double) async throws -> String {
        // "-" reads the script from stdin; everything after it is argv, even values that start with "-".
        let out = await Command.run(["osascript", "-"] + args, timeout: timeout, input: source)
        if out.timedOut { throw ActionError("the app didn't answer within \(Int(timeout))s") }
        guard out.ok else { throw ActionError(Self.explain(out.stderr)) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// osascript errors look like "0:120: execution error: Mail got an error: … (-1728)".
    static func explain(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("(-1743)") {
            return "macOS didn't let bibi control this app: allow it in System Settings > Privacy & Security > Automation"
        }
        if text.contains("(-600)") { return "the app isn't running and couldn't be started" }
        let msg = text.components(separatedBy: "execution error: ").last ?? text
        return Text.oneLine(msg.replacingOccurrences(of: #"\s*\(-?\d+\)$"#, with: "", options: .regularExpression), max: 300)
            .ifEmpty("the script failed")
    }
}

// MARK: URLs

public protocol URLOpener: Sendable {
    func open(_ url: String) async throws
}

public struct SystemOpener: URLOpener {
    public init() {}
    public func open(_ url: String) async throws { try await Command.run(["open", url]).check() }
}

// MARK: Contacts

public struct ContactCard: Codable, Sendable, Equatable {
    public var name: String
    public var emails: [String]
    /// Numbers with their Contacts label ("mobile", "iPhone", "work"...).
    public var phones: [Phone]

    public struct Phone: Codable, Sendable, Equatable {
        public var label: String
        public var number: String
        public init(_ label: String, _ number: String) { self.label = label; self.number = number }
    }

    public init(name: String, emails: [String] = [], phones: [Phone] = []) {
        self.name = name; self.emails = emails; self.phones = phones
    }
}

public protocol ContactStore: Sendable {
    /// People whose name (full, first, last or nickname) is `query`, or who have `query` as an address.
    func find(_ query: String) async throws -> [ContactCard]
}

public struct SystemContacts: ContactStore {
    public init() {}

    public func find(_ query: String) async throws -> [ContactCard] {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            guard (try? await store.requestAccess(for: .contacts)) == true else { throw Permissions.denied("Contacts") }
        case .denied, .restricted: throw Permissions.denied("Contacts")
        default: break
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                    CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let predicate = query.contains("@") ? CNContact.predicateForContacts(matchingEmailAddress: query)
                                            : CNContact.predicateForContacts(matchingName: query)
        let all: [CNContact]
        do { all = try store.unifiedContacts(matching: predicate, keysToFetch: keys) } catch let e as CNError where e.code == .authorizationDenied {
            throw Permissions.denied("Contacts")
        }
        return all.compactMap { c in
            let full = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let card = ContactCard(
                name: full.ifEmpty(c.organizationName),
                emails: c.emailAddresses.map { $0.value as String },
                phones: c.phoneNumbers.map { .init(CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? ""), $0.value.stringValue) })
            // matchingName also matches prefixes ("Mar" finds "Marie"); only whole names count.
            let names = [full, c.givenName, c.familyName, c.nickname, c.organizationName]
            return query.contains("@") || names.contains(where: { Contacts.same($0, query) }) ? card : nil
        }
    }
}

enum Permissions {
    /// What to do when macOS said no (or never asked because bibi wasn't its own responsible process).
    static func denied(_ what: String) -> ActionError {
        ActionError("bibi isn't allowed to use \(what). Run `bibi apps permissions` and allow it, or turn on bibi under "
                    + "System Settings > Privacy & Security > \(what). If bibi isn't listed there, restart `bibi ui` from the "
                    + "latest build so macOS can ask.")
    }
}

public enum Contacts {
    static func same(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

// MARK: Calendar and Reminders

public struct CalendarItem: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: Date?
    public var end: Date?
    public var allDay: Bool
    public var calendar: String
    public var location: String?
    public var notes: String?
    public var completed: Bool?

    public init(id: String, title: String, start: Date? = nil, end: Date? = nil, allDay: Bool = false, calendar: String,
                location: String? = nil, notes: String? = nil, completed: Bool? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.calendar = calendar
        self.location = location; self.notes = notes; self.completed = completed
    }
}

public struct NewEvent: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var calendar: String?
    public var location: String?
    public var notes: String?
}

public protocol CalendarStore: Sendable {
    /// Event occurrences (repeating events expanded) that overlap the range.
    func events(from: Date, to: Date, calendar: String?) async throws -> [CalendarItem]
    func addEvent(_ e: NewEvent) async throws -> CalendarItem
    func removeEvent(id: String) async throws
    func reminders(list: String?, includeCompleted: Bool) async throws -> [CalendarItem]
    func addReminder(title: String, due: Date?, dueHasTime: Bool, list: String?, notes: String?) async throws -> CalendarItem
    func setCompleted(id: String, _ done: Bool) async throws -> CalendarItem
    func removeReminder(id: String) async throws
}

/// EventKit, with a fresh store per call (EKEventStore isn't Sendable). macOS asks once for each kind of access.
public struct EventKitStore: CalendarStore {
    public init() {}

    func store(_ type: EKEntityType) async throws -> EKEventStore {
        let s = EKEventStore(), what = type == .event ? "Calendars" : "Reminders"
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return s
        case .notDetermined:
            let granted = type == .event ? try? await s.requestFullAccessToEvents() : try? await s.requestFullAccessToReminders()
            guard granted == true else { throw Permissions.denied(what) }
            return s
        default: throw Permissions.denied(what)
        }
    }

    func calendar(_ s: EKEventStore, _ name: String?, _ type: EKEntityType) throws -> EKCalendar? {
        guard let name, !name.isEmpty else { return nil }
        let all = s.calendars(for: type)
        if let c = all.first(where: { Contacts.same($0.title, name) }) { return c }
        let kind = type == .event ? "calendar" : "list"
        throw ActionError("there is no \(kind) named \(name) (have: \(all.map(\.title).sorted().joined(separator: ", ")))")
    }

    static func item(_ e: EKEvent) -> CalendarItem {
        CalendarItem(id: e.eventIdentifier ?? "", title: e.title ?? "", start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                     calendar: e.calendar?.title ?? "", location: e.location, notes: e.notes)
    }

    static func item(_ r: EKReminder) -> CalendarItem {
        CalendarItem(id: r.calendarItemIdentifier, title: r.title ?? "", start: r.dueDateComponents?.date,
                     allDay: r.dueDateComponents.map { $0.hour == nil } ?? false, calendar: r.calendar?.title ?? "",
                     notes: r.notes, completed: r.isCompleted)
    }

    public func events(from: Date, to: Date, calendar name: String?) async throws -> [CalendarItem] {
        let s = try await store(.event)
        defer { withExtendedLifetime(s) {} }  // items read nothing once their store is released
        let cals = try calendar(s, name, .event).map { [$0] }
        return s.events(matching: s.predicateForEvents(withStart: from, end: to, calendars: cals)).map(Self.item)
    }

    public func addEvent(_ n: NewEvent) async throws -> CalendarItem {
        let s = try await store(.event)
        defer { withExtendedLifetime(s) {} }  // items read nothing once their store is released
        let e = EKEvent(eventStore: s)
        e.title = n.title; e.startDate = n.start; e.endDate = n.end; e.isAllDay = n.allDay
        e.location = n.location; e.notes = n.notes
        guard let cal = try calendar(s, n.calendar, .event) ?? s.defaultCalendarForNewEvents else {
            throw ActionError("there is no default calendar; name one with calendar=")
        }
        e.calendar = cal
        try s.save(e, span: .thisEvent, commit: true)
        return Self.item(e)
    }

    public func removeEvent(id: String) async throws {
        let s = try await store(.event)
        defer { withExtendedLifetime(s) {} }  // items read nothing once their store is released
        guard let e = s.event(withIdentifier: id) else { throw ActionError("the event is gone") }
        try s.remove(e, span: .thisEvent, commit: true)
    }

    func fetch(_ s: EKEventStore, _ cals: [EKCalendar]?, includeCompleted: Bool) async -> [CalendarItem] {
        let p = includeCompleted ? s.predicateForReminders(in: cals)
                                 : s.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        let items = await withCheckedContinuation { cont in
            s.fetchReminders(matching: p) { cont.resume(returning: ($0 ?? []).map(Self.item)) }
        }
        withExtendedLifetime(s) {}
        return items
    }

    public func reminders(list: String?, includeCompleted: Bool) async throws -> [CalendarItem] {
        let s = try await store(.reminder)
        defer { withExtendedLifetime(s) {} }  // items read nothing once their store is released
        return await fetch(s, try calendar(s, list, .reminder).map { [$0] }, includeCompleted: includeCompleted)
    }

    public func addReminder(title: String, due: Date?, dueHasTime: Bool, list: String?, notes: String?) async throws -> CalendarItem {
        let s = try await store(.reminder)
        defer { withExtendedLifetime(s) {} }  // items read nothing once their store is released
        let r = EKReminder(eventStore: s)
        r.title = title; r.notes = notes
        if let due {
            let parts: Set<Calendar.Component> = dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            r.dueDateComponents = Calendar.current.dateComponents(parts, from: due)
            if dueHasTime { r.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        guard let cal = try calendar(s, list, .reminder) ?? s.defaultCalendarForNewReminders() else {
            throw ActionError("there is no default Reminders list; name one with list=")
        }
        r.calendar = cal
        try s.save(r, commit: true)
        return Self.item(r)
    }

    func reminder(_ s: EKEventStore, _ id: String) throws -> EKReminder {
        guard let r = s.calendarItem(withIdentifier: id) as? EKReminder else { throw ActionError("the reminder is gone") }
        return r
    }

    public func setCompleted(id: String, _ done: Bool) async throws -> CalendarItem {
        let s = try await store(.reminder)
        defer { withExtendedLifetime(s) {} }  // items read nothing once their store is released
        let r = try reminder(s, id)
        r.isCompleted = done
        try s.save(r, commit: true)
        return Self.item(r)
    }

    public func removeReminder(id: String) async throws {
        let s = try await store(.reminder)
        defer { withExtendedLifetime(s) {} }  // items read nothing once their store is released
        try s.remove(try reminder(s, id), commit: true)
    }
}
