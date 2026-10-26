@testable import BibiCore
import Foundation
import Testing

// MARK: fakes

final class FakeScripts: ScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    private(set) var calls: [(source: String, args: [String])] = []

    init(_ outputs: [String] = ["done"]) { self.outputs = outputs }

    func run(_ source: String, args: [String], timeout: Double) async throws -> String {
        lock.withLock {
            calls.append((source, args))
            return outputs.count > 1 ? outputs.removeFirst() : outputs.first ?? ""
        }
    }
}

final class FakeCalendar: CalendarStore, @unchecked Sendable {
    private let lock = NSLock()
    var events: [CalendarItem] = []
    var reminderItems: [CalendarItem] = []
    private(set) var removed: [String] = []
    private(set) var queried: (Date, Date)?

    func events(from: Date, to: Date, calendar: String?) async throws -> [CalendarItem] {
        lock.withLock { queried = (from, to); return events.filter { calendar == nil || $0.calendar == calendar } }
    }
    func addEvent(_ e: NewEvent) async throws -> CalendarItem {
        let item = CalendarItem(id: "ev\(events.count + 1)", title: e.title, start: e.start, end: e.end, allDay: e.allDay,
                                calendar: e.calendar ?? "Home", location: e.location)
        lock.withLock { events.append(item) }
        return item
    }
    func removeEvent(id: String) async throws { lock.withLock { removed.append(id); events.removeAll { $0.id == id } } }
    func reminders(list: String?, includeCompleted: Bool) async throws -> [CalendarItem] {
        lock.withLock { reminderItems.filter { (includeCompleted || $0.completed != true) && (list == nil || $0.calendar == list) } }
    }
    func addReminder(title: String, due: Date?, dueHasTime: Bool, list: String?, notes: String?) async throws -> CalendarItem {
        let r = CalendarItem(id: "r\(reminderItems.count + 1)", title: title, start: due, allDay: !dueHasTime, calendar: list ?? "Reminders",
                             completed: false)
        lock.withLock { reminderItems.append(r) }
        return r
    }
    func setCompleted(id: String, _ done: Bool) async throws -> CalendarItem {
        try lock.withLock {
            guard let i = reminderItems.firstIndex(where: { $0.id == id }) else { throw ActionError("gone") }
            reminderItems[i].completed = done
            return reminderItems[i]
        }
    }
    func removeReminder(id: String) async throws { lock.withLock { removed.append(id); reminderItems.removeAll { $0.id == id } } }
}

/// Matches a whole name or any one word of it, like Contacts' whole-name matching.
struct FakeContacts: ContactStore {
    var people: [ContactCard] = []
    func find(_ query: String) async throws -> [ContactCard] {
        people.filter { c in c.name.lowercased() == query.lowercased() || c.name.lowercased().split(separator: " ").contains { $0 == query.lowercased() } }
    }
}

final class FakeOpener: URLOpener, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var opened: [String] = []
    func open(_ url: String) async throws { lock.withLock { opened.append(url) } }
}

func testApps(_ dir: String, roots: [String] = [], scripts: any ScriptRunner = FakeScripts(), calendar: any CalendarStore = FakeCalendar(),
              contacts: any ContactStore = FakeContacts(), opener: any URLOpener = FakeOpener()) -> AppServices {
    AppServices(scripts: scripts, calendar: calendar, contacts: contacts, opener: opener,
                catalog: AppCatalog(cachePath: dir + "/apps.json", roots: roots))
}

// MARK: a fixture app

