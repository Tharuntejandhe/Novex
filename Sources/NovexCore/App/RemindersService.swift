import Foundation
import EventKit
import Observation

/// One open to-do from Apple Reminders.
public struct Todo: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let due: Date?
    public let list: String

    public func isOverdue(_ now: Date = Date()) -> Bool {
        guard let due else { return false }
        return due < now
    }
}

/// Reads Apple Reminders locally (EventKit) so the brief can show what's actually
/// on your plate alongside mail — the personal-agent move. Read-only, on-device.
/// Needs `NSRemindersFullAccessUsageDescription` in Info.plist.
@MainActor
@Observable
public final class RemindersService {
    public static let shared = RemindersService()

    private let store = EKEventStore()
    public private(set) var todos: [Todo] = []
    private var started = false
    private init() {}

    public func start() async {
        if !started {
            started = true
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                _ = try? await store.requestFullAccessToReminders()
            }
        }
        await refresh()
    }

    public func refresh() async {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            todos = []
            return
        }
        let pred = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { cont.resume(returning: $0 ?? []) }
        }
        let cal = Calendar.current
        let raw: [Todo] = reminders.compactMap { r in
            guard !r.isCompleted, let title = r.title, !title.isEmpty else { return nil }
            let due = r.dueDateComponents.flatMap { cal.date(from: $0) }
            return Todo(id: r.calendarItemIdentifier, title: title, due: due, list: r.calendar?.title ?? "")
        }
        todos = Self.prioritize(raw, now: Date())
    }

    /// Overdue first, then soonest-due, then undated — capped. Pure + testable.
    public nonisolated static func prioritize(_ todos: [Todo], now: Date, limit: Int = 6) -> [Todo] {
        func rank(_ t: Todo) -> (Int, Date) {
            if let due = t.due {
                return (due < now ? 0 : 1, due)        // 0 = overdue, 1 = upcoming
            }
            return (2, .distantFuture)                  // 2 = undated, last
        }
        return todos.sorted {
            let a = rank($0), b = rank($1)
            return a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
        }
        .prefix(limit)
        .map { $0 }
    }
}
