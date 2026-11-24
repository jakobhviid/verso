// Memories, as the Mac's Memories shows them: cards of three photos each (MemoryCard), in the card sizes every card page
// shares (CardSize), two to a row on iPhone at the smallest and one from the next; a pinch goes through them, as do Zoom
// Out and Zoom In in View Options. Each opens out of its card into the memory's full-screen story (MemoryStory), which
// goes on to the next memory as one ends; its bookmark keeps it. A long press offers Keep, Show as Grid and Delete
// Memory, as the Mac's memory actions. Show as Grid, from the menu or from a story once it has closed, pushes the
// memory's photos (Route.photos over `.memory(id)`) onto the stack Memories is shown in.

import SwiftUI

struct MemoriesView: View {
    let session: LibrarySession
    @Environment(\.pushRoute) private var pushRoute
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(CardSize.key) private var cardSize = 0
    @State private var page = CardPageWidth()
    @State private var model: MemoriesModel
    /// The memory whose story plays.
    @State private var playing: ChosenMemory?
    /// A grid the story asked for, pushed once the story has closed.
    @State private var gridAfterStory: ChosenMemory?
    @State private var deleting: ChosenMemory?
    @State private var actionError: String?
    @Namespace private var zoomNamespace
    /// The memory whose story plays once the memories are read, as a memory card elsewhere opens it (Collections).
    private let openingID: String?
    @State private var opened = false

    init(session: LibrarySession, opening openingID: String? = nil) {
        self.session = session
        self.openingID = openingID
        _model = State(initialValue: MemoriesModel(session: session))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cardPageWidth($page, regular: horizontalSizeClass == .regular)
            .cardPageTitle(String(localized: "Memories"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        CardZoomControls(size: $cardSize, ladder: Self.ladder, page: cardPage)
                    } label: {
                        Label("View Options", systemImage: "line.3.horizontal.decrease")
                    }
                }
            }
            .fullScreenCover(item: $playing, onDismiss: showGridAfterStory) { chosen in
                MemoryStory(model: model, startID: chosen.id) { memory in
                    gridAfterStory = ChosenMemory(memory)
                }
                .navigationTransition(.zoom(sourceID: chosen.id, in: zoomNamespace))
            }
            .confirmationDialog("Delete This Memory?", isPresented: deletingShown, titleVisibility: .visible, presenting: deleting) { chosen in
                Button("Delete Memory", role: .destructive) { delete(chosen.id) }
            } message: { _ in
                Text("The photos in it stay in your library.")
            }
            .alert("Can't Change This Memory", isPresented: actionErrorShown) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .task(id: session.services.reconnections) {
                await model.load(reconnections: session.services.reconnections)
                if !opened, let openingID, let memory = model.memories.first(where: { $0.id == openingID }) {
                    opened = true
                    playing = ChosenMemory(memory)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .disabled:
            ContentUnavailableView("Memories Are Off", systemImage: "sparkles.rectangle.stack",
                                   description: Text("Memories are turned off in your Immich account's settings."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Load Memories", systemImage: "sparkles.rectangle.stack")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
            }
        case .loaded:
            if model.memories.isEmpty {
                ContentUnavailableView("No Memories Today", systemImage: "sparkles.rectangle.stack",
                                       description: Text("Immich makes memories of this day in earlier years."))
            } else {
                cards
            }
        }
    }

    /// The cards' sizes: two to a row on iPhone, then one; on iPad the Mac's widths.
    static let ladder = CardLadder(compactColumns: [2, 1, 1, 1, 1], widths: [240, 290, 350, 420, 500], spacing: 12)

    /// The width the cards share: the page's, less its margins.
    private var cardPage: CardPageWidth {
        CardPageWidth(width: max(0, page.width - 32), regular: page.regular)
    }

    private var cards: some View {
        let memories = model.memories
        return CardGrid(
            sections: [CardGridSection(id: "memories", count: memories.count)],
            card: { _, item, _ in AnyView(card(memories[item])) },
            footer: model.hasMore ? AnyView(loadingMore) : nil,
            ladder: Self.ladder, size: $cardSize, regular: horizontalSizeClass == .regular,
            contentKey: memories.map { "\($0.id)-\($0.isSaved == true)" }, top: 16,
            refresh: { await model.reload() })
    }

    /// Played by a tap on it rather than as a button, so the bookmark in its corner takes its own taps and a pinch
    /// changes the cards' size.
    private func card(_ memory: ExploreMemory) -> some View {
        MemoryCard(pipeline: session.pipeline, memory: memory) { keep in setKept(memory.id, keep) }
            .matchedTransitionSource(id: memory.id, in: zoomNamespace)
            .cardOpens { playing = ChosenMemory(memory) }
            .contextMenu { menu(memory) }
    }

    /// The next memories load as the end comes into view.
    private var loadingMore: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
            .onAppear { Task { await model.loadMore() } }
    }

    @ViewBuilder private func menu(_ memory: ExploreMemory) -> some View {
        let kept = memory.isSaved == true
        Button(kept ? "Don't Keep" : "Keep", systemImage: kept ? "bookmark.slash" : "bookmark") {
            setKept(memory.id, !kept)
        }
        Button("Show as Grid", systemImage: "square.grid.2x2") { showGrid(ChosenMemory(memory)) }
        Divider()
        Button("Delete Memory…", systemImage: "trash", role: .destructive) { deleting = ChosenMemory(memory) }
    }

    /// Pushes a memory's photos as a grid.
    private func showGrid(_ chosen: ChosenMemory) {
        pushRoute(.photos(.memory(chosen.id), title: chosen.title))
    }

    private func showGridAfterStory() {
        guard let chosen = gridAfterStory else { return }
        gridAfterStory = nil
        showGrid(chosen)
    }

    /// Keeps a memory or lets it go.
    private func setKept(_ id: String, _ keep: Bool) {
        Task {
            do { try await model.setKept(id, keep) }
            catch { report(error) }
        }
    }

    private func delete(_ id: String) {
        Task {
            do { try await model.delete(id) }
            catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        session.handle(error)
        actionError = error.localizedDescription
    }

    private var deletingShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { shown in if !shown { deleting = nil } })
    }

    private var actionErrorShown: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { shown in if !shown { actionError = nil } })
    }
}

/// A memory to play, delete or show as a grid, with the title its grid's page takes.
struct ChosenMemory: Identifiable, Hashable {
    let id: String
    let title: String

    init(_ memory: ExploreMemory) {
        id = memory.id
        title = memory.title
    }
}
