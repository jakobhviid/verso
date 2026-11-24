import SwiftUI

struct ExploreMemoriesView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(PageNavigation.self) private var navigation
    @State private var memories: [ExploreMemory] = []
    @State private var error: String?
    @State private var page = 1
    @State private var hasMore = false
    @State private var busy = false
    @State private var deleting: ExploreMemory?
    @AppStorage(CardSize.key) private var cardSize = 0
    @State private var cardZoom = CardZoom()
    /// The memory cards at each size.
    private static let cards = CardLayout(widths: [240, 290, 350, 420, 500])
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Self.cards.columns(cardSize)) {
                ForEach(memories) { memory in
                    // Opened by a click on it rather than as a button, so the bookmark takes its own clicks.
                    MemoryCard(memory: memory) { keep in setKept(memory.id, keep) }
                    .contentShape(Rectangle())
                    .onTapGesture { open(memory.id) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { open(memory.id) }
                    .contextMenu {
                        Button(memory.isSaved == true ? "Don't Keep" : "Keep") { setKept(memory.id, memory.isSaved != true) }
                        Divider()
                        Button("Delete Memory…", role: .destructive) { deleting = memory }
                    }
                    .cardZoomItem(memory.id)
                }
            }
            .cardGrid(Self.cards)
            .padding()
            if hasMore { Button("Load More") { Task { await load() } }.disabled(busy) }
        }
        .cardZoom($cardSize, cardZoom)
        // A memory opens as a gallery, as an album does (MemoryDetailView).
        .navigationDestination(for: MemoryRoute.self) { MemoryDetailView(id: $0.id) }
        .cardSizeCommands($cardSize, zoom: cardZoom)
        .pageToolbar("memories") { CardSizeToolbarItems(size: $cardSize, zoom: cardZoom) }
        .task(id: session.services.reconnections) {
            memories = []; page = 1; hasMore = false
            do {
                let preferences = try await session.client.explorePreferences()
                guard preferences.memories?.enabled == true else { error = String(localized: "Memories are disabled in Immich Account Settings."); hasMore = false; return }
                await load()
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Delete Memory?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Memory", role: .destructive) {
                guard let memory = deleting else { return }
                Task {
                    do { try await session.client.exploreDeleteMemory(memory.id); withAnimation(.smooth(duration: 0.35)) { memories.removeAll { $0.id == memory.id } } }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("The photos in this memory are kept.") }
        .alert("Memories", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    /// Open a memory as a gallery; it is New until opened, as on Linux, and its page marks it seen on the server.
    private func open(_ id: String) {
        navigation.open(MemoryRoute(id: id))
        if let index = memories.firstIndex(where: { $0.id == id }), memories[index].seenAt == nil {
            memories[index].seenAt = Date().ISO8601Format()
        }
    }

    /// Keep a memory or let it go; the list may have changed meanwhile, so it is found again by its id.
    private func setKept(_ id: String, _ keep: Bool) {
        Task {
            do {
                try await session.client.exploreKeepMemory(id, keep: keep)
                if let index = memories.firstIndex(where: { $0.id == id }) { memories[index].isSaved = keep }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let batch = try await session.client.exploreMemories(page: page)
            memories.append(contentsOf: batch.map { memory in
                var visible = memory
                visible.assets.removeAll { $0.visibility == "locked" }
                return visible
            }.filter { !$0.assets.isEmpty })
            page += 1; hasMore = batch.count == 100
        } catch { self.error = error.localizedDescription }
    }
}

/// A memory as Linux shows it (ARCHITECTURE.md, "Verso on the Mac"): three of its photos, New until it is opened, the
/// day it recalls and how many, where most were taken and the named people in the most of them, and a bookmark that
/// keeps it, as Immich's cleanup removes a memory after 30 days unless it is kept.
struct MemoryCard: View {
    @Environment(LibrarySession.self) private var session
    let memory: ExploreMemory
    let keep: (Bool) -> Void

    var body: some View {
        photos
            .aspectRatio(1.4, contentMode: .fit)
            .overlay(alignment: .bottom) { foot }
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if memory.seenAt == nil {
                    Text("New").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                let kept = memory.isSaved == true
                Button { keep(!kept) } label: {
                    Image(systemName: kept ? "bookmark.fill" : "bookmark")
                        .font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help(kept ? "Kept: Immich won't remove it. Click to let it go." : "Keep: Immich removes a memory after 30 days unless it is kept.")
                .accessibilityLabel(kept ? "Kept" : "Keep")
            }
    }

    /// Its title, day and what it is about, on a fade at the photos' foot, as an album's card has its own.
    private var foot: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(memory.title).font(.headline).lineLimit(1)
            Text(dayLine).font(.caption).opacity(0.9).lineLimit(1)
            if let about { Text(about).font(.caption).opacity(0.85).lineLimit(1) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }

    /// One photo large beside two small, or the first alone.
    @ViewBuilder private var photos: some View {
        let ids = memory.assets.prefix(3).map(\.id)
        if ids.count >= 3 {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    RemoteThumbnail(pipeline: session.pipeline, assetID: ids[0], size: .preview)
                        .frame(width: geometry.size.width * 0.62)
                    VStack(spacing: 2) {
                        RemoteThumbnail(pipeline: session.pipeline, assetID: ids[1])
                        RemoteThumbnail(pipeline: session.pipeline, assetID: ids[2])
                    }
                }
            }
        } else {
            RemoteThumbnail(pipeline: session.pipeline, assetID: ids.first, size: .preview)
        }
    }

    /// The day it recalls, and how many.
    private var dayLine: String {
        let count = memory.assets.count == 1 ? String(localized: "1 photo") : String(localized: "\(memory.assets.count) photos")
        guard let day = memory.memoryAt.flatMap(ImmichDate.parse) else { return count }
        // Immich keeps the day as its UTC midnight, so it is read in UTC, or west of it shows the day before.
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return "\(day.formatted(style)) · \(count)"
    }

    /// Where most were taken and the named people in the most of them.
    private var about: String? {
        func mostCommon(_ values: [String], limit: Int) -> [String] {
            var counts: [String: Int] = [:]
            for value in values { counts[value, default: 0] += 1 }
            let ranked: [(name: String, count: Int)] = counts.map { (name: $0.key, count: $0.value) }
            let sorted = ranked.sorted { first, second in
                first.count != second.count ? first.count > second.count : first.name < second.name
            }
            return sorted.prefix(limit).map(\.name)
        }
        let place = mostCommon(memory.assets.compactMap { $0.exifInfo?.city }.filter { !$0.isEmpty }, limit: 1).first
        let people = mostCommon(memory.assets.flatMap { $0.people ?? [] }.map(\.name).filter { !$0.isEmpty }, limit: 3)
        let parts = [place, people.isEmpty ? nil : people.formatted(.list(type: .and))].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ExploreMemoryPlayer: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var memory: ExploreMemory
    let duration: Int
    /// Over the Memories page, closes it there; nil in a window of its own (a widget's memory), which closes.
    var close: (() -> Void)? = nil
    /// A photo taken out of the memory, for the page's card.
    var removed: ((String) -> Void)? = nil
    @State private var index = 0
    @State private var paused = false
    @State private var image: CGImage?
    /// Which photo `image` is, so the slides cross-fade by photo.
    @State private var imageID: String?
    @State private var error: String?
    private var asset: AssetResponse? { memory.assets.indices.contains(index) ? memory.assets[index] : nil }
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(.bottom, 80)
                    .id(imageID)
                    .transition(.opacity)
            }
            VStack {
                HStack {
                    Text(memory.title)
                    Spacer()
                    Button("Close") { if let close { close() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                HStack {
                    Button("Previous", systemImage: "backward.fill") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button(paused ? "Play" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") { paused.toggle() }.keyboardShortcut(.space, modifiers: [])
                    Button("Next", systemImage: "forward.fill") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Text("\(memory.assets.isEmpty ? 0 : index + 1) / \(memory.assets.count)")
                    Button("Remove from Memory") {
                        guard let asset else { return }
                        Task {
                            do {
                                try await session.client.exploreRemoveMemoryAsset(memory.id, asset: asset.id)
                                removed?(asset.id)
                                withAnimation(.smooth(duration: 0.3)) {
                                    memory.assets.removeAll { $0.id == asset.id }; index = min(index, max(0, memory.assets.count - 1))
                                }
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(asset == nil)
                }
            }.padding(24).foregroundStyle(.white)
        }
        .task { do { try await session.client.exploreSeenMemory(memory.id) } catch { self.error = error.localizedDescription } }
        .onChange(of: session.services.hiddenAssetIDs) {
            memory.assets.removeAll { session.services.hiddenAssetIDs.contains($0.id) }
            index = min(index, max(0, memory.assets.count - 1))
            image = nil
        }
        .task(id: "\(asset?.id ?? "")-\(session.metadata.imageRevision)") {
            // The previous photo stays until the next has loaded, then they cross-fade, without a black frame between.
            guard let asset else { image = nil; return }
            let loaded = await session.pipeline.thumbnail(asset.id, size: .preview)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { image = loaded; imageID = asset.id }
        }
        .task(id: "\(paused)-\(index)") {
            guard !paused else { return }
            do { try await Task.sleep(for: .seconds(duration)); if index + 1 < memory.assets.count { step(1) } else { paused = true } } catch {}
        }
        .alert("Memory", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    private func step(_ delta: Int) { index = min(max(index + delta, 0), max(memory.assets.count - 1, 0)) }
}
