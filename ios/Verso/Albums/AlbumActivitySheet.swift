// A shared album's comments and likes, as Immich keeps them and the Mac's activity panel shows them
// (mac/Verso/Verso/Views/Albums/AlbumActivityPanel.swift): opened from the album's header, in a sheet of its own. Each
// comment or like with whose it is, when, and the photo it is about; a field at the foot to comment, and the heart
// beside it that likes the album or takes the like back. One's own, and anything for the album's owner, is deleted
// with a swipe.

import SwiftUI

struct AlbumActivitySheet: View {
    let session: LibrarySession
    let album: AlbumDetails

    @Environment(\.dismiss) private var dismiss
    @State private var activities: [AlbumActivity] = []
    @State private var loaded = false
    @State private var comment = ""
    @State private var busy = false
    @State private var error: String?

    private var userID: String? { session.user?.id }

    /// The account's like of the album itself, which the heart takes back.
    private var ownLike: AlbumActivity? {
        activities.first { $0.type == "like" && $0.user.id == userID && $0.assetId == nil }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(activities) { activity in
                    row(activity)
                        .swipeActions {
                            if activity.user.id == userID || album.isOwner(userID) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    change { try await session.client.deleteAlbumActivity(activity.id) }
                                }
                            }
                        }
                }
            }
            .listStyle(.plain)
            .defaultScrollAnchor(.bottom)
            .overlay {
                if loaded && activities.isEmpty {
                    ContentUnavailableView("No Comments Yet", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Comments and likes on this album and its photos appear here."))
                } else if !loaded && error == nil {
                    ProgressView()
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Comments and Likes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .close) { dismiss() }
                }
            }
            .alert("Comments and Likes", isPresented: errorShown) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        .task { await load() }
    }

    /// Whose it is and when, the comment or the like, and the photo it is about.
    private func row(_ activity: AlbumActivity) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AlbumsMemberAvatar(user: activity.user, client: session.client, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: activity.user.name)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if let date = ImmichDate.parse(activity.createdAt) {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let text = activity.comment, !text.isEmpty {
                    Text(verbatim: text)
                        .font(.body)
                } else {
                    Label(activity.assetId == nil ? "Liked the album" : "Liked a photo", systemImage: "heart.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let assetID = activity.assetId {
                AlbumsThumbnail(pipeline: session.pipeline, assetID: assetID)
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The heart that likes the album, and the field to comment.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            let liked = ownLike != nil
            Button(liked ? "Unlike" : "Like", systemImage: liked ? "heart.fill" : "heart") {
                let like = ownLike
                change {
                    if let like {
                        try await session.client.deleteAlbumActivity(like.id)
                    } else {
                        _ = try await session.client.createAlbumActivity(album.id, assetID: nil, comment: nil)
                    }
                }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .foregroundStyle(liked ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            .frame(minHeight: 40)
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Add a Comment", text: $comment, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.vertical, 9)
                Button("Post", systemImage: "arrow.up.circle.fill") { post() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.bottom, 4)
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 20, style: .continuous))
        }
        .disabled(busy || !loaded)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })
    }

    private func post() {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        change {
            _ = try await session.client.createAlbumActivity(album.id, assetID: nil, comment: text)
            comment = ""
        }
    }

    private func load() async {
        do {
            activities = try await session.client.albumActivities(album.id, assetID: nil)
            loaded = true
        } catch is CancellationError {
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
            loaded = true
        }
    }

    /// A comment or a like made or taken back, then the list read again.
    private func change(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                await load()
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }
}
