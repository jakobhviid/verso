// What Search suggests (ROADMAP.md, M10: "Search's suggestions as glass chips: people with their faces, places,
// recent searches"). Before typing: the quick filters the Mac's search page has, people, places, tags and the recent
// searches. While typing: the words to search for, then the people Immich finds by that name, and the places, tags
// and recent searches that match. A quick filter or a recent search runs at once; a person opens their page, and a
// place or a tag its photos, as Immich's app opens them from its search page.

import SwiftUI

/// The people, places and settings the suggestions are made from, read once per connection.
@MainActor @Observable
final class SearchSuggestionsModel {
    /// The people Immich lists first, the named ones, as Search's chips show them.
    private(set) var people: [Person] = []
    /// The places in the library, each with a photo, as Immich's explore page lists them.
    private(set) var places: [String] = []
    /// Ratings are a choice in the filters when the account has them on.
    private(set) var ratingsEnabled = false
    /// Whom a typed name found on the server, and the name; nil before any name.
    private(set) var found: (name: String, people: [Person])?

    func load(_ session: LibrarySession) async {
        let client = session.client
        async let preferences = try? client.searchPreferences()
        async let explore = try? client.searchExplore()
        if session.features.facialRecognition {
            do {
                people = try await session.client.peoplePage(page: 1, withHidden: false).people.filter { !$0.name.isEmpty }
            } catch { session.handle(error) }
        }
        ratingsEnabled = await preferences?.ratings?.enabled ?? false
        // Explore lists places alone in Immich 3; only the fields searched exactly are offered, as on the Mac.
        let groups = await explore ?? []
        places = groups.filter { $0.fieldName == "exifInfo.city" }.flatMap(\.items)
            .filter { $0.data.visibility != "locked" }.map(\.value)
    }

    /// Asks the server whom a name finds, a moment after typing stops.
    func find(_ name: String, session: LibrarySession) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, session.features.facialRecognition else { found = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let result = try await session.client.peoplePage(page: 1, withHidden: false, name: name)
            try Task.checkCancellation()
            found = (name, result.people)
        } catch {
            if !error.isCancellation { session.handle(error) }
        }
    }
}

struct SearchSuggestionsView: View {
    let session: LibrarySession
    let text: String
    let filters: SearchQuery
    let history: SearchHistory
    let suggestions: SearchSuggestionsModel
    let run: (SearchQuery) -> Void
    let removeFilter: (SearchQuery.Filter) -> Void
    let clearFilters: () -> Void
    @Environment(\.pushRoute) private var pushRoute

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !filters.chips.isEmpty {
                    filtersSet
                }
                if typed.isEmpty { landing } else { matches }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.immediately)
        .task(id: typed) { await suggestions.find(typed, session: session) }
    }

    // MARK: Before typing

    @ViewBuilder
    private var landing: some View {
        // The Mac's quick filters, first and without a heading.
        chips {
            SearchChip(Text("Favorites"), systemImage: "heart") { run(with { $0.favorites = true }) }
            SearchChip(Text("Photos"), systemImage: "photo") { run(with { $0.mediaType = "IMAGE" }) }
            SearchChip(Text("Videos"), systemImage: "video") { run(with { $0.mediaType = "VIDEO" }) }
        }
        if !suggestions.people.isEmpty {
            section("People") {
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(suggestions.people.prefix(20)) { person in personChip(person) }
                        }
                    }
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
        }
        if !suggestions.places.isEmpty {
            section("Places") {
                chips { ForEach(suggestions.places.prefix(12), id: \.self) { placeChip($0) } }
            }
        }
        if !session.exploreTags.isEmpty {
            section("Tags") {
                chips { ForEach(session.exploreTags.prefix(20)) { tagChip($0) } }
            }
        }
        if !history.entries.isEmpty {
            section("Recent Searches", trailing: { Button("Clear") { history.clear() } }) {
                recentRows(Array(history.entries.prefix(6)))
            }
        }
        if !session.features.smartSearch {
            Text("Smart search is off on this server, so Search finds photos by their file names.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }

    // MARK: While typing

    @ViewBuilder
    private var matches: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                run(with { $0.text = typed })
            } label: {
                Label { Text("Search for “\(typed)”") } icon: { Image(systemName: "magnifyingglass") }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        let people = foundPeople
        if !people.isEmpty {
            section("People") {
                chips { ForEach(people.prefix(12)) { personChip($0) } }
            }
        }
        let places = suggestions.places.filter { $0.localizedCaseInsensitiveContains(typed) }
        if !places.isEmpty {
            section("Places") {
                chips { ForEach(places.prefix(12), id: \.self) { placeChip($0) } }
            }
        }
        let tags = session.exploreTags.filter { $0.value.localizedCaseInsensitiveContains(typed) }
        if !tags.isEmpty {
            section("Tags") {
                chips { ForEach(tags.prefix(12)) { tagChip($0) } }
            }
        }
        let recent = history.entries.filter { entry in
            ([entry.text] + entry.chips).contains { $0.localizedCaseInsensitiveContains(typed) }
        }
        if !recent.isEmpty {
            section("Recent Searches") {
                recentRows(Array(recent.prefix(6)))
            }
        }
    }

    /// Whom the server found by the typed name, or until it answers, the listed people the name matches.
    private var foundPeople: [Person] {
        if let found = suggestions.found, found.name == typed { return found.people }
        return suggestions.people.filter { $0.name.localizedCaseInsensitiveContains(typed) }
    }

    // MARK: Pieces

    private var filtersSet: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(Text("Filters"))
            SearchFilterChips(query: filters, remove: removeFilter, clear: clearFilters)
            if typed.isEmpty {
                Button("Show Results") { run(filters) }
                    .buttonStyle(.glassProminent)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func personChip(_ person: Person) -> some View {
        SearchPersonChip(pipeline: session.pipeline, person: person) {
            pushRoute(.person(person))
        }
    }

    private func placeChip(_ city: String) -> some View {
        SearchChip(Text(verbatim: city), systemImage: "mappin") {
            pushRoute(.city(city))
        }
    }

    private func tagChip(_ tag: ExploreTag) -> some View {
        SearchChip(Text(verbatim: tag.value), systemImage: "tag") {
            pushRoute(.photos(.explore(.tag(tag.id)), title: tag.value))
        }
    }

    private func recentRows(_ entries: [SearchQuery]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                Button {
                    run(entry)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.text.isEmpty ? entry.chips.joined(separator: ", ") : entry.text)
                                .lineLimit(1)
                            if !entry.text.isEmpty && !entry.chips.isEmpty {
                                Text(verbatim: entry.chips.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The filters set with one change, the words left out unless the change puts them in.
    private func with(_ change: (inout SearchQuery) -> Void) -> SearchQuery {
        var query = filters
        query.text = ""
        change(&query)
        return query
    }

    private func chips<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        GlassEffectContainer(spacing: 8) {
            SearchChipFlow(spacing: 8) { content() }
        }
        .padding(.horizontal, 16)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    private func section<Trailing: View, Content: View>(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing,
                                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(Text(title))
                Spacer()
                trailing()
            }
            .padding(.trailing, 16)
            content()
        }
    }

    private func sectionTitle(_ title: Text) -> some View {
        title
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 16)
    }
}
