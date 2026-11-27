import Foundation
import Observation
import VersoCore

// The photos the TV shows, and the timeline they are read from month by month, as the iPhone's grid model reads them
// (mac/Verso/Verso/App/AssetGridModel.swift) without what a read-only viewer has no use for.

/// A photo or video as the TV shows it.
struct TVItem: Identifiable, Hashable, Sendable {
    let id: String
    var isVideo: Bool
    var isFavorite = false
    var durationMS: Int?
    /// When it was taken, as the server keeps it: the wall clock where it was taken, written as UTC.
    var date: Date?
    /// A Live Photo's movie, which the remote's play/pause plays.
    var livePhotoVideoID: String?
    var thumbhash: String?

    init(id: String, isVideo: Bool, isFavorite: Bool = false, durationMS: Int? = nil, date: Date? = nil,
         livePhotoVideoID: String? = nil, thumbhash: String? = nil) {
        self.id = id
        self.isVideo = isVideo
        self.isFavorite = isFavorite
        self.durationMS = durationMS
        self.date = date
        self.livePhotoVideoID = livePhotoVideoID
        self.thumbhash = thumbhash
    }

    init(_ asset: AssetResponse) {
        self.init(id: asset.id, isVideo: asset.type == .video, isFavorite: asset.isFavorite, durationMS: asset.duration?.milliseconds,
                  date: ImmichDate.parse(asset.localDateTime), livePhotoVideoID: asset.livePhotoVideoId, thumbhash: asset.thumbhash)
    }

    /// A month's photos, without the Locked Folder's, unless the month is the Locked Folder's own (`keepsLocked`), which
    /// only its session, unlocked from the iPhone, reads.
    static func items(_ month: TimeBucketAssets, keepsLocked: Bool = false) -> [TVItem] {
        month.id.indices.filter { keepsLocked || month.visibility?.indices.contains($0) != true || month.visibility?[$0] != "locked" }.map { index in
            TVItem(id: month.id[index], isVideo: !month.isImage[index], isFavorite: month.isFavorite[index],
                   durationMS: month.duration[index]?.milliseconds, date: ImmichDate.parse(month.fileCreatedAt[index]),
                   livePhotoVideoID: month.livePhotoVideoId[index], thumbhash: month.thumbhash[index])
        }
    }

    /// Photos from a search or a memory, without the Locked Folder's.
    static func items(_ assets: [AssetResponse]) -> [TVItem] {
        assets.filter { $0.visibility != "locked" }.map(TVItem.init)
    }
}

/// Which photos the viewer steps through, and where it starts. `more` reads what comes after the last of them, the
/// next month of a timeline, and answers every photo then known, or nil where there is nothing more.
struct TVViewing: Identifiable {
    let id = UUID()
    let items: [TVItem]
    let index: Int
    var more: (@MainActor () async -> [TVItem]?)?

    /// The photo it opens at, whose tile it grows out of.
    var startID: String { items.indices.contains(index) ? items[index].id : "" }
}

/// A timeline: its months, newest first as the server sends them, each read as it comes into view.
@MainActor @Observable
final class TVTimelineModel: TVPhotoPage {
    struct Month: Identifiable {
        let id: String
        var count: Int
        var items: [TVItem]?
    }

    enum Phase: Equatable { case loading, loaded, failed(String) }

    let query: TimelineQuery
    private(set) var months: [Month] = [] { didSet { revision += 1 } }
    private(set) var phase = Phase.loading
    /// Counts every change to the months, which the grid redraws by (TVPhotoGrid).
    private(set) var revision = 0
    @ObservationIgnored private var reading: Set<String> = []

    init(query: TimelineQuery) {
        self.query = query
    }

    /// How many photos the timeline holds.
    var total: Int { months.reduce(0) { $0 + $1.count } }

    /// The photos of the months read so far, in order.
    var items: [TVItem] { months.flatMap { $0.items ?? [] } }

    func load(_ client: ImmichClient?) async {
        guard let client else { return }
        do {
            months = try await client.timeBuckets(query).filter { $0.count > 0 }.map { Month(id: $0.timeBucket, count: $0.count) }
            phase = .loaded
        } catch is CancellationError {
        } catch {
            if months.isEmpty { phase = .failed(error.localizedDescription) }
        }
    }

    func reload(_ client: ImmichClient?) async {
        phase = .loading
        months = []
        await load(client)
    }

    /// Reads a month, once.
    func read(_ id: String, client: ImmichClient?) async {
        guard let client, let index = months.firstIndex(where: { $0.id == id }), months[index].items == nil,
              !reading.contains(id) else { return }
        reading.insert(id)
        defer { reading.remove(id) }
        guard let assets = try? await client.timeBucket(id, query),
              let current = months.firstIndex(where: { $0.id == id }) else { return }
        months[current].items = TVItem.items(assets, keepsLocked: query.visibility == "locked")
    }

    /// A photo a menu changed (TVPhotoMenu): a favorite's heart, or gone from the timeline, as from Favorites once it is
    /// no longer one.
    func apply(_ change: TVPhotoChange) {
        for index in months.indices {
            guard var items = months[index].items, let at = items.firstIndex(where: { $0.id == change.id }) else { continue }
            switch change {
            case .favorite(_, let on) where !(query.isFavorite == true && !on):
                items[at].isFavorite = on
            default:
                items.remove(at: at)
                months[index].count -= 1
            }
            months[index].items = items
        }
        months.removeAll { $0.count <= 0 }
    }

    /// The viewer over every photo read so far, from a month's photo, which reads the following months as it nears
    /// their end.
    func viewing(month index: Int, photo: Int, client: ImmichClient?) -> TVViewing {
        let before = months.prefix(index).reduce(0) { $0 + ($1.items?.count ?? 0) }
        return TVViewing(items: items, index: before + photo) { [self] in await readNext(client: client) }
    }

    /// Reads the first month not read yet, for the viewer stepping past the last photo it has, and answers every photo.
    func readNext(client: ImmichClient?) async -> [TVItem]? {
        guard let next = months.first(where: { $0.items == nil }) else { return nil }
        await read(next.id, client: client)
        return items
    }
}

enum TVFormat {
    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    /// "May 2024" from a time bucket's "2024-05-01T00:00:00.000Z".
    static func month(_ bucket: String) -> String { ImmichDate.monthTitle(bucket) }

    /// "Today", "Yesterday", the weekday within the week, the day and month within the year, else the full date, as the
    /// iPhone's viewer names a photo's day (ViewerDays).
    static func day(_ date: Date, now: Date = .now) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let photoDay = calendar.dateComponents([.year, .month, .day], from: date)
        let today = Calendar.current.dateComponents([.year, .month, .day], from: now)
        guard let photoStart = calendar.date(from: photoDay), let todayStart = calendar.date(from: today),
              let days = calendar.dateComponents([.day], from: photoStart, to: todayStart).day else {
            return date.formatted(Date.FormatStyle(timeZone: utc).day().month(.wide).year())
        }
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        case 2...6: return date.formatted(Date.FormatStyle(timeZone: utc).weekday(.wide))
        default:
            if photoDay.year == today.year { return date.formatted(Date.FormatStyle(timeZone: utc).day().month(.wide)) }
            return date.formatted(Date.FormatStyle(timeZone: utc).day().month(.wide).year())
        }
    }
}
