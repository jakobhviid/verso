// The people Immich recognises, as the Mac's People shows them: faces in rounded squares with their names on them on a
// fade at the foot and the heart and hidden mark in the corner (DESIGN.md, "The apps' interfaces"), in the server's
// order, the favourites first, whom it shows decided by the shared core (`peopleShown`, as on the Mac and Linux). The
// faces come in the card sizes every card page shares (CardSize), three to a row on iPhone at the smallest and two from
// the next; a pinch goes through them, as do Zoom Out and Zoom In in View Options. A search over the names, hidden at
// rest above the top of the page and pulled down into view, as Albums' (CardGrid's `finder`), with a pull further
// reading the people again; Show Hidden People in View Options; and a long press for a person's menu: Rename, Favorite,
// Hide and Merge, as the Mac offers them. A person pushes their page (Route.person, PersonPage) onto the stack People
// is shown in.

import SwiftUI
import VersoCore

struct PeopleView: View {
    let session: LibrarySession
    /// Shows the hidden people beside the others, marked, as the Mac's view option does.
    @AppStorage("people.includeHidden") private var includeHidden = false
    @AppStorage(CardSize.key) private var cardSize = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.pushRoute) private var pushRoute
    @State private var pageWidth = CardPageWidth()
    @State private var people: [Person] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var requestID = UUID()
    /// A new view option's first page replaces the people shown, rather than emptying the page first.
    @State private var replacing = false
    @State private var error: String?
    @State private var revision = 0
    /// What the people shown were read for, so coming back from a person's page keeps the pages read.
    @State private var loadedKey: String?
    @State private var query = ""
    /// The search field has the keyboard.
    @State private var searching = false
    /// The people whose name matches the search, once Immich has answered; nil while not searching.
    @State private var found: [Person]?
    @State private var renaming: Person?
    @State private var mergeTarget: Person?
    @State private var mergePair: (target: Person, source: Person)?
    /// The pair chosen in the picker, asked about once the picker has closed.
    @State private var chosenPair: (target: Person, source: Person)?
    /// Why a change to a person failed.
    @State private var actionError: String?

    var body: some View {
        let shown = found ?? people
        CardGrid(
            sections: shown.isEmpty ? [] : [CardGridSection(id: "people", count: shown.count)],
            card: { _, item, size in
                let columns = Self.ladder.columns(size, width: cardPage.width, regular: cardPage.regular)
                return AnyView(tile(shown[item], large: columns <= 2))
            },
            finder: AnyView(PageSearchField(prompt: "Search People", text: $query, isFocused: $searching)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 14)),
            searching: searching || !query.isEmpty,
            footer: footer(shown),
            ladder: Self.ladder, size: $cardSize, regular: horizontalSizeClass == .regular,
            contentKey: shown,
            refresh: { if query.isEmpty { await reload() } else { await search() } })
        .cardPageWidth($pageWidth, regular: horizontalSizeClass == .regular)
        .cardPageTitle(String(localized: "People"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { viewOptions }
        }
        .personRenameAlert($renaming) { person, name in update(person, PersonEdit(name: name)) }
        .sheet(item: $mergeTarget, onDismiss: askToMerge) { target in
            PersonMergePicker(session: session, target: target) { source in chosenPair = (target, source) }
        }
        .alert("Merge People?", isPresented: mergeConfirmationShown) {
            Button("Cancel", role: .cancel) {}
            Button("Merge", role: .destructive) { merge() }
        } message: {
            Text("All faces of \(mergePair?.source.displayName ?? "this person") will move to \(mergePair?.target.displayName ?? "the person chosen"). This cannot be undone.")
        }
        .alert("Can't Change This Person", isPresented: actionErrorShown) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .versoPeopleChanged, object: session.services)) { _ in
            revision += 1
        }
        // Read again when a view option changes, a person changed, or the server answers after it could not be
        // reached.
        .task(id: "\(includeHidden)-\(revision)-\(session.services.reconnections)") {
            let key = "\(includeHidden)-\(revision)-\(session.services.reconnections)"
            guard key != loadedKey || (people.isEmpty && error == nil) else { return }
            loadedKey = key
            await reload()
        }
        .task(id: "\(query)-\(includeHidden)-\(revision)") { await search() }
    }

    // MARK: The page

    /// Under the faces: what the page says where it has none, or the next page loading as the end comes into view, or
    /// why it did not.
    private func footer(_ shown: [Person]) -> AnyView? {
        if shown.isEmpty {
            return AnyView(Group {
                if !query.isEmpty {
                    if found == nil { ProgressView() } else { ContentUnavailableView.search(text: query) }
                } else if isLoading || (hasMore && error == nil) {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView {
                        Label("Can't Load People", systemImage: "person.crop.square")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { revision += 1 }
                    }
                } else {
                    ContentUnavailableView("No People", systemImage: "person.crop.square",
                                           description: Text("The people Immich recognises in your photos appear here."))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48))
        }
        if found == nil && hasMore && error == nil {
            return AnyView(ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .onAppear { Task { await loadMore() } })
        }
        if found == nil, let error {
            return AnyView(VStack(spacing: 8) {
                Text(error).foregroundStyle(.secondary)
                Button("Try Again") {
                    self.error = nil
                    hasMore = true
                    Task { await loadMore() }
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12))
        }
        return nil
    }

    /// The faces' sizes: three to a row on iPhone, then two; on iPad the Mac's widths.
    static let ladder = CardLadder(compactColumns: [3, 3, 2, 2, 2], widths: [120, 150, 190, 240, 300], spacing: 10)

    /// The width the faces share: the page's, less its margins.
    private var cardPage: CardPageWidth {
        CardPageWidth(width: max(0, pageWidth.width - 32), regular: pageWidth.regular)
    }

    private func tile(_ person: Person, large: Bool) -> some View {
        PersonFaceTile(pipeline: session.pipeline, person: person, large: large)
            .cardOpens { pushRoute(.person(person)) }
            .contextMenu {
                Button(person.name.isEmpty ? "Add Name…" : "Rename…", systemImage: "pencil") { renaming = person }
                let favorite = person.isFavorite == true
                Button(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.slash" : "heart") {
                    update(person, PersonEdit(isFavorite: !favorite))
                }
                Button(person.isHidden ? "Show Person" : "Hide Person", systemImage: person.isHidden ? "eye" : "eye.slash") {
                    update(person, PersonEdit(isHidden: !person.isHidden))
                }
                Divider()
                Button("Merge…", systemImage: "person.2") { mergeTarget = person }
            } preview: {
                PersonFaceTile(pipeline: session.pipeline, person: person, large: true)
                    .frame(width: 240, height: 240)
            }
    }

    private var viewOptions: some View {
        Menu {
            CardZoomControls(size: $cardSize, ladder: Self.ladder, page: cardPage)
            Toggle("Show Hidden People", systemImage: "eye.slash", isOn: $includeHidden)
        } label: {
            Label("View Options", systemImage: includeHidden ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
    }

    // MARK: Loading

    private var options: PeopleOptions { PeopleOptions(show: .all, includeHidden: includeHidden) }

    /// The first page read again, replacing the people shown once it comes rather than emptying the page first.
    private func reload() async {
        requestID = UUID()
        isLoading = false
        replacing = !people.isEmpty
        page = 1
        hasMore = true
        error = nil
        await loadMore()
    }

    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        let currentRequest = requestID
        isLoading = true
        defer { if currentRequest == requestID { isLoading = false } }
        let options = options, filter = options.filter(server: session.version)
        do {
            // A page can come back with no one to show; the next one is read then.
            var added = 0
            repeat {
                let response = try await session.client.peoplePage(page: page, withHidden: filter.withHidden, filters: filter.query)
                try Task.checkCancellation()
                guard currentRequest == requestID else { return }
                let known = replacing ? [] : Set(people.map(\.id))
                let shown = options.shown(response.people).filter { !known.contains($0.id) }
                if replacing {
                    replacing = false
                    people = shown
                } else {
                    people += shown
                }
                added += shown.count
                hasMore = response.hasNextPage ?? (!response.people.isEmpty && page * 100 < response.total)
                page += 1
            } while added == 0 && hasMore
        } catch is CancellationError {
        } catch {
            guard currentRequest == requestID else { return }
            session.handle(error)
            self.error = error.localizedDescription
            hasMore = false
        }
    }

    /// The people whose name has a word starting with the search's text, as Immich's search finds them, a moment
    /// after the typing stops.
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            found = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let results: [Person] = try await session.client.get("search/person",
                                                                 query: ["name": text, "withHidden": String(includeHidden)])
            try Task.checkCancellation()
            found = options.shown(results)
        } catch is CancellationError {
        } catch {
            session.handle(error)
            found = []
        }
    }

    // MARK: Changes

    private var mergeConfirmationShown: Binding<Bool> {
        Binding(get: { mergePair != nil }, set: { shown in if !shown { mergePair = nil } })
    }

    private var actionErrorShown: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { shown in if !shown { actionError = nil } })
    }

    private func update(_ person: Person, _ edit: PersonEdit) {
        Task {
            do { _ = try await PersonEditing.save(edit, to: person.id, session: session) }
            catch {
                session.handle(error)
                actionError = error.localizedDescription
            }
        }
    }

    private func askToMerge() {
        mergePair = chosenPair
        chosenPair = nil
    }

    private func merge() {
        guard let pair = mergePair else { return }
        mergePair = nil
        Task {
            do { try await PersonEditing.merge(pair.source, into: pair.target, session: session) }
            catch {
                session.handle(error)
                actionError = error.localizedDescription
            }
        }
    }
}
