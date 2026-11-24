import Foundation

struct AlbumMember: Decodable, Sendable, Identifiable {
    let role: String
    let user: User
    var id: String { user.id }
}

struct AlbumDetails: Decodable, Sendable, Identifiable {
    let id: String
    let albumName: String
    let assetCount: Int
    let shared: Bool
    var description: String?
    var startDate: String?
    var endDate: String?
    var order: String?
    var isActivityEnabled: Bool?
    var albumUsers: [AlbumMember]?

    /// The owner is the member whose role says so.
    var albumOwner: User? { albumUsers?.first(where: { $0.role == "owner" })?.user }
    func isOwner(_ userID: String?) -> Bool { userID != nil && albumOwner?.id == userID }
    func canEdit(_ userID: String?) -> Bool {
        isOwner(userID) || albumUsers?.contains(where: { $0.id == userID && $0.role == "editor" }) == true
    }
}

struct AlbumUpdate: Encodable {
    var albumName: String?
    var description: String?
    var albumThumbnailAssetId: String?
    var order: String?
    var isActivityEnabled: Bool?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(albumName, forKey: .albumName)
        if let description {
            if description.isEmpty { try c.encodeNil(forKey: .description) }
            else { try c.encode(description, forKey: .description) }
        }
        try c.encodeIfPresent(albumThumbnailAssetId, forKey: .albumThumbnailAssetId)
        try c.encodeIfPresent(order, forKey: .order)
        try c.encodeIfPresent(isActivityEnabled, forKey: .isActivityEnabled)
    }
    private enum CodingKeys: String, CodingKey { case albumName, description, albumThumbnailAssetId, order, isActivityEnabled }
}

struct AlbumAssetResult: Decodable {
    let id: String
    let success: Bool
    var error: String?
}

struct AlbumActivity: Decodable, Sendable, Identifiable {
    let id: String
    let type: String
    let user: User
    let createdAt: String
    var assetId: String?
    var comment: String?
}

struct AlbumActivityStatistics: Decodable {
    let comments: Int
    let likes: Int
}
