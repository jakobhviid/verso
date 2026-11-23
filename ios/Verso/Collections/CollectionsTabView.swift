// The Collections tab on iOS (ROADMAP.md, M10): every section of the library but the timeline, in the order and with
// the sections Edit Sidebar keeps (CollectionsLinks.swift), as blocks down the page, as Photos' Collections in iOS 26.
// Albums, People, Places and Memories are blocks of their own: a header line (the title, the count and a chevron)
// that opens the whole page, and cards scrolling sideways beneath it. A section's other links (Sharing, Utilities,
// Tags and Folders) are rows in a grouped box under the section's name, which collapses it, remembered in the layout as
// the Mac's sidebar remembers it. What the tab bar holds leaves Collections (TabBarChoice), as do Favorites and Videos,
// the Library's filters, and the shared albums, a filter in Albums. Customize, at the foot as Photos has it, orders the
// sections and links, chooses what shows and what the tab bar holds. The toolbar holds "+" and the account
// (CollectionsToolbar). Every page opens as a `Route` on the tab's stack.

import SwiftUI

struct CollectionsTabView: View {
    let session: LibrarySession
    @AppStorage(collectionsLayoutKey) private var storedLayout = ""
    @AppStorage(TabBarChoice.storageKey) private var storedTabBar = ""
    @State private var previews = CollectionsPreviews()
    @State private var customizing = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = SidebarLayout(stored: storedLayout)
        let blocks = session.collectionsBlocks(layout: layout, tabBar: TabBarChoice.decode(storedTabBar))
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(blocks) { block in
                    switch block {
                    case .cards(let link): cardsBlock(link, layout: layout)
                    case .rows(let section, let entries): rowsBlock(section, entries: entries)
                    }
                }
                Button("Customize") { customizing = true }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .modifier(CollectionsTitle(regular: sizeClass == .regular))
        .collectionsToolbar(session: session)
        .refreshable { await refresh(blocks) }
        .task(id: previewsWanted(blocks)) { await loadPreviews(blocks) }
        // As the grids: the counts read again once something marked them stale, a delete or an import.
        .task(id: session.macGridRevision) { await previews.loadCounts(session) }
        .sheet(isPresented: $customizing) {
            CollectionsCustomizeSheet(session: session)
        }
    }

    // MARK: Blocks

    /// Albums, People, Places or Memories: the header, which opens the page, and the cards beneath it.
    private func cardsBlock(_ link: SidebarLink, layout: SidebarLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let route = link.collectionsRoute {
                CollectionsBlockHeader(title: Text(link.collectionsTitle), count: count(of: link), route: route)
            }
            cards(of: link, layout: layout)
        }
    }

    /// A section's links in a grouped box under the section's name, which collapses it; in a regular width, as Photos'
    /// Utilities on an iPad, each link a box of its own, two to a row.
    private func rowsBlock(_ section: SidebarSection, entries: [CollectionsEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CollectionsSectionHeader(title: section.collectionsLabel, expanded: expanded(section))
            if !section.isCollapsed, sizeClass == .regular {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(entries) { entry in
                        row(entry)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(.rect(cornerRadius: collectionsBoxCornerRadius))
                    }
                }
                .padding(.horizontal, collectionsMargin)
            } else if !section.isCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().padding(.leading, CollectionsRow.textInset)
                        }
                        row(entry)
                    }
                }
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(.rect(cornerRadius: collectionsBoxCornerRadius))
                .padding(.horizontal, collectionsMargin)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: CollectionsEntry) -> some View {
        switch entry {
        case .link(let link):
            if let route = link.collectionsRoute {
                CollectionsRow(title: Text(link.collectionsTitle), systemImage: link.collectionsSymbol, count: count(of: link),
                               route: route)
            }
        case .partner(let id, let name):
            CollectionsRow(title: Text(verbatim: name), systemImage: "person.2", count: nil,
                           route: .photos(.partner(id), title: name))
        }
    }

    private func count(of link: SidebarLink) -> Int? {
        switch link {
        case .albums: session.albums.count
        case .people: previews.peopleTotal
        case .places, .map: previews.cities.isEmpty ? nil : previews.cities.count
        case .memories: previews.memories.isEmpty ? nil : previews.memories.count
        case .sharedLinks: session.sharing.links.count
        case .tags: session.exploreTags.count
        default: previews.counts[link]
        }
    }

    // MARK: Cards

    /// What Albums, People, Places and Memories hold, as cards in a row: the cards their own pages draw, an album's
    /// cover, a person's face with the name on it, a memory's three photos, a city's photo with its name on it.
    @ViewBuilder
    private func cards(of link: SidebarLink, layout: SidebarLayout) -> some View {
        switch link {
        case .albums:
            albumCards(session.collectionsAlbums(layout: layout))
        case .people where !previews.people.isEmpty:
            CollectionsCardRow(perScreen: sizeClass == .regular ? 7.5 : 3.5) {
                ForEach(previews.people) { person in
                    NavigationLink(value: Route.person(person)) {
                        PersonFaceTile(pipeline: session.pipeline, person: person)
                    }
                }
            }
        case .memories where !previews.memories.isEmpty:
            CollectionsCardRow(perScreen: sizeClass == .regular ? 3.5 : 1.5) {
                ForEach(previews.memories) { memory in
                    NavigationLink(value: Route.memories(opening: memory.id)) {
                        MemoryCard(pipeline: session.pipeline, memory: memory)
                    }
                }
            }
        case .memories where previews.memoriesRead:
            // Immich makes a day's memories from the photos of that day in earlier years; some days have none.
            Text("No Memories Today")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, collectionsMargin)
        case .places where !previews.cities.isEmpty:
            CollectionsCardRow(perScreen: cardsPerScreen) {
                NavigationLink(value: Route.places) {
                    CollectionsMapCard(places: previews.cities)
                }
                ForEach(previews.cities.prefix(CollectionsPreviews.rowLimit)) { place in
                    let city = place.exifInfo?.city ?? ""
                    NavigationLink(value: Route.city(city)) {
                        PlaceCityTile(pipeline: session.pipeline, place: place, showsCountry: true)
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    /// Albums as Photos' covers, the card pages' smallest cards, two and a half to the width on iPhone; See All last
    /// when the row is shortened.
    @ViewBuilder
    private func albumCards(_ albums: [Album]) -> some View {
        if !albums.isEmpty {
            let shown = albums.prefix(CollectionsPreviews.rowLimit)
            CollectionsCardRow(perScreen: cardsPerScreen) {
                ForEach(shown) { album in
                    NavigationLink(value: Route.album(album)) {
                        AlbumCoverCard(session: session, album: album)
                    }
                }
                if albums.count > shown.count {
                    NavigationLink(value: Route.albums) {
                        VStack(alignment: .leading, spacing: 4) {
                            CollectionsSeeAllCard()
                            Spacer(minLength: 0)
                        }
                    }
                    .accessibilityLabel("See All Albums")
                }
            }
        }
    }

    private var cardsPerScreen: Double { sizeClass == .regular ? 4.5 : 2.5 }

    // MARK: Collapsing and loading

    /// A section's disclosure, saved in the layout as the Mac's sidebar saves it.
    private func expanded(_ section: SidebarSection) -> Binding<Bool> {
        Binding(get: { !section.isCollapsed }, set: { expanded in
            var updated = SidebarLayout(stored: storedLayout)
            updated.setSectionCollapsed(!expanded, id: section.id)
            withAnimation(reduceMotion ? nil : .default) { storedLayout = updated.stored }
        })
    }

    /// The blocks of cards that read what they show, so each is read once it is shown.
    private func previewsWanted(_ blocks: [CollectionsBlock]) -> Set<SidebarLink> {
        var wanted = Set<SidebarLink>()
        for case .cards(let link) in blocks where [.people, .memories, .places].contains(link) {
            wanted.insert(link)
        }
        return wanted
    }

    private func loadPreviews(_ blocks: [CollectionsBlock]) async {
        let wanted = previewsWanted(blocks)
        if wanted.contains(.people) { await previews.loadPeople(session) }
        if wanted.contains(.memories) { await previews.loadMemories(session) }
        if wanted.contains(.places) { await previews.loadPlaces(session) }
    }

    private func refresh(_ blocks: [CollectionsBlock]) async {
        let wanted = previewsWanted(blocks)
        await session.reloadAlbums()
        await session.sharing.reload()
        await session.loadExploreTags(refresh: true)
        await previews.reload(session, people: wanted.contains(.people), memories: wanted.contains(.memories),
                              places: wanted.contains(.places))
    }
}

/// The page's margin at either side, which the headers, the boxes and the first card keep.
let collectionsMargin: CGFloat = 16
/// The corner of a section's box of rows, as iOS 26's grouped lists round theirs.
let collectionsBoxCornerRadius: CGFloat = 26

/// The header of a block of cards, as Photos' collections have it: the title, the count and a chevron, which open the
/// whole page.
struct CollectionsBlockHeader: View {
    let title: Text
    let count: Int?
    let route: Route

    var body: some View {
        HStack(spacing: 0) {
            NavigationLink(value: route) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    if let count {
                        Text(count.formatted())
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, collectionsMargin)
    }
}

/// The header of a section's box of rows: its name, and a chevron that turns as a tap collapses or expands it, as the
/// system's sidebar sections do.
struct CollectionsSectionHeader: View {
    let title: Text
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack {
                title
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, collectionsMargin)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
    }
}

/// A row in a section's box: the symbol, the title, the count where there is one, and the chevron of a page to open.
struct CollectionsRow: View {
    let title: Text
    let systemImage: String
    let count: Int?
    let route: Route

    /// Where the title starts, from the box's leading edge, which the dividers between rows keep.
    static let textInset: CGFloat = 60

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                title
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let count {
                    Text(count.formatted())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(CollectionsRowStyle())
        // Under an iPad's pointer the row is lit, as a list's row is.
        .hoverEffect(.highlight)
    }
}

/// A row's press: the row darkens under the finger, as a list's row does.
private struct CollectionsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(uiColor: .systemFill) : .clear)
    }
}

/// A row of cards that scrolls sideways under its header, from edge to edge, settling on a card; `perScreen` cards to
/// the width, the half showing there is more.
struct CollectionsCardRow<Content: View>: View {
    let perScreen: Double
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                content
                    .buttonStyle(.plain)
                    .contentShape(.hoverEffect, .rect(cornerRadius: 12, style: .continuous))
                    .hoverEffect(.lift)
                    .containerRelativeFrame(.horizontal, count: Int(perScreen * 2), span: 2, spacing: 12)
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, collectionsMargin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

/// Collections' title: the system's large title in the bar's row on a phone; on an iPad the photo pages' own
/// (PageTitle), which iPadOS's top tab bar leaves room for where it hides the system's.
private struct CollectionsTitle: ViewModifier {
    let regular: Bool

    func body(content: Content) -> some View {
        if regular {
            content.cardPageTitle(String(localized: "Collections"))
        } else {
            content
                .navigationTitle("Collections")
                .toolbarTitleDisplayMode(.inlineLarge)
        }
    }
}
