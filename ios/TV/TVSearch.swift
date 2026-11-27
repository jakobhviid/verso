import Observation
import SwiftUI
import VersoCore

// Search on the TV, as the iPhone's (ios/Verso/Search/): typed, or spoken with the Siri Remote, on tvOS's own search
// screen. Before typing, the iPhone's start page: the quick filters, the people with their faces, the places and the
// recent searches; while typing, what matches; and on Search, the results in the grid, by Immich's smart search. A person
// or a place opens its photos, as the iPhone's chips do. What the TV leaves out: tags, which its read-only key may not
// list, and the filters sheet, which a remote makes a poor form of.

/// Where a suggestion leads.
enum TVSearchRoute: Hashable {
    case person(id: String, name: String)
    case city(String)
}

struct TVSearch: View {
    @Environment(TVModel.self) private var tv
    @State private var path: [TVSearchRoute] = []
    @State private var text = ""
    /// The search whose results show; nil while the suggestions show.
    @State private var submitted: SearchQuery?
    @State private var history = TVSearchHistory()
    @State private var suggestions = TVSuggestions()

    init() {
        #if DEBUG
        // A development build opens at the results of a search (`-tvSearch mountain`), to look at them.
        if let words = UserDefaults.standard.string(forKey: "tvSearch") {
            var query = SearchQuery()
            query.text = words
            _text = State(initialValue: words)
            _submitted = State(initialValue: query)
        }
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .searchable(text: $text)
                .onSubmit(of: .search) { submit() }
                // Editing the text after a search goes back to the suggestions, until Search again.
                .onChange(of: text) { _, value in
                    if let submitted, value != submitted.text { self.submitted = nil }
                }
                .navigationDestination(for: TVSearchRoute.self) { route in
                    switch route {
                    case .person(let id, let name): TVTimeline(query: TimelineQuery(personId: id), title: name)
                    case .city(let city): TVCityPage(city: city)
                    }
                }
        }
        .task {
            history.load(client: tv.client)
            await suggestions.load(tv.client)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let submitted {
            TVSearchResults(query: submitted).id(submitted)
        } else {
            TVSuggestionsView(text: text, suggestions: suggestions, history: history, run: run) { route in path.append(route) }
        }
    }

    private func submit() {
        var query = SearchQuery()
        query.text = text
        run(query)
    }

    /// Shows a search's results and remembers it: from the keyboard, a quick filter or a recent search.
    private func run(_ query: SearchQuery) {
        var query = query
        query.text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.text.isEmpty || !query.chips.isEmpty else { return }
        submitted = query
        text = query.text
        history.remember(query)
    }
}

