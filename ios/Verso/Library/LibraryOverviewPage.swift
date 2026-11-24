// Library's Years and Months on iOS, as Photos has them: a card for each year with a photo from its fullest month, and
// for each month a few photos from different days of it, both running as All Photos runs, the newest at the end
// GridNewestEnd chooses (the bottom by default), where the page opens. A year opens its months, at the year; a photo
// opens All Photos at it. What they show is arranged by the shared core (`overviewYears`, `overviewPicks`), as on the
// Mac (mac/Verso/Verso/Views/Grid/LibraryOverviewView.swift) and Linux.
//
// The title is the Library's (PageTitle). The whole tab bar stays here (LibraryTabs), with Years, Months and All in a
// glass capsule of the page's own above it, so they never stand at the accessory's full width. A tap on the Library
// tab goes to the newest end, as in All.

import SwiftUI
import VersoCore

struct LibraryOverviewPage: View {
    let session: LibrarySession
    /// Years or Months.
    let mode: LibraryMode
    @Environment(LibraryChrome.self) private var chrome
    /// Where Months starts: the month of the year a card opened that comes first down the page.
    @State private var monthsStart: String?
    /// This page, among the window's pages that open at their bottom.
    @State private var pageID = UUID()
    @AppStorage(GridNewestEnd.storageKey) private var newestEnd = GridNewestEnd.bottom

    private var newestAtTop: Bool { newestEnd == .top }
    /// The end the newest year or month is at, where the page opens and lands.
    private var newestAnchor: UnitPoint { newestAtTop ? .top : .bottom }

    var body: some View {
        let model = session.gridModel(for: .library)
        Group {
            if model.sections.isEmpty {
                emptyState(model)
            } else if mode == .years {
                years(model)
            } else {
                months(model)
            }
        }
        .navigationTitle("Library")
        .pageTitle("Library", line: "")
        .safeAreaBar(edge: .bottom) {
            LibraryModeCapsule(mode: Binding(get: { chrome.libraryMode }, set: { chrome.libraryMode = $0 }))
                .padding(.bottom, 8)
        }
        .task(id: session.macGridRevision) { await model.loadIfNeeded() }
        .onAppear { chrome.setOpensAtBottom(pageID, !newestAtTop) }
        .onDisappear { chrome.setOpensAtBottom(pageID, false) }
    }

    @ViewBuilder
    private func emptyState(_ model: AssetGridModel) -> some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
        case .loaded:
            ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle")
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Load Photos", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
            }
        }
    }

    // MARK: Years

    private func years(_ model: AssetGridModel) -> some View {
        // Oldest first (the model keeps its months newest first), and the other way about with Newest at the Top.
        let years = overviewYears(months: model.sections.reversed().map { OverviewMonth(bucket: $0.id, count: UInt32(clamping: $0.count)) })
        let shown = newestAtTop ? Array(years.reversed()) : years
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                    ForEach(shown) { year in
                        Button { open(year) } label: {
                            LibraryYearCard(model: model, year: year, pipeline: session.pipeline)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: year.id))
                        .id(year.id)
                    }
                }
                .padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .defaultScrollAnchor(newestAnchor, for: .initialOffset)
            .refreshable { [model] in await model.reload() }
            .onChange(of: chrome.libraryLandings) {
                guard let newest = years.last?.id else { return }
                withAnimation(.smooth) { proxy.scrollTo(newest, anchor: newestAnchor) }
            }
        }
    }

    /// Months, with the year at the top: its first month, or its last with Newest at the Top, where Months runs from
    /// the newest down.
    private func open(_ year: OverviewYear) {
        monthsStart = newestAtTop ? year.months.last : year.months.first
        chrome.libraryMode = .months
    }

    // MARK: Months

    private func months(_ model: AssetGridModel) -> some View {
        // The model keeps its months newest first.
        let months = newestAtTop ? Array(model.sections.enumerated()) : Array(model.sections.enumerated().reversed())
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 20)], alignment: .leading, spacing: 28) {
                    ForEach(months, id: \.element.id) { index, section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title ?? "")
                                .font(.title2.bold())
                                .accessibilityAddTraits(.isHeader)
                            LibraryMonthMosaic(model: model, index: index, pipeline: session.pipeline) { id in
                                model.viewerScrollTarget = id
                                chrome.libraryMode = .all
                            }
                        }
                        .id(section.id)
                    }
                }
                .padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .defaultScrollAnchor(newestAnchor, for: .initialOffset)
            .refreshable { [model] in await model.reload() }
            .onChange(of: chrome.libraryLandings) {
                guard let newest = model.sections.first?.id else { return }
                withAnimation(.smooth) { proxy.scrollTo(newest, anchor: newestAnchor) }
            }
            .onAppear {
                guard let start = monthsStart else { return }
                monthsStart = nil
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(start, anchor: .top)
                }
            }
        }
    }
}

/// A month's photos as the shared core picks from them.
private func overviewPhotos(_ assets: [AssetItem]) -> [OverviewPhoto] {
    assets.map { OverviewPhoto(id: $0.id, taken: $0.date, isVideo: $0.isVideo) }
}

/// A year: a photo from its fullest month, the year written over it.
private struct LibraryYearCard: View {
    let model: AssetGridModel
    let year: OverviewYear
    let pipeline: ImagePipeline

    var body: some View {
        let index = model.sections.firstIndex { $0.id == year.keyMonth }
        let photo = index.flatMap { model.sections[$0].assets }
            .flatMap { overviewPicks(photos: overviewPhotos($0), limit: 1).first }
        Color.clear
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                GridThumbnailImage(pipeline: pipeline, assetID: photo?.id, size: .preview)
            }
            .clipShape(.rect(cornerRadius: 22))
            .overlay(alignment: .topLeading) {
                Text(verbatim: year.id)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 6)
                    .padding(20)
            }
            .contentShape(.rect(cornerRadius: 22))
            .onAppear { if let index { model.ensureLoaded(index) } }
    }
}

/// A month: one large photo and up to three beside it, each from a different day, the day written on it.
private struct LibraryMonthMosaic: View {
    let model: AssetGridModel
    let index: Int
    let pipeline: ImagePipeline
    let openPhoto: (String) -> Void
    private let spacing = 4.0

    var body: some View {
        let assets = model.sections.indices.contains(index) ? model.sections[index].assets : nil
        let picks = assets.map { overviewPicks(photos: overviewPhotos($0), limit: 4) } ?? []
        Color.clear
            .aspectRatio(1.5, contentMode: .fit)
            .overlay {
                if picks.isEmpty {
                    RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                } else {
                    GeometryReader { geometry in
                        HStack(spacing: spacing) {
                            tile(picks[0])
                                .frame(width: picks.count > 1
                                       ? (geometry.size.width - spacing) * (picks.count > 2 ? 2 / 3 : 1 / 2)
                                       : geometry.size.width)
                            if picks.count > 1 {
                                VStack(spacing: spacing) {
                                    ForEach(picks.dropFirst(), id: \.id) { tile($0) }
                                }
                            }
                        }
                    }
                    .clipShape(.rect(cornerRadius: 18))
                }
            }
            .onAppear { model.ensureLoaded(index) }
    }

    private func tile(_ pick: OverviewPick) -> some View {
        Button { openPhoto(pick.id) } label: {
            GridThumbnailImage(pipeline: pipeline, assetID: pick.id, size: .preview)
                .overlay(alignment: .topLeading) {
                    if let day = pick.day {
                        Text(verbatim: String(day))
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 4)
                            .padding(10)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