let taskySdef = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE dictionary SYSTEM "file://localhost/System/Library/DTDs/sdef.dtd">
<dictionary title="Tasky">
  <xi:include xmlns:xi="http://www.w3.org/2003/XInclude" href="file:///System/Library/ScriptingDefinitions/CocoaStandard.sdef" xpointer="xpointer(/dictionary/suite)"/>
  <suite name="Tasky Suite" code="TASK" description="Tasks">
    <enumeration name="urgency" code="Urgn">
      <enumerator name="low" code="Ulow"/>
      <enumerator name="high" code="Uhig"/>
    </enumeration>
    <command name="send summary" code="TASKsnds" description="Sends a summary by email.">
      <direct-parameter type="text" description="The address"/>
      <parameter name="days" code="Days" type="integer" optional="yes" description="How many days"/>
    </command>
    <command name="get open count" code="TASKgcnt" description="Counts open tasks."><result type="integer"/></command>
    <command name="archive done" code="TASKarch" description="Archives finished tasks."/>
    <command name="do script" code="TASKdosc" description="Runs a script."><direct-parameter type="text"/></command>
    <command name="secret thing" code="TASKsecr" hidden="yes"/>
    <command name="snooze" code="TASKsnoz" description="Snoozes a task.">
      <direct-parameter type="task"/>
      <parameter name="until" code="Untl" type="date"/>
      <parameter name="level" code="Levl" type="urgency" optional="yes"/>
      <parameter name="tags" code="Tags" optional="yes"><type type="text" list="yes"/></parameter>
    </command>
    <class-extension extends="application">
      <element type="project"/>
      <element type="task"/>
      <property name="frontmost" code="pisf" type="boolean" access="r"/>
    </class-extension>
    <class name="item" code="cobj" description="base">
      <property name="id" code="ID  " type="text" access="r"/>
    </class>
    <class name="project" code="Proj" plural="projects" inherits="item" description="A project">
      <property name="name" code="pnam" type="text"/>
      <element type="task"/>
    </class>
    <class name="task" code="Task" plural="tasks" inherits="item" description="A task to do">
      <property name="name" code="pnam" type="text"/>
      <property name="due date" code="Dued" type="date"/>
      <property name="flagged" code="Flag" type="boolean"/>
      <property name="sync password" code="Spwd" type="text"/>
      <property name="created" code="Crtd" type="date" access="r"/>
      <element type="note"/>
    </class>
    <class name="note" code="Note" plural="notes" description="A note on a task">
      <property name="name" code="pnam" type="text"/>
      <property name="text" code="Text" type="text"/>
    </class>
  </suite>
