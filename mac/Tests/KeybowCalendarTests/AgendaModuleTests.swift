@testable import KeybowCalendar
import KeybowKit
import XCTest

/// A calendar made up for the tests.
private actor FakeCalendar: CalendarSource {
    var events: [CalendarEvent]
    var reminders: [CalendarReminder]
    private(set) var completed: [String] = []
    private(set) var appended: [(id: String, start: Date, text: String)] = []

    init(events: [CalendarEvent] = [], reminders: [CalendarReminder] = []) {
        self.events = events
        self.reminders = reminders
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        events.filter { $0.start < end && $0.end > start }
    }

    func incompleteReminders() async throws -> [CalendarReminder] {
        reminders.filter { !completed.contains($0.id) }
    }

    func completeReminder(id: String) async throws {
        completed.append(id)
    }

    func appendToNotes(ofEvent id: String, startingAt start: Date, text: String) async throws {
        appended.append((id, start, text))
    }
}

private final class Opened: @unchecked Sendable {
    var urls: [URL] = []
}

final class AgendaModuleTests: XCTestCase {
    /// 7 Oct 2026, 10:00 here.
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 10))!

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7 + day, hour: hour, minute: minute))!
    }

    private func event(_ title: String, _ start: Date, _ end: Date, _ change: (inout CalendarEvent) -> Void = { _ in })
        -> CalendarEvent {
        var event = CalendarEvent(id: title, title: title, start: start, end: end)
        change(&event)
        return event
    }

    // MARK: Which meeting

    func testTheMeetingUnderWayElseTheNextToday() {
        let standup = event("Standup", at(9, 45), at(10, 15))
        let review = event("Review", at(14), at(15))
        let early = event("Early", at(9, 30), at(11))
        XCTAssertEqual(Meetings.current([review, standup], now: now)?.title, "Standup")
        XCTAssertEqual(Meetings.current([standup, early], now: now)?.title, "Standup", "the one started last")
        XCTAssertEqual(Meetings.current([review], now: now)?.title, "Review")
        XCTAssertNil(Meetings.current([event("Tomorrow", at(9, day: 1), at(10, day: 1))], now: now), "today only")
        XCTAssertEqual(Meetings.next([standup, review], now: now)?.title, "Review", "whatever's under way")
        XCTAssertEqual(Meetings.next([event("Tomorrow", at(9, day: 1), at(10, day: 1))], now: now)?.title, "Tomorrow")
    }

    func testInAMeetingsLastMinutesTheNextIsMeant() {
        let ending = event("Ending", at(9), at(10, 4))
        let soon = event("Soon", at(10, 8), at(11))
        XCTAssertEqual(Meetings.current([ending, soon], now: now)?.title, "Soon")
        let later = event("Later", at(10, 30), at(11))
        XCTAssertEqual(Meetings.current([ending, later], now: now)?.title, "Ending", "the next is too far off")
    }

    func testNotEverythingOnTheCalendarIsAMeeting() {
        let allDay = event("Offsite", at(0), at(0, day: 1)) { $0.isAllDay = true }
        let declined = event("Declined", at(9, 30), at(10, 30)) { $0.declined = true }
        let off = event("Called off", at(9, 30), at(10, 30)) { $0.canceled = true }
        XCTAssertNil(Meetings.current([allDay, declined, off], now: now))
    }

    // MARK: Links

    func testTheLinkToJoinIsFound() {
        let zoom = event("A", now, now) { $0.notes = "Join: https://us02web.zoom.us/j/123456789?pwd=abc\nHelp: https://support.zoom.us/hc" }
        XCTAssertEqual(Meetings.joinLink(zoom)?.absoluteString, "https://us02web.zoom.us/j/123456789?pwd=abc")
        let meet = event("B", now, now) { $0.location = "meet.google.com/abc-defg-hij" ; $0.notes = "https://example.com/agenda" }
        XCTAssertEqual(Meetings.joinLink(meet).flatMap(Meetings.service), "Google Meet")
        let teams = event("C", now, now) {
            $0.url = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0")
        }
        XCTAssertEqual(Meetings.joinLink(teams).flatMap(Meetings.service), "Teams")
        let plain = event("D", now, now) { $0.url = URL(string: "https://example.com/room") }
        XCTAssertEqual(Meetings.joinLink(plain)?.absoluteString, "https://example.com/room", "its URL, as a last resort")
        XCTAssertNil(Meetings.joinLink(event("E", now, now) { $0.notes = "Help: https://support.zoom.us/hc" }))
    }

    // MARK: The day

    func testTheRestOfTheDayLaidOut() {
        let events = [
            event("Done already", at(8), at(9)),
            event("Standup", at(9, 45), at(10, 15)),
            event("Review", at(14), at(15)),
            event("Offsite", at(0), at(0, day: 1)) { $0.isAllDay = true },
            event("Skipped", at(16), at(17)) { $0.declined = true },
        ]
        let reminders = [
            CalendarReminder(title: "Call the bank", due: at(17)),
            CalendarReminder(title: "Pay invoice", due: at(9, day: -2)),
            CalendarReminder(title: "Buy milk", due: at(0), dueHasTime: false),
            CalendarReminder(title: "Someday", due: nil),
            CalendarReminder(title: "Dentist", due: at(9, day: 1)),
        ]
        XCTAssertEqual(Meetings.agenda(events: events, reminders: reminders, day: now, from: now, overdue: true), """
            - All day: Offsite
            - 09:45–10:15 Standup (now)
            - 14:00–15:00 Review

            **Reminders**
            - Pay invoice, overdue since 5 Oct
            - Buy milk
            - Call the bank, 17:00
            """)
        XCTAssertEqual(Meetings.agenda(events: events, reminders: reminders, day: at(9, day: 1), from: nil, overdue: false), """
            **Reminders**
            - Dentist, 09:00
            """, "tomorrow: nothing overdue")
        XCTAssertEqual(Meetings.agenda(events: [], reminders: [], day: now, from: now, overdue: true), "")
    }

    // MARK: Values

    private func module(_ calendar: FakeCalendar, host: MemoryModuleHost = MemoryModuleHost(),
                        opened: Opened = Opened()) -> AgendaModule {
        let module = AgendaModule(source: calendar) { url in opened.urls.append(url) }
        module.start(host: host)
        return module
    }

    func testValuesForTheMeetingTheNextAndTheReminder() async throws {
        let calendar = FakeCalendar(
            events: [
                event("Standup", at(9, 45), at(10, 15)) {
                    $0.location = "Room 4"
                    $0.attendees = ["Alex Example", "Sam Sample"]
                    $0.organizer = "Alex Example"
                    $0.notes = "https://meet.google.com/abc-defg-hij"
                },
                event("Review", at(14), at(15)),
            ],
            reminders: [CalendarReminder(title: "Call the bank", list: "Errands", due: at(17))])
        let values = try await module(calendar).fetch(
            ["event", "event.time", "event.location", "event.attendees", "event.link", "event.date", "event.next",
             "event.next.start", "reminder", "reminder.list", "reminder.due"], params: [:], now: now)
        XCTAssertEqual(values["event"], "Standup")
        XCTAssertEqual(values["event.time"], "09:45–10:15")
        XCTAssertEqual(values["event.location"], "Room 4")
        XCTAssertEqual(values["event.attendees"], "Alex Example, Sam Sample")
        XCTAssertEqual(values["event.link"], "https://meet.google.com/abc-defg-hij")
        XCTAssertTrue(values["event.date"]?.contains("2026") == true)
        XCTAssertEqual(values["event.next"], "Review")
        XCTAssertEqual(values["event.next.start"], "14:00")
        XCTAssertEqual(values["reminder"], "Call the bank")
        XCTAssertEqual(values["reminder.list"], "Errands")
        XCTAssertTrue(values["reminder.due"]?.hasSuffix("17:00") == true)
    }

    func testWhatIsntThereIsEmptyForItsFallback() async throws {
        let values = try await module(FakeCalendar()).fetch(["event", "agenda", "reminder"], params: [:], now: now)
        XCTAssertEqual(values, ["event": "", "agenda": "", "reminder": ""])
    }

    func testOnlyTheCalendarsChosenAreRead() async throws {
        let host = MemoryModuleHost()
        host.set("work", for: "calendars", of: AgendaModule.id)
        let calendar = FakeCalendar(events: [
            event("Birthday party", at(9, 45), at(11)) { $0.calendar = "Family" },
            event("Review", at(14), at(15)) { $0.calendar = "Work" },
        ])
        let values = try await module(calendar, host: host).fetch(["event"], params: [:], now: now)
        XCTAssertEqual(values["event"], "Review")
    }

    func testAnUnknownValueIsSaid() async {
        do {
            _ = try await module(FakeCalendar()).fetch(["event.colour"], params: [:], now: now)
            XCTFail()
        } catch let error as ModuleError {
            XCTAssertEqual(error.message, "There's no {{event.colour}}")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testWithoutEventKitItSaysWhy() async {
        let module = AgendaModule(source: nil)
        guard !EventKitService.isAvailable else { return }
        do {
            _ = try await module.fetch(["event"], params: [:], now: now)
            XCTFail()
        } catch let error as ModuleError {
            XCTAssertEqual(error.message, "Your calendar is read by KeybowNotes.app")
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Actions

    private func request(_ type: String, _ fields: [String: String] = [:], leaf: String = "Key") -> ModuleRequest {
        ModuleRequest(type: type, fields: fields, labels: ["Meetings", leaf], time: now)
    }

    func testJoiningOpensTheMeetingsLink() async {
        let opened = Opened()
        let calendar = FakeCalendar(events: [
            event("Standup", at(9, 45), at(10, 15)) { $0.notes = "https://zoom.us/j/42" },
            event("Review", at(14), at(15)) { $0.location = "https://meet.google.com/abc-defg-hij" },
        ])
        let module = module(calendar, opened: opened)
        var outcome = await module.run(request("calendar.join"), now: now)
        XCTAssertEqual(outcome, .success("Joining “Standup” on Zoom", "now, until 10:15"))
        outcome = await module.run(request("calendar.join", ["which": "next"]), now: now)
        XCTAssertEqual(outcome, .success("Joining “Review” on Google Meet", "at 14:00"))
        XCTAssertEqual(opened.urls.map(\.absoluteString), ["https://zoom.us/j/42", "https://meet.google.com/abc-defg-hij"])

        let quiet = await self.module(FakeCalendar(events: [event("Lunch", at(9, 45), at(11))])).run(request("calendar.join"), now: now)
        XCTAssertEqual(quiet.message, "“Lunch” has no link to join")
        let nothing = await self.module(FakeCalendar()).run(request("calendar.join"), now: now)
        XCTAssertEqual(nothing.message, "There's no meeting now")
    }

    func testANoteGoesOnTheMeeting() async {
        let calendar = FakeCalendar(events: [event("Standup", at(9, 45), at(10, 15))])
        let outcome = await module(calendar).run(request("calendar.addNote", ["text": "Decided: ship it"]), now: now)
        XCTAssertEqual(outcome.message, "Added to “Standup”")
        let appended = await calendar.appended
        XCTAssertEqual(appended.map(\.text), ["Decided: ship it"])
        XCTAssertEqual(appended.first?.start, at(9, 45), "the occurrence meant")

        let readOnly = FakeCalendar(events: [event("Holiday", at(9), at(11)) { $0.canEdit = false; $0.calendar = "Holidays" }])
        let refused = await module(readOnly).run(request("calendar.addNote", ["text": "x"]), now: now)
        XCTAssertEqual(refused, .failure("“Holiday” can't be changed", "Its calendar, Holidays, is read-only."))
    }

    func testAReminderIsTickedOff() async {
        let calendar = FakeCalendar(reminders: [
            CalendarReminder(id: "a", title: "Call the bank about the card", list: "Errands", due: at(17)),
            CalendarReminder(id: "b", title: "Call the bank", list: "Errands", due: nil),
            CalendarReminder(id: "c", title: "Pay invoice", list: "Work", due: at(9, day: -1)),
        ])
        let module = module(calendar)
        var outcome = await module.run(request("reminders.complete", ["title": "call the bank"]), now: now)
        XCTAssertEqual(outcome, .success("Done: Call the bank", "in Errands"), "the exact title first")
        outcome = await module.run(request("reminders.complete"), now: now)
        XCTAssertEqual(outcome, .success("Done: Pay invoice", "in Work"), "overdue is next")
        outcome = await module.run(request("reminders.complete", ["list": "errands"]), now: now)
        XCTAssertEqual(outcome, .success("Done: Call the bank about the card", "in Errands"))
        outcome = await module.run(request("reminders.complete"), now: now)
        XCTAssertEqual(outcome.message, "Nothing's due")
        let completed = await calendar.completed
        XCTAssertEqual(completed, ["b", "c", "a"])
    }

    func testWhatAKeyWillDoIsSaid() {
        let module = AgendaModule(source: FakeCalendar())
        XCTAssertEqual(module.summary(of: request("calendar.join", ["which": "next"]), now: now),
                       ModuleSummary(verb: "Join", subject: "the next meeting"))
        XCTAssertEqual(module.summary(of: request("reminders.complete", ["list": "Errands"]), now: now),
                       ModuleSummary(verb: "Complete", subject: "the reminder due next", details: ["in Errands"]))
        XCTAssertEqual(module.problem(with: request("calendar.join", ["which": "later"])),
                       "“later” isn't a meeting to choose: now or next.")
    }
}