/// The results of a search: its words, or the quick filter it was made with, as the grid.
struct TVSearchResults: View {
    let query: SearchQuery
    @Environment(TVModel.self) private var tv
    @State private var model: TVResultsModel?
    @State private var viewing: TVViewing?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TVPageTitle(query.text.isEmpty ? query.chips.joined(separator: ", ") : query.text, line: line)
            if let model { TVPhotos(content: .results(model)) { viewing = $0 } }
        }
        .modifier(TVViewerCover(viewing: $viewing))
        .environment(\.tvPhotoPage, model)
        .task {
            guard model == nil, let client = tv.client else { return }
            let query = query
            let made = TVResultsModel { page in
                try await client.advancedSearch(query, smartEnabled: true, page: ImmichClient.SearchPage(page: page))
            }
            model = made
            await made.loadMore()
        }
    }

    /// The filters beside the words, and how many photos came.
    private var line: String {
        let count = model.map { $0.items.isEmpty ? "" : itemCount($0.items.count, more: $0.hasMore) } ?? ""
        let filters = query.text.isEmpty ? "" : query.chips.joined(separator: ", ")
        return [filters, count].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The start page and what matches the typed words, as the iPhone's suggestions are laid out.
struct TVSuggestionsView: View {
    let text: String
    let suggestions: TVSuggestions
    let history: TVSearchHistory
    let run: (SearchQuery) -> Void
    let open: (TVSearchRoute) -> Void
    @Environment(TVModel.self) private var tv

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if typed.isEmpty { landing } else { matches }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .task(id: typed) { await suggestions.find(typed, client: tv.client) }
    }

    // MARK: Before typing

    @ViewBuilder
    private var landing: some View {
        // The quick filters, first and without a heading.
        chips {
            SearchChip(Text("Favorites"), systemImage: "heart") { run(with { $0.favorites = true }) }
            SearchChip(Text("Photos"), systemImage: "photo") { run(with { $0.mediaType = "IMAGE" }) }
            SearchChip(Text("Videos"), systemImage: "video") { run(with { $0.mediaType = "VIDEO" }) }
        }
        if !suggestions.people.isEmpty {
            section("People") { chips { ForEach(suggestions.people.prefix(12)) { personChip($0) } } }
        }
        if !suggestions.places.isEmpty {
            section("Places") { chips { ForEach(suggestions.places.prefix(12), id: \.self) { placeChip($0) } } }
        }
        if !history.entries.isEmpty {
            section("Recent Searches") { recentRows(Array(history.entries.prefix(6))) }
        }
    }

    // MARK: While typing

    @ViewBuilder
    private var matches: some View {
        Button { run(with { $0.text = typed }) } label: {
            Label { Text("Search for “\(typed)”") } icon: { Image(systemName: "magnifyingglass") }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        let people = foundPeople
        if !people.isEmpty {
            section("People") { chips { ForEach(people.prefix(12)) { personChip($0) } } }
        }
        let places = suggestions.places.filter { $0.localizedCaseInsensitiveContains(typed) }
        if !places.isEmpty {
            section("Places") { chips { ForEach(places.prefix(12), id: \.self) { placeChip($0) } } }
        }
        let recent = history.entries.filter { entry in
            ([entry.text] + entry.chips).contains { $0.localizedCaseInsensitiveContains(typed) }
        }
        if !recent.isEmpty {
            section("Recent Searches") { recentRows(Array(recent.prefix(6))) }
        }
    }

    /// Whom the server found by the typed name, or until it answers, the listed people the name matches.
    private var foundPeople: [Person] {
        if let found = suggestions.found, found.name == typed { return found.people }
        return suggestions.people.filter { $0.name.localizedCaseInsensitiveContains(typed) }
    }

    // MARK: Pieces

    private func personChip(_ person: Person) -> some View {
        SearchChip(title: Text(verbatim: person.name), action: { open(.person(id: person.id, name: person.name)) }) {
            if let pipeline = tv.images {
                PersonFaceImage(pipeline: pipeline, personID: person.id).frame(width: 56, height: 56)
            }
        }
    }

    private func placeChip(_ city: String) -> some View {
        SearchChip(Text(verbatim: city), systemImage: "mappin") { open(.city(city)) }
    }

    private func recentRows(_ entries: [SearchQuery]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                Button { run(entry) } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.text.isEmpty ? entry.chips.joined(separator: ", ") : entry.text).lineLimit(1)
                            if !entry.text.isEmpty && !entry.chips.isEmpty {
                                Text(verbatim: entry.chips.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The quick filter or the words, as a search of their own.
    private func with(_ change: (inout SearchQuery) -> Void) -> SearchQuery {
        var query = SearchQuery()
        change(&query)
        return query
    }

    private func chips<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        GlassEffectContainer(spacing: 16) {
            SearchChipFlow(spacing: 16) { content() }
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// A person's face as the iPhone's chips ask for it (Collections' `CollectionsFace`), which the TV has no collections
/// for: the shared person face.
struct CollectionsFace: View {
    let pipeline: ImagePipeline
    let personID: String

    var body: some View { PersonFaceImage(pipeline: pipeline, personID: personID) }
}

/// The people and places the suggestions are made from, read once per connection, and whom a typed name found.
@MainActor @Observable
final class TVSuggestions {
    /// The people Immich lists first, the named ones.
    private(set) var people: [Person] = []
    /// The places in the library, as Immich's explore lists them.
    private(set) var places: [String] = []
    /// Whom a typed name found on the server, and the name; nil before any name.
    private(set) var found: (name: String, people: [Person])?

    func load(_ client: ImmichClient?) async {
        guard let client else { return }
        if let page = try? await client.peoplePage(page: 1, withHidden: false) {
            people = page.people.filter { !$0.name.isEmpty }
        }
        // Explore lists places alone in Immich 3; only the fields searched exactly are offered, as on the iPhone.
        let groups = (try? await client.searchExplore()) ?? []
        places = groups.filter { $0.fieldName == "exifInfo.city" }.flatMap(\.items)
            .filter { $0.data.visibility != "locked" }.map(\.value)
    }

    /// Asks the server whom a name finds, a moment after typing stops.
    func find(_ name: String, client: ImmichClient?) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let client else { found = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let result = try await client.peoplePage(page: 1, withHidden: false, name: name)
            try Task.checkCancellation()
            found = (name, result.people.filter { !$0.name.isEmpty })
        } catch {}
    }
}

/// The recent searches, kept in the TV's defaults for each server. The shared core keeps them, as on the iPhone
/// (`recentSearchesRemembered`): the newest first, at most 20, the same search in another order once, and one with
/// neither words nor a filter never. The TV has one account, the key's, so no user in the key it keeps them under.
@MainActor @Observable
final class TVSearchHistory {
    private(set) var entries: [SearchQuery] = []
    private var key = ""
    @ObservationIgnored private var stored = ""

    func load(client: ImmichClient?) {
        guard let client else { return }
        key = recentSearchesKey(apiUrl: client.apiURL.absoluteString, userId: "apple-tv")
        show(recentSearchesRead(stored: UserDefaults.standard.data(forKey: key).map { String(decoding: $0, as: UTF8.self) } ?? ""))
    }

    func remember(_ query: SearchQuery) {
        guard !key.isEmpty, let search = try? JSONEncoder().encode(query) else { return }
        let remembered = recentSearchesRemembered(stored: stored, search: String(decoding: search, as: UTF8.self))
        guard remembered.stored != stored else { return }
        persist(remembered)
    }

    private func persist(_ recent: RecentSearches) {
        show(recent)
        UserDefaults.standard.set(Data(recent.stored.utf8), forKey: key)
    }

    private func show(_ recent: RecentSearches) {
        stored = recent.stored
        entries = recent.searches.compactMap { try? JSONDecoder().decode(SearchQuery.self, from: Data($0.utf8)) }
    }
}
