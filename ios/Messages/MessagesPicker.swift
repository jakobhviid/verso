// What Verso shows in Messages (MessagesViewController), at the size Messages gives it. Compact, beneath the
// conversation: the library's newest photos, with Albums and Search, which ask for the expanded picker. Expanded,
// over the conversation: Recents, Favorites and Albums under the bar's segmented control, an album's photos pushed
// from its cover, and the search field in the bar, which searches the library by meaning where the server can. A tap
// on a photo puts a preview-sized copy into the message field, or its original where the Original toggle at the top
// says so, in both sizes. Messages gives an app one item in the field, so a tap's photo takes the place of the one
// before, and the expanded picker gives way to the compact one so the field shows. Signed out, it says to open Verso,
// with a button that does. Nothing fades or slides in as it loads.

import SwiftUI

struct MessagesPicker: View {
    let model: PickerModel

    var body: some View {
        content
            .alert("Can't Add the Photo", isPresented: problemShown) {
                Button("OK") { model.problem = nil }
            } message: {
                Text(model.problem ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .reading:
            Color.clear
        case .signedOut(let sessionEnded):
            SignedOutView(sessionEnded: sessionEnded) { model.openVerso() }
        case .signedIn(let library):
            if model.isExpanded {
                ExpandedPicker(model: model, library: library)
                    .id(ObjectIdentifier(library))
            } else {
                CompactPicker(model: model, library: library)
                    .id(ObjectIdentifier(library))
            }
        }
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { model.problem != nil }, set: { shown in if !shown { model.problem = nil } })
    }
}

/// Beneath the conversation: the newest photos, and the way to the rest.
private struct CompactPicker: View {
    let model: PickerModel
    let library: PickerLibrary

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Recents")
                    .font(.headline)
                Spacer()
                OriginalToggle(model: model)
                Button("Albums", systemImage: "rectangle.stack") {
                    model.section = .albums
                    model.expand(searching: false)
                }
                Button("Search", systemImage: "magnifyingglass") {
                    model.expand(searching: true)
                }
            }
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            PhotoGrid(feed: library.recents, model: model, thumbnails: library.thumbnails, emptyText: "No Photos")
        }
    }
}

/// Over the conversation: the sections, an album's photos, and search.
private struct ExpandedPicker: View {
    @Bindable var model: PickerModel
    let library: PickerLibrary
    @State private var query = ""
    @State private var searchFieldActive = false

    var body: some View {
        NavigationStack {
            shown
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Section", selection: $model.section) {
                            ForEach(PickerSection.allCases) { section in
                                Text(section.title).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        OriginalToggle(model: model)
                    }
                }
                .searchable(text: $query, isPresented: $searchFieldActive,
                            placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search Your Library"))
                .onSubmit(of: .search) {
                    Task { await library.search(for: query) }
                }
                .onChange(of: query) {
                    if query.isEmpty { library.clearSearch() }
                }
                .navigationDestination(for: Album.self) { album in
                    AlbumPhotos(album: album, model: model, library: library)
                }
        }
        .onAppear {
            if model.searchRequested {
                searchFieldActive = true
                model.searchRequested = false
            }
        }
    }

    /// The search's results while there is a search, else the section.
    @ViewBuilder
    private var shown: some View {
        if let search = library.search {
            PhotoGrid(feed: search, model: model, thumbnails: library.thumbnails, emptyText: "No Results")
                .id(ObjectIdentifier(search))
        } else {
            switch model.section {
            case .recents:
                PhotoGrid(feed: library.recents, model: model, thumbnails: library.thumbnails, emptyText: "No Photos")
            case .favorites:
                PhotoGrid(feed: library.favorites, model: model, thumbnails: library.thumbnails,
                          emptyText: "No Favorites")
            case .albums:
                AlbumsGrid(library: library)
            }
        }
    }
}

/// An album's photos, newest first, under its name.
private struct AlbumPhotos: View {
    let album: Album
    let model: PickerModel
    let library: PickerLibrary
    @State private var feed: PhotoFeed?

    var body: some View {
        Group {
            if let feed {
                PhotoGrid(feed: feed, model: model, thumbnails: library.thumbnails, emptyText: "No Photos")
            } else {
                Color.clear
            }
        }
        .navigationTitle(album.albumName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if feed == nil { feed = library.feed(for: album) }
        }
    }
}

/// Signed out: what to do, and a way to Verso to do it.
private struct SignedOutView: View {
    let sessionEnded: Bool
    let openVerso: () -> Void

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Verso"
    }

    var body: some View {
        ContentUnavailableView {
            Label(sessionEnded ? "Sign In Again" : "Not Signed In", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            if sessionEnded {
                Text("Your Immich server ended \(appName)'s sign-in. Open \(appName) and sign in again to send your photos here.")
            } else {
                Text("Open \(appName) and sign in to your Immich server to send its photos here.")
            }
        } actions: {
            Button("Open \(appName)", action: openVerso)
                .buttonStyle(.glassProminent)
        }
    }
}

/// Original: a tap sends the photo as it was taken, full size with its metadata, such as where it was taken, rather
/// than a copy sized for Messages. Lit while on.
private struct OriginalToggle: View {
    @Bindable var model: PickerModel

    var body: some View {
        Toggle(isOn: $model.sendsOriginals) {
            Label("Original", systemImage: "photo.badge.arrow.down")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
        }
        .toggleStyle(.button)
        .buttonBorderShape(.capsule)
        .font(.subheadline.weight(.semibold))
        .imageScale(.medium)
        .accessibilityHint(Text("Sends photos full size, with where they were taken."))
        .accessibilityIdentifier("picker.original")
    }
}