</dictionary>
"""

func makeApp(_ root: String, name: String, bundle: String, sdef: String?) {
    let contents = "\(root)/\(name).app/Contents"
    try! FileManager.default.createDirectory(atPath: contents + "/Resources", withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleIdentifier": bundle, "CFBundleName": name]
    if let sdef {
        info["OSAScriptingDefinition"] = name + ".sdef"
        try! sdef.write(toFile: "\(contents)/Resources/\(name).sdef", atomically: true, encoding: .utf8)
    }
    (info as NSDictionary).write(toFile: contents + "/Info.plist", atomically: true)
}

@Suite struct AppsTests {
    let tmp = tempDir()

    func catalog() -> AppCatalog {
        let root = tmp + "/Applications"
        makeApp(root, name: "Tasky", bundle: "test.tasky", sdef: taskySdef)
        makeApp(root, name: "Terminal", bundle: "com.apple.Terminal", sdef: taskySdef)
        makeApp(root, name: "Plain", bundle: "test.plain", sdef: nil)
        let c = AppCatalog(cachePath: tmp + "/apps.json", roots: [root])
        c.scan()
        return c
    }

    func tasky() -> AppDictionary { catalog().app("Tasky")! }

    func env(_ apps: AppServices) -> ActionEnv { ActionEnv(policy: testPolicy(), admin: RecordingAdminRunner(), apps: apps) }

    // MARK: discovery

    @Test func catalogReadsScriptableAppsOnly() throws {
        let c = catalog()
        #expect(c.apps.map(\.name) == ["Tasky"])  // Terminal is blocked, Plain has no dictionary
        let app = try #require(c.app("tasky"))
        #expect(app.commands.map(\.name) == ["send summary", "get open count", "archive done", "do script", "snooze"])
        #expect(app.topElements == ["project", "task"])
        #expect(app.enumerations["urgency"] == ["low", "high"])
        let snooze = try #require(app.command("snooze"))
        #expect(snooze.direct?.type == "task")
        #expect(snooze.params.map(\.name) == ["until", "level", "tags"])
        #expect(snooze.params[2].type == "text list")
        // Inherited properties and plural lookup.
        let task = try #require(app.cls("tasks"))
        #expect(task.properties.map(\.name).contains("id"))
        #expect(app.containers(of: "note") == ["task"])
        // The cache is read back by a new catalog.
        #expect(AppCatalog(cachePath: tmp + "/apps.json", roots: []).app("test.tasky") == app)
    }

    @Test func rescanKeepsUnchangedAppsAndSyncsGraph() throws {
        let c = catalog()
        #expect(!c.scan())
        let graph = try GraphStore(path: tmp + "/bibi.db")
        c.sync(graph)
        let ids = Set(graph.nodes(kind: "capability").map(\.id))
        #expect(ids.contains("cap:test.tasky:command:snooze"))
        #expect(ids.contains("cap:test.tasky:class:task"))
        #expect(ids.contains("cap:test.tasky:class:note"))
        // An app that is gone takes its capabilities with it.
        try FileManager.default.removeItem(atPath: tmp + "/Applications/Tasky.app")
        #expect(c.scan())
        c.sync(graph)
        #expect(graph.nodes(kind: "capability").isEmpty)
    }

    // MARK: writing scripts

    @Test func commandValuesTravelAsArguments() throws {
        let app = tasky()
        let tricky = "x\" & (do shell script \"rm -rf ~\") & \""
        let s = try AppScripts.build(AppCall(op: "command", term: "send summary", values: ["direct": tricky, "days": "7"]), app)
        #expect(s.args == [tricky, "7"])
        #expect(!s.source.contains("rm -rf"))
        #expect(s.source.contains("tell application id \"test.tasky\""))
        #expect(s.source.contains("set r to (send summary (item 1 of argv) days ((item 2 of argv) as integer))"))
        #expect(s.risk == .outbound)
        #expect(s.steps == ["Tasky: send summary \(tricky); days: 7"])
    }

    @Test func commandTypesAreChecked() throws {
        let app = tasky()
        let ok = try AppScripts.build(AppCall(op: "command", term: "snooze",
                                              values: ["direct": "Taxes", "until": "2026-10-27 15:00", "level": "HIGH"]), app)
        #expect(ok.source.contains("snooze (first task whose name is (item 1 of argv)) level high until (my mkdate((item 2 of argv)))"))
        #expect(ok.args == ["Taxes", "2026-10-27 15:00"])
        #expect(throws: ActionError.self) { try AppScripts.build(AppCall(op: "command", term: "snooze", values: ["direct": "x", "until": "soon"]), app) }
        #expect(throws: ActionError.self) { try AppScripts.build(AppCall(op: "command", term: "snooze", values: ["direct": "x"]), app) }
        #expect(throws: ActionError.self) {
            try AppScripts.build(AppCall(op: "command", term: "snooze", values: ["direct": "x", "until": "2026-10-27", "level": "medium"]), app)
        }
        #expect(throws: ActionError.self) {
            try AppScripts.build(AppCall(op: "command", term: "snooze", values: ["direct": "x", "until": "2026-10-27", "tags": "a"]), app)
        }
        #expect(throws: ActionError.self) { try AppScripts.build(AppCall(op: "command", term: "send summary", values: ["direct": "a", "days": "many"]), app) }
        #expect(throws: ActionError.self) { try AppScripts.build(AppCall(op: "command", term: "send summary", values: ["direct": "a", "bogus": "1"]), app) }
        #expect(throws: ActionError.self) { try AppScripts.build(AppCall(op: "command", term: "fly"), app) }
    }

    @Test func codeRunningCommandsAreRefused() {
        #expect(throws: ActionError.self) { try AppScripts.build(AppCall(op: "command", term: "do script", values: ["direct": "x"]), tasky()) }
        #expect(AppScripts.refusal(ofCommand: "do JavaScript") != nil)
        #expect(AppScripts.refusal(ofCommand: "keystroke") != nil)
        #expect(AppScripts.refusal(ofCommand: "play") == nil)
    }

    @Test func riskComesFromTheCommandName() {
        #expect(AppScripts.risk(ofCommand: "send") == .outbound)
        #expect(AppScripts.risk(ofCommand: "reply") == .outbound)
        #expect(AppScripts.risk(ofCommand: "delete") == .destructive)
        #expect(AppScripts.risk(ofCommand: "empty trash") == .destructive)
        #expect(AppScripts.risk(ofCommand: "get open count") == .readOnly)
        #expect(AppScripts.risk(ofCommand: "show") == .writes)
        #expect(AppScripts.risk(ofCommand: "play") == .writes)
    }

    @Test func makeSetsWritablePropertiesAndCanBeUndone() async throws {
        let app = tasky()
        let s = try AppScripts.build(AppCall(op: "make", term: "task", values: ["name": "Pay rent", "flagged": "yes", "at": "Home"]), app)
        #expect(s.source.contains("make new task at (first project whose name is (item 2 of argv)) with properties {flagged:true, name:(item 1 of argv)}"))
        #expect(s.undoClass == "task")
        #expect(throws: ActionError.self) { try AppScripts.build(AppCall(op: "make", term: "task", values: ["created": "2026-10-27"]), app) }
        #expect(throws: ActionError.self) { try AppScripts.build(AppCall(op: "make", term: "task", values: ["sync password": "x"]), app) }
        #expect(throws: ActionError.self) { try AppScripts.build(AppCall(op: "make", term: "widget"), app) }

        let scripts = FakeScripts(["created Pay rent\nid:T-1", "ok"])
        let apps = testApps(tmp, roots: [tmp + "/Applications"], scripts: scripts)
        apps.catalog.scan()
        let registry = ActionRegistry(Builtins.all)
        let call = RunAppCall.call(app, AppCall(op: "make", term: "task", values: ["name": "Pay rent"]))
        let out = try await registry.execute(call, env(apps))
        #expect(out.message == "created Pay rent")
        let undo = try #require(out.undo)
        #expect(undo == ActionCall("app_delete", ["app": "test.tasky", "class": "task", "id": "T-1"]))
        _ = try await registry.execute(undo, env(apps), allowInternal: true)
        #expect(scripts.calls.last?.args == ["T-1"])
        #expect(scripts.calls.last?.source.contains("delete (first task whose id is (item 1 of argv))") == true)
    }

    @Test func listReadsFieldsAndReachesNestedClasses() throws {
        let app = tasky()
        let s = try AppScripts.build(AppCall(op: "list", term: "tasks", values: ["fields": "name, due date", "where": "rent", "limit": "500"]), app)
        #expect(s.risk == .readOnly)
        #expect(s.source.contains("set xs to every task whose name contains (item 1 of argv)"))
        #expect(s.source.contains("if i > 50 then exit repeat"))
        #expect(s.source.contains("my totext(due date of x)"))
        let nested = try AppScripts.build(AppCall(op: "list", term: "note"), app)
        #expect(nested.source.contains("set xs to my flatten((every note) of every task)"))
        #expect(throws: ActionError.self) { try AppScripts.build(AppCall(op: "list", term: "task", values: ["fields": "sync password"]), app) }
    }

    @Test func parseAcceptsTheShapesSmallModelsWrite() throws {
        #expect(try AppScripts.parse(["make=task", "name=x"]) == AppCall(op: "make", term: "task", values: ["name": "x"]))
        #expect(try AppScripts.parse(["op=list", "class=task"]) == AppCall(op: "list", term: "task"))
        #expect(try AppScripts.parse(["command=snooze", "Due Date=a=b"]) == AppCall(op: "command", term: "snooze", values: ["due date": "a=b"]))
        #expect(throws: ActionError.self) { try AppScripts.parse(["name=x"]) }
    }

    @Test func plannerBindsAppStepsWithRiskAndExactDates() throws {
        let apps = testApps(tmp, roots: [tmp + "/Applications"])
        _ = catalog()
        apps.catalog.scan()
        let planner = Planner(registry: ActionRegistry(Builtins.all), env: env(apps), skill: { _ in nil })
        let send = try planner.bind(PlannedStep(tool: "app:Tasky", args: ["command=send summary", "direct=me@example.com"])).get()
        #expect(send[0].kind == "outbound")
        #expect(send[0].safety == 3)
        let make = try planner.bind(PlannedStep(tool: "app:Tasky", args: ["make=task", "name=Taxes", "due date=tomorrow 3pm"])).get()
        let call = try JSON.decode(AppCall.self, from: make[0].call.params["call"]!)
        #expect(Re.test(#"^\d{4}-\d{2}-\d{2} 15:00$"#, call.values["due date"]!))
        #expect(make[0].reversible)
        #expect(PlannedStep.from(make[0]).tool == "app:Tasky")
        if case .success = planner.bind(PlannedStep(tool: "app:Nope", args: ["list=x"])) { Issue.record("unknown app bound") }
        // The registry entry can't be called directly: only through app:, where bibi builds and classifies the script.
        if case .success = planner.bind(PlannedStep(tool: "action:run_app_call", args: ["app=test.tasky"])) { Issue.record("run_app_call bound") }
    }

    @Test func storedCallsAreRebuiltBeforeRunning() throws {
        let apps = testApps(tmp, roots: [tmp + "/Applications"])
        _ = catalog()
        apps.catalog.scan()
        let registry = ActionRegistry(Builtins.all)
        let bad = ActionCall("run_app_call", ["app": "test.tasky", "call": JSON.string(AppCall(op: "command", term: "do script", values: ["direct": "x"]))])
        #expect(registry.preview(bad, env(apps)).error != nil)
    }

    @Test func rawAppleScriptThatDrivesAppsIsRefused() {
        let v = CommandPolicy.classify(["osascript", "-e", "tell application \"Mail\" to send"], policy: testPolicy())
        #expect(v.refusal != nil)
        #expect(CommandPolicy.classify(["osascript", "-e", "display notification \"hi\""], policy: testPolicy()).refusal == nil)
        #expect(CommandPolicy.classify(["mail", "-s", "Reminder", "a@b.com"], policy: testPolicy()).refusal?.contains("mail_send") == true)
    }

    // MARK: dates

    @Test func datesBecomeExactWhenProposed() throws {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 26; c.hour = 9
        let now = Calendar.current.date(from: c)!
        #expect(DateText.normalize("tomorrow", now: now) == "2026-10-27")
        #expect(DateText.normalize("2026-10-30 09:30", now: now) == "2026-10-30 09:30")
        #expect(DateText.normalize("tomorrow at 3pm", now: now) == "2026-10-27 15:00")
        #expect(DateText.normalize("not a date", now: now) == nil)
        #expect(DateText.strict("tomorrow") == nil)
        #expect(DateText.strict("2026-10-27")?.hasTime == false)
    }

    // MARK: built-in actions

    @Test func mailSendShowsEverythingAndPassesArguments() async throws {
        let scripts = FakeScripts(["sent"])
        let apps = testApps(tmp, scripts: scripts)
        let registry = ActionRegistry(Builtins.all)
        let p: Params = ["to": "Marie Dupont <marie@example.com>, bob@example.com", "subject": "Repo", "body": "Look at\nthe repo",
                         "from": "me@example.com"]
        let preview = registry.preview(ActionCall("mail_send", p), env(apps))
        #expect(preview.error == nil)
        #expect(preview.steps.contains("to: Marie Dupont <marie@example.com>, bob@example.com"))
        #expect(preview.steps.contains("body: Look at\nthe repo"))
        #expect(preview.steps.first == "send an email from me@example.com")
        _ = try await registry.execute(ActionCall("mail_send", p), env(apps))
        #expect(scripts.calls[0].args == ["marie@example.com\nbob@example.com", "", "", "Repo", "Look at\nthe repo", "me@example.com"])
        #expect(registry.preview(ActionCall("mail_send", ["to": "Marie", "body": "x"]), env(apps)).error != nil)
        #expect(registry.preview(ActionCall("mail_send", ["to": "a@b.co"]), env(apps)).error != nil)
    }

    @Test func recipientsResolveToExactlyOneAddress() async {
        let contacts = FakeContacts(people: [
            ContactCard(name: "Marie Dupont", emails: ["marie@example.com"], phones: [.init("home", "+1 514 555 0100"), .init("mobile", "+1 514 555 0199")]),
            ContactCard(name: "Paul Roy", emails: ["paul@a.com", "paul@b.com"]),
            ContactCard(name: "Paul Tremblay", emails: ["pt@example.com"]),
        ])
        let steps = [
            PlannedStep(tool: "action:mail_send", args: ["to=Marie, x@y.com", "subject=Hi"]),
            PlannedStep(tool: "action:facetime_call", args: ["Marie"]),
            PlannedStep(tool: "action:mail_send", args: ["to=Paul", "subject=Hi"]),
            PlannedStep(tool: "action:message_send", args: ["to=Paul Roy", "text=hi"]),
            PlannedStep(tool: "action:mail_send", args: ["to=Zed", "subject=Hi"]),
            PlannedStep(tool: "command", args: ["echo", "Marie"]),
        ]
        let r = await Recipes.resolveRecipients(steps, contacts: contacts)
        #expect(r.steps.map(\.args) == [["to=Marie Dupont <marie@example.com>, x@y.com", "subject=Hi"],
                                        ["to=Marie Dupont <+1 514 555 0199>"], ["echo", "Marie"]])
        #expect(r.refusals.count == 3)
        #expect(r.refusals[0].contains("matches 2 contacts"))
        #expect(r.refusals[1].contains("has several addresses"))
        #expect(r.refusals[2].contains("isn't in Contacts"))
    }

    @Test func calendarAddIsUndoableAndListIsSorted() async throws {
        let cal = FakeCalendar()
        let apps = testApps(tmp, calendar: cal)
        let registry = ActionRegistry(Builtins.all)
        let planner = Planner(registry: registry, env: env(apps), skill: { _ in nil })
        let a = try planner.bind(PlannedStep(tool: "action:calendar_add", args: ["title=Dentist", "start=2026-10-30 09:30", "location=Main St"])).get()[0]
        #expect(a.command.contains("add \"Dentist\" to your default calendar: Fri Oct 30 09:30–10:30 @ Main St"))
        #expect(a.reversible)
        let out = try await registry.execute(a.call, env(apps))
        #expect(cal.events.count == 1)
        _ = try await registry.execute(try #require(out.undo), env(apps), allowInternal: true)
        #expect(cal.removed == ["ev1"])

        let day = DateText.strict("2026-10-27")!.date
        cal.events = [CalendarItem(id: "b", title: "Standup", start: day.addingTimeInterval(10 * 3600), end: day.addingTimeInterval(10.25 * 3600), calendar: "Work"),
                      CalendarItem(id: "a", title: "Holiday", start: day, end: day, allDay: true, calendar: "Home")]
        let list = try await registry.execute(ActionCall("calendar_list", ["from": "2026-10-27"]), env(apps))
        #expect(list.output == "Tue Oct 27 all day  Holiday (Home)\nTue Oct 27 10:00–10:15  Standup (Work)")
        #expect(cal.queried?.1 == day.addingTimeInterval(86400))
        // A day without a time is an all-day event.
        let allDay = try planner.bind(PlannedStep(tool: "action:calendar_add", args: ["Holiday", "start=2026-12-25"])).get()
        #expect(allDay[0].call.params["title"] == "Holiday")
        #expect(allDay[0].command.contains("all day"))
    }

    @Test func remindersAddCompleteAndUndo() async throws {
        let cal = FakeCalendar()
        cal.reminderItems = [CalendarItem(id: "r9", title: "Buy milk", calendar: "Groceries", completed: false)]
        let apps = testApps(tmp, calendar: cal)
        let registry = ActionRegistry(Builtins.all)
        let done = try await registry.execute(ActionCall("reminder_complete", ["title": "buy MILK"]), env(apps))
        #expect(cal.reminderItems[0].completed == true)
        _ = try await registry.execute(try #require(done.undo), env(apps), allowInternal: true)
        #expect(cal.reminderItems[0].completed == false)
        await #expect(throws: ActionError.self) { try await registry.execute(ActionCall("reminder_complete", ["title": "Walk"]), env(apps)) }
        let added = try await registry.execute(ActionCall("reminder_add", ["title": "Call mom", "due": "2026-10-27 18:00"]), env(apps))
        #expect(added.undo?.spec == "reminder_remove")
        let list = try await registry.execute(ActionCall("reminders_list", [:]), env(apps))
        #expect(list.output == "- Call mom (due Tue Oct 27 18:00) [Reminders]\n- Buy milk [Groceries]")
    }

    @Test func callsUseTheRightScheme() async throws {
        let opener = FakeOpener()
        let apps = testApps(tmp, opener: opener)
        let registry = ActionRegistry(Builtins.all)
        _ = try await registry.execute(ActionCall("facetime_call", ["to": "Marie Dupont <+1 (514) 555-0199>"]), env(apps))
        _ = try await registry.execute(ActionCall("facetime_call", ["to": "marie@example.com", "via": "video"]), env(apps))
        _ = try await registry.execute(ActionCall("facetime_call", ["to": "+15145550199", "via": "phone"]), env(apps))
        #expect(opener.opened == ["facetime-audio://+15145550199", "facetime://marie@example.com", "tel:+15145550199"])
        #expect(registry.preview(ActionCall("facetime_call", ["to": "marie@example.com", "via": "phone"]), env(apps)).error != nil)
        #expect(registry.preview(ActionCall("facetime_call", ["to": "Marie"]), env(apps)).error != nil)
    }

    @Test func messagesSendThroughIMessage() async throws {
        let scripts = FakeScripts(["sent"])
        let apps = testApps(tmp, scripts: scripts)
        let registry = ActionRegistry(Builtins.all)
        let p = registry.preview(ActionCall("message_send", ["to": "+15145550199", "text": "On my way"]), env(apps))
        #expect(p.steps.contains("text: On my way"))
        _ = try await registry.execute(ActionCall("message_send", ["to": "+15145550199", "text": "On my way"]), env(apps))
        #expect(scripts.calls[0].args == ["+15145550199", "On my way"])
    }

    // MARK: real dictionaries

    /// Compiles without running (osacompile sends no events, so no app starts and macOS asks nothing).
    func compile(_ source: String) async -> String? {
        let file = tmp + "/s-\(UUID().uuidString).applescript"
        try? source.write(toFile: file, atomically: true, encoding: .utf8)
        let out = await Command.run(["osacompile", "-o", file + ".scpt", file])
        return out.ok ? nil : out.stderr
    }

    @Test func generatedScriptsCompileAgainstInstalledApps() async throws {
        for (name, script) in [("mail_send", MailSend.script), ("mail_accounts", MailAccounts.script), ("message_send", MessageSend.script)] {
            if let e = await compile(script) { Issue.record("\(name): \(e)") }
        }
        let catalog = AppCatalog(cachePath: tmp + "/real.json", roots: ["/System/Applications"])
        catalog.scan()
        var compiled = 0
        for app in catalog.apps {
            var calls = app.commands.map { AppCall(op: "command", term: $0.name) }
            for name in Set(app.topElements + app.topElements.flatMap { app.cls($0)?.elements ?? [] }) {
                guard let c = app.cls(name) else { continue }
                calls.append(AppCall(op: "list", term: c.name, values: c.properties.contains { $0.name == "name" } ? ["where": "x"] : [:]))
                if let p = c.properties.first(where: { $0.writable && ["text", ""].contains($0.type) && !$0.name.contains("password") }) {
                    calls.append(AppCall(op: "make", term: c.name, values: [p.name: "x"]))
                }
            }
            for call in calls {
                // Commands that need values bibi can't invent here are skipped; what builds must compile.
                guard let s = try? AppScripts.build(call, app) else { continue }
                if let e = await compile(s.source) { Issue.record("\(app.name) \(call.op) \(call.term): \(e)") }
                compiled += 1
            }
        }
        #expect(compiled > 20)
    }

    // MARK: chat

    @Test func chatOffersBuiltInsAndDiscoveredApps() throws {
        let graph = try GraphStore(path: tmp + "/bibi.db")
        _ = catalog()
        let apps = testApps(tmp, roots: [tmp + "/Applications"])
        let harness = Harness(skills: [], store: RunStore(root: tmp + "/runs"), policy: testPolicy(), graph: graph, apps: apps) { FakeModel() }
        let chat = ChatEngine(harness: harness, graph: graph, embedder: NoEmbedder())
        apps.catalog.refresh(graph: graph)

        let mail = chat.toolCatalog([], request: "email Marie about the repo", examples: [])
        #expect(mail.ids.contains("action:mail_send"))
        #expect(!mail.ids.contains("action:calendar_add"))

        let tasks = chat.toolCatalog([], request: "flag my tasks about taxes", examples: [])
        #expect(tasks.ids.contains("app:Tasky"))
        #expect(tasks.text.contains("- app:Tasky [\"list=task\""))
        #expect(tasks.text.contains("Settable: name, due date, flagged"))
        #expect(!tasks.text.contains("sync password"))
    }
}
