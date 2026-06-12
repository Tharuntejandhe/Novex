import Foundation
import EventKit

/// Reads the user's Calendar locally (EventKit) so the brief can show what's
/// next and cross-reference meetings with mail — the kind of context only a
/// local, on-device assistant can do privately. Read-only; nothing leaves the
/// Mac. Needs `NSCalendarsFullAccessUsageDescription` in Info.plist.
@MainActor
@Observable
public final class CalendarService {
    public static let shared = CalendarService()

    private let store = EKEventStore()
    public private(set) var upcoming: [CalEvent] = []

    private init() {}

    private var started = false

    /// Request access (one-time prompt) then load the next ~36h of events.
    /// Idempotent: subsequent calls just refresh.
    public func start() async {
        if !started {
            started = true
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await store.requestFullAccessToEvents()
            }
        }
        await refresh()
    }

    public func refresh() async {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            upcoming = []
            return
        }
        let now = Date()
        let end = now.addingTimeInterval(36 * 3600)
        let pred = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(5)
        upcoming = events.map { ev in
            CalEvent(
                id: ev.eventIdentifier ?? UUID().uuidString,
                title: ev.title ?? "(untitled)",
                start: ev.startDate,
                end: ev.endDate,
                location: ev.location,
                attendeeEmails: (ev.attendees ?? []).compactMap { Self.email(from: $0) },
                organizerEmail: ev.organizer.flatMap { Self.email(from: $0) }
            )
        }
    }

    /// Pull an email address out of an EKParticipant (its `url` is `mailto:…`).
    private static func email(from p: EKParticipant) -> String? {
        let s = p.url.absoluteString
        guard s.lowercased().hasPrefix("mailto:") else { return nil }
        return String(s.dropFirst("mailto:".count)).lowercased()
    }
}

public struct CalEvent: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let location: String?
    public let attendeeEmails: [String]
    public let organizerEmail: String?

    /// All participant emails (organizer + attendees), for matching against mail.
    public var participantEmails: [String] {
        ([organizerEmail].compactMap { $0 } + attendeeEmails)
    }
}

/// A calendar event paired with the most recent related email (from one of its
/// participants) — the cross-app magic. `relatedSender` is nil when no recent
/// mail from a participant was found (we just show the event).
public struct UpNext: Identifiable, Equatable, Sendable {
    public var id: String { event.id }
    public let event: CalEvent
    public let relatedSenderName: String?
    public let relatedWhen: Date?
    public let relatedMessageID: String?
}
