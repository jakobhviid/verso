// The Search tab on iOS, the trailing tab with the search role (ROADMAP.md, M10), the root of the tab's stack. Before
// typing, suggestions as glass chips: quick filters, people with their faces, places, tags, and the recent searches
// (SearchHistory, as on the Mac); while typing, the suggestions that match; on Search, the results in place under the
// field: Immich's smart search, as the Mac's, or a search by its filters and mode once those are set
// (SearchFiltersSheet). A person, a place or a tag opens its page as a `Route` on the tab's stack. On a server without
// smart search, a search is by file name, as on the Mac (SearchQuery.clampMode).

import SwiftUI

struct SearchTabView: View {
    let session: LibrarySession
    @State private var text = ""
    @State private var searchActive = false
    @FocusState private var fieldFocused: Bool
    /// The filters, mode and order the next search uses: set in the filters sheet or by a suggestion.
    @State private var filters = SearchQuery()
    /// The search whose results show; nil while the suggestions show.
    @State private var submitted: SearchQuery?
    @State private var history = SearchHistory()
    @State private var suggestions = SearchSuggestionsModel()
    @State private var showingFilters = false
    /// Find's askings (⌘F) answered, so each opens the field once.
    @State private var findsAnswered = 0
    @Environment(LibraryChrome.self) private var chrome: LibraryChrome?
    @Environment(\.accountInTopBar) private var accountInTopBar

    var body: some View {
        content
            .navigationTitle("Search")
            .toolbar { toolbar }
            .searchable(text: $text, isPresented: $searchActive, prompt: prompt)
            .searchFocused($fieldFocused)
            .onSubmit(of: .search) { submit() }
            // Editing the text after a search goes back to the suggestions, until Search again.
            .onChange(of: text) { _, value in
                if let submitted, value != submitted.text { self.submitted = nil }
            }
            // Cancel ends the search: its text, filters and results go.
            .onChange(of: searchActive) { _, active in
                if !active { endSearch() }
            }
            .sheet(isPresented: $showingFilters) {
                SearchFiltersSheet(session: session, query: filtersForSheet, ratingsEnabled: suggestions.ratingsEnabled) { chosen in
                    filters = chosen
                    run(chosen)
                }
            }
            // Find (⌘F): the field, ready to type in.
            .onChange(of: chrome?.searchRequests ?? 0, initial: true) { _, requests in
                guard requests > findsAnswered else { return }
                findsAnswered = requests
                searchActive = true
                fieldFocused = true
            }
            .task(id: session.user?.id) { history.load(session: session) }
            .task(id: session.services.reconnections) { await suggestions.load(session) }
    }

    // MARK: What shows

    @ViewBuilder
    private var content: some View {
        if let submitted {
            let source = source(for: submitted)
            AssetGridPage(session: session, source: source, title: submitted.text.isEmpty ? String(localized: "Search") : submitted.text,
                          header: resultsHeader(submitted))
                .id(source)
        } else {
            SearchSuggestionsView(session: session, text: text, filters: filters, history: history, suggestions: suggestions,
                                  run: run, removeFilter: removeFilter, clearFilters: clearFilters)
        }
    }

    /// Over the results: the filters set, each to take off, and what a date order does to smart search.
    private func resultsHeader(_ query: SearchQuery) -> AnyView? {
        let smartDateOrder = query.mode == .context && session.features.smartSearch && !query.text.isEmpty && query.sort != .automatic
        guard !query.chips.isEmpty || smartDateOrder else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                if !query.chips.isEmpty {
                    SearchFilterChips(query: query, remove: removeFilter, clear: clearFilters)
                }
                if smartDateOrder {
                    Text("Showing up to the 500 most relevant smart search results, sorted by date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 8)
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let submitted {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort Results", selection: Binding(get: { submitted.sort }, set: { sort in
                        filters.sort = sort
                        var sorted = submitted
                        sorted.sort = sort
                        run(sorted)
                    })) {
                        ForEach(SearchSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort Results", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingFilters = true
            } label: {
                Label("Filters", systemImage: filters.chips.isEmpty ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }
        }
        AccountToolbarItems(session: session, chrome: chrome, shown: accountInTopBar)
    }

    /// The field's prompt says what it searches.
    private var prompt: Text {
        var mode = filters
        mode.clampMode(smartEnabled: session.features.smartSearch, ocrEnabled: session.features.ocr)
        switch mode.mode {
        case .context: return Text("Search photos")
        case .fileName: return Text("Search file names")
        case .description: return Text("Search descriptions")
        case .ocr: return Text("Search text in photos")
        }
    }

    // MARK: Searching

    /// The results' source: smart search for words alone, as the Mac searches them; the search by filters for anything
    /// more, or on a server without smart search.
    private func source(for query: SearchQuery) -> GridSource {
        if query.chips.isEmpty, query.mode == .context, query.sort == .automatic, session.features.smartSearch {
            return .search(query.text)
        }
        return .filteredSearch(query)
    }

    /// Search, from the keyboard: the field's words with the filters set.
    private func submit() {
        var query = filters
        query.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        run(query)
    }

    /// Shows a search's results and remembers it: from the field, a suggestion, a recent search or the filters.
    private func run(_ query: SearchQuery) {
        var query = query
        query.text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        query.clampMode(smartEnabled: session.features.smartSearch, ocrEnabled: session.features.ocr)
        guard !query.text.isEmpty || !query.chips.isEmpty else { return }
        var kept = query
        kept.text = ""
        filters = kept
        submitted = query
        text = query.text
        fieldFocused = false
        history.remember(query)
    }

    private func removeFilter(_ filter: SearchQuery.Filter) {
        filters.remove(filter)
        guard var query = submitted else { return }
        query.remove(filter)
        if query.text.isEmpty && query.chips.isEmpty { submitted = nil } else { run(query) }
    }

    private func clearFilters() {
        var cleared = SearchQuery()
        cleared.mode = filters.mode
        cleared.sort = filters.sort
        filters = cleared
        guard let query = submitted else { return }
        if query.text.isEmpty { submitted = nil } else {
            cleared.text = query.text
            run(cleared)
        }
    }

    private func endSearch() {
        submitted = nil
        text = ""
        var cleared = SearchQuery()
        cleared.mode = filters.mode
        filters = cleared
    }

    /// The filters sheet starts from the filters set, with the words in the field.
    private var filtersForSheet: SearchQuery {
        var query = filters
        query.text = text
        return query
    }
}
