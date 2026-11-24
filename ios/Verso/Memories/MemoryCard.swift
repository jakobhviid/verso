// A memory as a card, as the Mac and Linux draw one (mac/Verso/Verso/Views/Explore/ExploreMemoriesView.swift): three
// of its photos, one large beside two small, or the first alone; on a fade at their foot what it recalls, the day with
// its year and how many photos, and where most were taken and whom; New until it has been opened; and in the corner
// the bookmark that keeps it, as Immich's cleanup removes a memory after 30 days unless it is kept. On the Memories
// page the bookmark is a button; elsewhere it shows only while the memory is kept.

import SwiftUI

struct MemoryCard: View {
    let pipeline: ImagePipeline
    let memory: ExploreMemory
    /// Keeps the memory or lets it go; nil where the card only shows whether it is kept.
    var keep: ((Bool) -> Void)? = nil

    var body: some View {
        photos
            .aspectRatio(1.4, contentMode: .fit)
            .overlay(alignment: .bottom) { foot }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                if memory.seenAt == nil {
                    Text("New")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) { bookmark }
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
    }

    /// One photo large beside two small, or the first alone.
    @ViewBuilder private var photos: some View {
        let shown = memory.assets.filter { $0.visibility != "locked" }.prefix(3)
        let assets = Array(shown)
        if assets.count >= 3 {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ExploreThumbnail(pipeline: pipeline, assetID: assets[0].id, size: .preview, thumbhash: assets[0].thumbhash)
                        .frame(width: geometry.size.width * 0.62)
                    VStack(spacing: 2) {
                        ExploreThumbnail(pipeline: pipeline, assetID: assets[1].id, thumbhash: assets[1].thumbhash)
                        ExploreThumbnail(pipeline: pipeline, assetID: assets[2].id, thumbhash: assets[2].thumbhash)
                    }
                }
            }
        } else {
            ExploreThumbnail(pipeline: pipeline, assetID: assets.first?.id, size: .preview, thumbhash: assets.first?.thumbhash)
        }
    }

    /// Its title, day and what it is about, on a fade at the photos' foot, as an album's card has its own.
    private var foot: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: memory.title)
                .font(.headline)
                .lineLimit(1)
            Text(memory.dayLine)
                .font(.caption)
                .opacity(0.9)
                .lineLimit(1)
            if let about = memory.aboutLine {
                Text(about)
                    .font(.caption)
                    .opacity(0.85)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 28)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
        .accessibilityElement(children: .combine)
    }

    /// The bookmark: a button that keeps the memory or lets it go, or the mark of a kept one.
    @ViewBuilder private var bookmark: some View {
        let kept = memory.isSaved == true
        if let keep {
            Button { keep(!kept) } label: {
                bookmarkImage(kept)
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel(kept ? "Kept" : "Keep")
            .accessibilityHint(kept ? "Lets Immich remove it after 30 days"
                               : "Immich removes a memory after 30 days unless it is kept")
        } else if kept {
            bookmarkImage(true)
                .padding(4)
                .accessibilityLabel("Kept")
        }
    }

    private func bookmarkImage(_ kept: Bool) -> some View {
        Image(systemName: kept ? "bookmark.fill" : "bookmark")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(.black.opacity(0.45), in: Circle())
            .padding(4)
            .contentShape(.rect)
    }
}

extension ExploreMemory {
    /// The day it recalls, with its year, and how many photos. Immich keeps the day as its UTC midnight, so it is read in
    /// UTC, or west of it shows the day before.
    var dayLine: String {
        let count = assets.count == 1 ? String(localized: "1 photo") : String(localized: "\(assets.count) photos")
        guard let day = memoryAt.flatMap(ImmichDate.parse) else { return "\(data.year) · \(count)" }
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return "\(day.formatted(style)) · \(count)"
    }

    /// Where most of its photos were taken and the named people in the most of them.
    var aboutLine: String? {
        func mostCommon(_ values: [String], limit: Int) -> [String] {
            var counts: [String: Int] = [:]
            for value in values { counts[value, default: 0] += 1 }
            let ranked = counts.sorted { first, second in
                first.value != second.value ? first.value > second.value : first.key < second.key
            }
            return ranked.prefix(limit).map(\.key)
        }
        let place = mostCommon(assets.compactMap { $0.exifInfo?.city }.filter { !$0.isEmpty }, limit: 1).first
        let people = mostCommon(assets.flatMap { $0.people ?? [] }.map(\.name).filter { !$0.isEmpty }, limit: 3)
        let parts = [place, people.isEmpty ? nil : people.formatted(.list(type: .and))].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
