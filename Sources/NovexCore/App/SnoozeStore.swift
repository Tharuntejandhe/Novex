import Foundation

/// One snoozed item: an email hidden from Novex until `wake`.
struct SnoozedItem: Codable, Equatable, Sendable {
    let messageID: String
    let title: String
    let wake: Date
}

/// Snooze presets the user picks from.
enum SnoozePreset: String, CaseIterable, Sendable {
    case laterToday, tomorrow, thisWeekend, nextWeek

    var label: String {
        switch self {
        case .laterToday:  return "Later today"
        case .tomorrow:    return "Tomorrow"
        case .thisWeekend: return "This weekend"
        case .nextWeek:    return "Next week"
        }
    }

    var icon: String {
        switch self {
        case .laterToday:  return "sun.max"
        case .tomorrow:    return "sunrise"
        case .thisWeekend: return "beach.umbrella"
        case .nextWeek:    return "calendar"
        }
    }

    /// Concrete wake time for this preset. "Later today" = +3h; the rest land at
    /// 9am on the next matching day. Pure (takes `now` + calendar) so it's testable.
    func wakeDate(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .laterToday:
            return now.addingTimeInterval(3 * 3600)
        case .tomorrow:
            return Self.nextDay(at: 9, daysAhead: 1, from: now, calendar: calendar)
        case .thisWeekend:
            return Self.next(weekday: 7, at: 9, from: now, calendar: calendar) // Saturday
        case .nextWeek:
            return Self.next(weekday: 2, at: 9, from: now, calendar: calendar) // Monday
        }
    }

    private static func nextDay(at hour: Int, daysAhead: Int, from now: Date, calendar: Calendar) -> Date {
        let base = calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }

    /// Next occurrence of `weekday` (1=Sun…7=Sat) at `hour`, strictly in the
    /// future (at least ~1h out, so "this weekend" tapped Saturday morning still
    /// lands next Saturday rather than in the past).
    private static func next(weekday: Int, at hour: Int, from now: Date, calendar: Calendar) -> Date {
        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = hour
        comps.minute = 0
        let candidate = calendar.nextDate(after: now.addingTimeInterval(3600),
                                          matching: comps,
                                          matchingPolicy: .nextTime)
        return candidate ?? now.addingTimeInterval(2 * 86_400)
    }
}

/// Local store of snoozed emails (UserDefaults JSON). "Snooze" hides an item
/// from Novex's views until its wake time, then resurfaces it. Fully on-device.
enum SnoozeStore {
    private static let key = "snoozedItems"

    static func all() -> [SnoozedItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([SnoozedItem].self, from: data) else { return [] }
        return items
    }

    private static func save(_ items: [SnoozedItem]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }

    /// The set of message-ids currently asleep (wake still in the future).
    static func asleepIDs(now: Date = Date()) -> Set<String> {
        Set(all().filter { $0.wake > now }.map(\.messageID))
    }

    static func isAsleep(_ messageID: String?, now: Date = Date()) -> Bool {
        guard let id = messageID else { return false }
        return asleepIDs(now: now).contains(id)
    }

    static func snooze(messageID: String, title: String, until wake: Date) {
        var items = all().filter { $0.messageID != messageID }
        items.append(SnoozedItem(messageID: messageID, title: title, wake: wake))
        save(items)
    }

    static func unsnooze(_ messageID: String) {
        save(all().filter { $0.messageID != messageID })
    }

    /// Items still asleep, soonest wake first.
    static func upcoming(now: Date = Date()) -> [SnoozedItem] {
        all().filter { $0.wake > now }.sorted { $0.wake < $1.wake }
    }

    /// Pull (and remove) every item whose wake time has passed — they've woken,
    /// so they leave the store and reappear in Novex. Returns them so the caller
    /// can fire a "back" notification.
    static func popWoken(now: Date = Date()) -> [SnoozedItem] {
        let items = all()
        let woken = items.filter { $0.wake <= now }
        if !woken.isEmpty { save(items.filter { $0.wake > now }) }
        return woken
    }
}
