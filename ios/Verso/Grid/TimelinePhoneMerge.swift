// The phone's new photos among Immich's in the Library's timeline (ROADMAP.md, M10, "Backing the iPhone up"), worked
// out from the months alone, with no views and no model, so the logic tests (ios/VersoTests) run it as it is. The
// grid's model stays Immich's (AssetGridModel, shared with the Mac); the photos on their way are a layer of iOS's own
// over it, placed here and laid out by TimelineLayout.
//
// Each photo on its way goes into the month it was taken in, as Immich files it, among that month's photos by when
// each was taken, so that when its upload lands, Immich's photo takes the same place. A month whose photos are not
// read yet (or a timeline ordered by date added, whose order the photos' dates do not give) has them at its newest
// end; a month Immich has none of yet gets a month of their own, in its place among the others. Months without any
// keep no list of their tiles, so a large library lays out in the time its months take.

import Foundation

enum TimelinePhoneMerge {
    /// One of the model's months, newest first, as the merge reads it.
    struct ModelMonth: Equatable {
        /// Its index in the model's sections.
        let section: Int
        /// The model's ID for it, a timeline bucket ("2026-11-01T00:00:00.000Z"), whose first seven characters are its
        /// month.
        let id: String
        let count: Int
        /// When each of its photos was taken, in the model's order (newest first); nil while the month is not read.
        let dates: [Date?]?
    }

    /// A photo on its way, as the merge places it.
    struct Phone: Equatable {
        /// Its index in the list of photos on their way the grid was given.
        let index: Int
        /// When it was taken (or added, in a timeline ordered by date added).
        let date: Date
        /// Its month, "2026-11", as Immich files it: in the time zone it was taken in.
        let month: String
    }

    /// A tile of a merged month: the model's photo at an index of its month, or a photo on its way.
    enum Slot: Equatable {
        case model(Int)
        case phone(Int)
    }

    /// A month of the grid, in the model's order (newest first).
    struct Month: Equatable {
        /// Its index in the model's sections, or nil for a month only the phone has photos of.
        let section: Int?
        let id: String
        let count: Int
        /// Its tiles in the model's order, where photos on their way are among them; nil where there are none, and
        /// each tile is the model's photo at its own index.
        let slots: [Slot]?
    }

    /// The model's months with the photos on their way placed among them. `byDate`: they go among the month's photos
    /// by when each was taken; otherwise at the month's newest end.
    static func merge(_ months: [ModelMonth], phone: [Phone], byDate: Bool) -> [Month] {
        guard !phone.isEmpty else {
            return months.map { Month(section: $0.section, id: $0.id, count: $0.count, slots: nil) }
        }
        // Each month's photos on their way, newest first.
        var byMonth: [String: [Phone]] = [:]
        for photo in phone { byMonth[photo.month, default: []].append(photo) }
        for key in byMonth.keys {
            byMonth[key]?.sort { $0.date != $1.date ? $0.date > $1.date : $0.index < $1.index }
        }
        var merged: [Month] = []
        var placed = Set<String>()
        for month in months {
            let key = String(month.id.prefix(7))
            // Months only the phone has, newer than this one, come before it.
            for phoneKey in byMonth.keys.sorted(by: >) where phoneKey > key && !placed.contains(phoneKey) {
                if let own = byMonth[phoneKey] {
                    merged.append(phoneOnly(phoneKey, own))
                    placed.insert(phoneKey)
                }
            }
            guard let own = byMonth[key], !placed.contains(key) else {
                merged.append(Month(section: month.section, id: month.id, count: month.count, slots: nil))
                continue
            }
            placed.insert(key)
            let slots = byDate ? interleave(own, month) : own.map { Slot.phone($0.index) } + (0..<month.count).map(Slot.model)
            merged.append(Month(section: month.section, id: month.id, count: slots.count, slots: slots))
        }
        // Months only the phone has, older than every month of the model's.
        for phoneKey in byMonth.keys.sorted(by: >) where !placed.contains(phoneKey) {
            if let own = byMonth[phoneKey] { merged.append(phoneOnly(phoneKey, own)) }
        }
        return merged
    }

    /// The photos on their way among a month's photos by when each was taken, newest first; the model's photos keep
    /// their order. Where the month is not read, or a photo has no date, they stay at its newest end.
    private static func interleave(_ phone: [Phone], _ month: ModelMonth) -> [Slot] {
        guard let dates = month.dates, dates.count == month.count else {
            return phone.map { Slot.phone($0.index) } + (0..<month.count).map(Slot.model)
        }
        var slots: [Slot] = []
        slots.reserveCapacity(phone.count + month.count)
        var next = 0
        for item in 0..<month.count {
            while next < phone.count, let date = dates[item], phone[next].date >= date {
                slots.append(.phone(phone[next].index))
                next += 1
            }
            // A photo without a date keeps the photos on their way at the newest end before it.
            if dates[item] == nil {
                while next < phone.count {
                    slots.append(.phone(phone[next].index))
                    next += 1
                }
            }
            slots.append(.model(item))
        }
        while next < phone.count {
            slots.append(.phone(phone[next].index))
            next += 1
        }
        return slots
    }

    private static func phoneOnly(_ key: String, _ phone: [Phone]) -> Month {
        Month(section: nil, id: key + "-01T00:00:00.000Z", count: phone.count, slots: phone.map { Slot.phone($0.index) })
    }

    /// A photo's month as Immich files it: by its own clock where it was taken, which for a photo just taken is this
    /// phone's time zone.
    static func month(of date: Date, in timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}
