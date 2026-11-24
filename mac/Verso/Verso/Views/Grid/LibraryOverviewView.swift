import SwiftUI
import VersoCore

/// Library's Years and Months, as in Photos: a card for each year, and a few photos from different days of each month.
/// A year opens its months; a photo opens All Photos at it. The shared core arranges them (`overviewYears`,
/// `overviewPicks`), as on Linux and the iPhone.
struct LibraryOverviewView: View {
    let model: AssetGridModel
    let mode: LibraryMode
    /// Where Months starts: the month a year card opened.
    let startMonth: String?
    let openYear: (OverviewYear) -> Void
    let openPhoto: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if mode == .years { years } else { months }
            }
            .onAppear { if mode == .months, let startMonth { proxy.scrollTo(startMonth, anchor: .top) } }
        }
    }

    private var years: some View {
        let years = overviewYears(months: model.sections.map { OverviewMonth(bucket: $0.id, count: UInt32(clamping: $0.count)) })
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: 28)], spacing: 28) {
            ForEach(years) { year in
                Button { openYear(year) } label: { LibraryYearCard(model: model, year: year) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: year.id))
            }
        }
        .padding(32)
        .scrollTargetLayout()
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.3) { ids in
            let shown = Set(ids)
            model.showing(sections: years.filter { shown.contains($0.id) }.flatMap(\.months))
        }
    }

    private var months: some View {
        LazyVStack(alignment: .leading, spacing: 36) {
            ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.title ?? "").font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    LibraryMonthMosaic(model: model, index: index, openPhoto: openPhoto)
                }
                .id(section.id)
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .scrollTargetLayout()
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.3) { ids in
            model.showing(sections: ids)
        }
    }
}

extension OverviewPhoto {
    init(_ item: AssetItem) { self.init(id: item.id, taken: item.date, isVideo: item.isVideo) }
}

private struct LibraryYearCard: View {
    @Environment(LibrarySession.self) private var session
    let model: AssetGridModel
    let year: OverviewYear

    var body: some View {
        let index = model.sections.firstIndex { $0.id == year.keyMonth }
        let photo = index.flatMap { model.sections[$0].assets }
            .flatMap { overviewPicks(photos: $0.map(OverviewPhoto.init), limit: 1).first }
        RemoteThumbnail(pipeline: session.pipeline, assetID: photo?.id, size: .preview)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                Text(verbatim: year.id)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 6)
                    .padding(20)
            }
            .contentShape(.rect(cornerRadius: 12))
            .onAppear { if let index { model.ensureLoaded(index) } }
    }
}

private struct LibraryMonthMosaic: View {
    @Environment(LibrarySession.self) private var session
    let model: AssetGridModel
    let index: Int
    let openPhoto: (String) -> Void
    private let spacing = 12.0

    var body: some View {
        let assets = model.sections.indices.contains(index) ? model.sections[index].assets : nil
        // One large photo and up to three beside it.
        let picks = assets.map { overviewPicks(photos: $0.map(OverviewPhoto.init), limit: 4) } ?? []
        Color.clear
            .aspectRatio(2.2, contentMode: .fit)
            .overlay {
                if picks.isEmpty {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5))
                } else {
                    GeometryReader { geometry in
                        // One large photo and the others beside it, as Photos' Months.
                        HStack(spacing: spacing) {
                            tile(picks[0])
                                .frame(width: picks.count > 1 ? (geometry.size.width - spacing) * (picks.count > 2 ? 2 / 3 : 1 / 2) : geometry.size.width)
                            if picks.count > 1 {
                                VStack(spacing: spacing) {
                                    ForEach(picks.dropFirst(), id: \.id) { tile($0) }
                                }
                            }
                        }
                    }
                }
            }
            .onAppear { model.ensureLoaded(index) }
    }

    private func tile(_ pick: OverviewPick) -> some View {
        Button { openPhoto(pick.id) } label: {
            RemoteThumbnail(pipeline: session.pipeline, assetID: pick.id, size: .preview)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if let day = pick.day {
                        Text(verbatim: String(day))
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 4)
                            .padding(12)
                    }
                }
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
