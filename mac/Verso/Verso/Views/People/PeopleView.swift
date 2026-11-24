import SwiftUI
import VersoCore

struct PeopleView: View {
    @Environment(LibrarySession.self) private var session
    @State private var people: [Person] = []
    @AppStorage(CardSize.key) private var cardSize = 0
    @State private var cardZoom = CardZoom()
    /// The people's tiles at each size.
    private static let cards = CardLayout(widths: [120, 150, 190, 240, 300], spacing: 16)
    // People: the Immich web app's favorite and hidden filters, as view options.
    @AppStorage("people.show") private var show = PeopleShow.all
    @AppStorage("people.includeHidden") private var includeHidden = false
    @State private var revision = 0
    @State private var page = 1
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var requestID = UUID()
    /// A new filter's first page replaces the people shown, instead of emptying the page first.
    @State private var replacing = false
    @State private var error: String?
    @State private var editing: Person?
    @State private var merging: Person?
    @State private var mergePair: (target: Person, source: Person)?

    var body: some View {
        Group {
            if people.isEmpty && isLoading {
                ProgressView().controlSize(.large)
            } else if people.isEmpty && filter.isFiltered && error == nil {
                ContentUnavailableView {
                    Label("No Matching People", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No people match the selected view options.")
                } actions: {
                    Button("Show All People") { show = .all; includeHidden = false }
                }
            } else if people.isEmpty {
                ContentUnavailableView("No People", systemImage: "person.crop.square",
                                       description: Text(error ?? String(localized: "People recognized by Immich appear here.")))
            } else {
                ScrollView {
                    LazyVGrid(columns: Self.cards.columns(cardSize), spacing: 20) {
                        ForEach(people) { person in
                            NavigationLink(value: person) { PersonCell(person: person) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Rename…") { editing = person }
                                    Button(person.isHidden ? "Unhide Person" : "Hide Person") {
                                        update(person, PersonEdit(isHidden: !person.isHidden))
                                    }
                                    Button("Merge…") { merging = person }
                                    Button(person.isFavorite == true ? "Unfavorite Person" : "Favorite Person") {
                                        update(person, PersonEdit(isFavorite: person.isFavorite != true))
                                    }
                                    Divider()
                                    CrosslinkMenuItems(item: .person(person.id)) // Crosslink
                                }
                                .onAppear { if person.id == people.last?.id { Task { await loadMore() } } }
                                .cardZoomItem(person.id)
                        }
                    }
                    .cardGrid(Self.cards)
                    .padding(20)
                }
                .cardZoom($cardSize, cardZoom)
                .fastWheelScrolling()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error {
                HStack {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") {
                        self.error = nil; hasMore = true
                        Task { await loadMore() }
                    }
                }.padding().background(.bar)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: error)
        .sheet(item: $editing) { person in
            PersonEditSheet(person: person) { _ in changed() }
        }
        .sheet(item: $merging) { person in
            PeoplePicker(title: "Merge into \(person.displayName)", excludedID: person.id) {
                mergePair = (person, $0)
            }
        }
        .confirmationDialog("Merge People?", isPresented: Binding(get: { mergePair != nil }, set: { if !$0 { mergePair = nil } }), titleVisibility: .visible) {
            Button("Merge", role: .destructive) {
                guard let pair = mergePair else { return }
                mergePair = nil
                Task {
                    do {
                        try await session.client.mergePeople(into: pair.target.id, ids: [pair.source.id])
                        changed()
                    } catch { session.handle(error); self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("All faces of \(mergePair?.source.displayName ?? "this person") will move to \(mergePair?.target.displayName ?? "the selected person"). This cannot be undone.")
        }
        .navigationTitle("People")
        .navigationDestination(for: Person.self) { person in
            // One page per person: the page keeps its person in its own state, and SwiftUI keeps a page while the
            // stack holds a value of its type in its place, so a link replacing one person with another would
            // otherwise go on showing the first.
            PersonDetailView(person: person).id(person.id)
        }
        .cardSizeCommands($cardSize, zoom: cardZoom)
        .pageToolbar("people") {
            ToolbarItem(id: "show", placement: .principal) {
                ToolbarModePicker(selection: $show, options: PeopleShow.allCases) { $0.title }
            }
            CardSizeToolbarItems(size: $cardSize, zoom: cardZoom)
            ToolbarItem(id: "viewOptions") { viewOptions }
        }
        .onReceive(NotificationCenter.default.publisher(for: .peopleChanged, object: session.services)) { _ in revision += 1 }
        // Read again when the server answers after it could not be reached.
        .task(id: "\(show.rawValue)-\(includeHidden)-\(revision)-\(session.services.reconnections)") {
            requestID = UUID(); isLoading = false
            replacing = !people.isEmpty; page = 1; hasMore = true; error = nil
            await loadMore()
        }
    }

    private var options: PeopleOptions { PeopleOptions(show: show, includeHidden: includeHidden) }
    private var filter: PeopleFilter { options.filter(server: session.version) }

    private var viewOptions: some View {
        Menu {
            Toggle("Include Hidden People", isOn: Binding(get: { filter.withHidden }, set: { includeHidden = $0 }))
                .disabled(show == .hidden)
        } label: {
            Label("View Options", systemImage: includeHidden && show != .hidden ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .menuIndicator(.hidden)
        .help("View Options")
    }

    private func changed() {
        session.invalidateGrids()
        NotificationCenter.default.post(name: .peopleChanged, object: session.services)
    }

    private func update(_ person: Person, _ edit: PersonEdit) {
        Task {
            do { _ = try await session.client.editPerson(person.id, edit); changed() }
            catch { session.handle(error); self.error = error.localizedDescription }
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        let currentRequest = requestID
        isLoading = true
        defer { if currentRequest == requestID { isLoading = false } }
        let options = options, filter = filter
        do {
            // A filtered page can come back empty in the app; keep going so the next one can load.
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
}

/// A person in the photos, as Verso draws one everywhere: a rounded square, the corner of the album and place tiles,
/// where an account is a circle (DESIGN.md, "The apps' interfaces").
struct PersonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        return RoundedRectangle(cornerRadius: min(10, max(4, side * 0.09)), style: .continuous).path(in: rect)
    }
}

/// A person's face, their name on it on a fade at its foot and their heart and hidden mark in its corner, as the cards
/// carry theirs (DESIGN.md, "The apps' interfaces").
struct PersonCell: View {
    @Environment(LibrarySession.self) private var session
    let person: Person
    /// Off in the person's own header and in the pickers, which show the name beside the face.
    var showsName = true
    @State private var image: CGImage?

    var body: some View {
        PersonShape()
            .fill(.quaternary)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .overlay(alignment: .bottom) { if showsName { nameOnPhoto } }
            .clipShape(PersonShape())
            .overlay(alignment: .topTrailing) { if showsName { marks } }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        .task(id: person.id) {
            let loaded = await session.pipeline.personThumbnail(person.id)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
        .onReceive(NotificationCenter.default.publisher(for: .personThumbnailChanged, object: session.services)) { notification in
            guard notification.userInfo?["personID"] as? String == person.id else { return }
            Task { image = await session.pipeline.personThumbnail(person.id) }
        }
    }

    /// The name on a fade at the face's foot; Add Name, dimmed, for someone unnamed.
    private var nameOnPhoto: some View {
        Text(person.name.isEmpty ? String(localized: "Add Name") : person.name)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(person.name.isEmpty ? 0.6 : 1))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.top, 20).padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }

    /// The heart and the hidden mark, on a dark plate as the grid's favorite badge is.
    @ViewBuilder private var marks: some View {
        if person.isFavorite == true || person.isHidden {
            HStack(spacing: 4) {
                if person.isFavorite == true { Image(systemName: "heart.fill").accessibilityLabel("Favorite") }
                if person.isHidden { Image(systemName: "eye.slash").accessibilityLabel("Hidden") }
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(3)
            .background(.black.opacity(0.45), in: .rect(cornerRadius: 4))
            .padding(6)
        }
    }
}
