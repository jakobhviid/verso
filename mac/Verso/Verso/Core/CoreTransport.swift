import Foundation
import Synchronization
import VersoCore

/// Immich's endpoint calls through the shared Rust core, for the app and its Finder extension (ARCHITECTURE.md,
/// "Verso on the Mac"). Each installs it once as it starts; the offline checks leave it out, so their URLProtocol
/// fixtures answer through the client's session.
enum CoreTransport {
    /// Once per process, however often it is called: the system makes the extension's object more than once.
    static func install() { _ = installed }

    private static let installed: Void = {
        startVersoCore()
        let connections = Connections()
        ImmichClient.core = { apiURL, credential in connections.connection(apiURL: apiURL, credential: credential) }
    }()
}

/// One core connection per API address, credential and certificate trusted for the server (ServerTrust), kept for the
/// process, so its connections to the server are used again; trusting another certificate, or forgetting one, makes
/// a new one, whose handshakes judge the server's certificate afresh.
private final class Connections: Sendable {
    private let open = Mutex<[String: CoreConnection]>([:])

    func connection(apiURL: URL, credential: Credential?) -> (any ImmichTransport)? {
        let (apiKey, sessionToken): (String?, String?) = switch credential {
        case .apiKey(let key): (key, nil)
        case .accessToken(let token): (nil, token)
        case nil: (nil, nil)
        }
        let certificate = ServerTrust.certificate(for: apiURL)
        let account = [apiURL.absoluteString, apiKey ?? "", sessionToken ?? ""].joined(separator: "\n")
        let key = account + "\n" + (certificate ?? "")
        return open.withLock { open -> CoreConnection? in
            if let kept = open[key] { return kept }
            guard let made = try? CoreConnection(apiURL: apiURL, apiKey: apiKey, sessionToken: sessionToken,
                                                 certificate: certificate) else { return nil }
            // The same account's connection trusting another certificate goes.
            open = open.filter { !$0.key.hasPrefix(account + "\n") }
            open[key] = made
            return made
        }
    }
}

extension CoreConnection: ImmichTransport {
    // The timeline, through immich-api's own calls when one of its scopes asks exactly what the query asks.

    func timeBuckets(_ query: TimelineQuery) async throws -> [TimeBucket]? {
        guard let call = TypedTimeline.call(for: query) else { return nil }
        let (source, settings) = call
        let months = try await asClientErrors { try await timelineMonths(source, settings) }
        return months.map { TimeBucket(timeBucket: $0.bucket, count: Int($0.count)) }
    }

    func timeBucket(_ bucket: String, _ query: TimelineQuery) async throws -> TimeBucketAssets? {
        guard let call = TypedTimeline.call(for: query) else { return nil }
        let (source, settings) = call
        let assets = try await asClientErrors { try await timelineMonth(source, settings, bucket: bucket) }
        return TypedTimeline.columns(assets, coordinates: settings.coordinates)
    }
}

extension CoreConnection {
    // Albums, through immich-api's own calls.

    func albums() async throws -> [Album]? {
        try await asClientErrors { try await galleryAlbums() }.map(TypedAlbums.album)
    }

    func albumDetails(_ id: String) async throws -> AlbumDetails? {
        TypedAlbums.details(try await asClientErrors { try await galleryAlbum(id: id) })
    }
}

extension CoreConnection {
    // People, through immich-api's own calls, when the page asks for nothing beyond what they know.

    func peoplePage(page: Int, size: Int, withHidden: Bool, name: String?, filters: [String: String]) async throws -> PeopleResponse? {
        guard Set(filters.keys).isSubset(of: ["isFavorite", "isHidden"]), filters.values.allSatisfy({ $0 == "true" }) else { return nil }
        let query = GalleryPeopleQuery(page: UInt32(page), size: UInt32(size), withHidden: withHidden, name: name,
                                       favoritesOnly: filters["isFavorite"] != nil, hiddenOnly: filters["isHidden"] != nil)
        let answer = try await asClientErrors { try await galleryPeoplePage(query) }
        return PeopleResponse(people: answer.people.map(TypedPeople.person), total: Int(answer.total), hasNextPage: answer.hasNextPage)
    }

    func person(_ id: String) async throws -> Person? {
        TypedPeople.person(try await asClientErrors { try await galleryPerson(id: id) })
    }

    func personStatistics(_ id: String) async throws -> PeopleStatistics? {
        PeopleStatistics(assets: Int(try await asClientErrors { try await galleryPersonStatistics(id: id) }))
    }
}

extension CoreConnection {
    // A photo's details, through immich-api's own call.

    func asset(_ id: String) async throws -> AssetResponse? {
        TypedAssets.asset(try await asClientErrors { try await galleryAsset(id: id) })
    }
}

/// The core's photos in the client's models, as Immich's JSON would have filled them.
enum TypedAssets {
    static func asset(_ asset: GalleryAsset) -> AssetResponse {
        AssetResponse(
            id: asset.id, ownerId: asset.ownerId, type: AssetType(rawValue: asset.kind) ?? .other,
            originalFileName: asset.originalFileName, originalMimeType: asset.originalMimeType,
            fileCreatedAt: asset.fileCreatedAt, localDateTime: asset.localDateTime, createdAt: asset.createdAt,
            isFavorite: asset.isFavorite, isTrashed: asset.isTrashed, visibility: asset.visibility,
            duration: asset.durationMs.map { MediaDuration(milliseconds: Int($0)) }, thumbhash: asset.thumbhash,
            livePhotoVideoId: asset.livePhotoVideoId, width: asset.width.map(Int.init), height: asset.height.map(Int.init),
            exifInfo: asset.exif.map(exif), people: asset.people.map { AssetPerson(id: $0.id, name: $0.name) },
            isEdited: asset.isEdited,
            stack: asset.stack.map { AssetsStackSummary(id: $0.id, primaryAssetId: $0.primaryAssetId, assetCount: Int($0.assetCount)) })
    }

    static func stack(_ stack: GalleryStackDetails) -> AssetsStack {
        AssetsStack(id: stack.id, primaryAssetId: stack.primaryAssetId, assets: stack.assets.map(asset))
    }

    static func exif(_ exif: GalleryExif) -> Exif {
        Exif(projectionType: exif.projectionType, make: exif.make, model: exif.model, lensModel: exif.lensModel,
             fNumber: exif.fNumber, focalLength: exif.focalLength, iso: exif.iso.map(Int.init), exposureTime: exif.exposureTime,
             orientation: exif.orientation, exifImageWidth: exif.imageWidth.map(Int.init),
             exifImageHeight: exif.imageHeight.map(Int.init), fileSizeInByte: exif.fileSize.map(Int64.init),
             latitude: exif.latitude, longitude: exif.longitude, city: exif.city, state: exif.state, country: exif.country,
             description: exif.description, dateTimeOriginal: exif.dateTimeOriginal, timeZone: exif.timeZone,
             rating: exif.rating.map(Int.init))
    }
}

extension CoreConnection {
    // Sharing, through immich-api's own calls.

    func sharedLinks() async throws -> [SharedLink]? {
        try await asClientErrors { try await gallerySharedLinks() }.map(TypedSharing.link)
    }

    func sharedLink(_ id: String) async throws -> SharedLink? {
        TypedSharing.link(try await asClientErrors { try await gallerySharedLink(id: id) })
    }

    func sharingPartners(direction: String) async throws -> [SharingPartner]? {
        try await asClientErrors { try await galleryPartners(direction: direction) }
            .map { SharingPartner(id: $0.id, name: $0.name, email: $0.email, inTimeline: $0.inTimeline) }
    }

    func users() async throws -> [User]? {
        try await asClientErrors { try await galleryUsers() }.map(TypedAlbums.user)
    }
}

extension CoreConnection {
    // Search, through immich-api's own call, with the request's every field.

    func search(_ request: AdvancedSearchRequest, smart: Bool) async throws -> SearchResponse.Assets? {
        let search = GallerySearch(
            query: request.query, originalFileName: request.originalFileName, description: request.description,
            ocr: request.ocr, personIds: request.personIds, tagIds: request.tagIds, country: request.country,
            state: request.state, city: request.city, make: request.make, model: request.model,
            lensModel: request.lensModel, takenAfter: request.takenAfter, takenBefore: request.takenBefore,
            kind: request.type, visibility: request.visibility, isFavorite: request.isFavorite,
            isNotInAlbum: request.isNotInAlbum, rating: request.rating.map(Int32.init), page: request.page.map(UInt32.init),
            cursor: request.cursor, size: UInt32(request.size), order: request.order, withExif: request.withExif,
            withStacked: request.withStacked)
        let page = try await asClientErrors { try await gallerySearch(search, smart: smart) }
        return SearchResponse.Assets(items: page.assets.map(TypedAssets.asset), nextPage: page.nextPage, nextCursor: page.nextCursor)
    }
}

extension CoreConnection {
    // Administration, through immich-api's own calls.

    func adminUsers() async throws -> [AdminUser]? {
        try await asClientErrors { try await galleryAdminUsers(withDeleted: true) }.map {
            AdminUser(id: $0.id, name: $0.name, email: $0.email, isAdmin: $0.isAdmin, deletedAt: $0.deletedAt, status: $0.status,
                      quotaSizeInBytes: $0.quotaSizeInBytes.map(Int64.init), quotaUsageInBytes: $0.quotaUsageInBytes.map(Int64.init),
                      shouldChangePassword: $0.shouldChangePassword)
        }
    }

    func adminLibraries() async throws -> [AdminLibrary]? {
        try await asClientErrors { try await galleryLibraries() }.map {
            AdminLibrary(id: $0.id, name: $0.name, ownerId: $0.ownerId, assetCount: Int($0.assetCount),
                         importPaths: $0.importPaths, exclusionPatterns: $0.exclusionPatterns)
        }
    }

    func adminQueues() async throws -> [AdminQueue]? {
        try await asClientErrors { try await galleryQueues() }.map {
            AdminQueue(name: $0.name, isPaused: $0.isPaused,
                       statistics: .init(active: Int($0.active), completed: Int($0.completed), delayed: Int($0.delayed),
                                         failed: Int($0.failed), paused: Int($0.paused), waiting: Int($0.waiting)))
        }
    }
}

extension CoreConnection {
    // Changes to photos, through immich-api's own calls.

    func updateAssets(_ ids: [String], _ changes: AssetChangeSet) async throws -> Bool {
        let typed = GalleryAssetChanges(
            favorite: changes.isFavorite, visibility: changes.visibility, dateTimeOriginal: changes.dateTimeOriginal,
            dateTimeRelative: changes.dateTimeRelative.map(Int64.init), timeZone: changes.timeZone, latitude: changes.latitude,
            longitude: changes.longitude, description: changes.description, rating: changes.rating.map(Int32.init),
            clearRating: changes.clearRating)
        try await asClientErrors { try await galleryUpdateAssets(ids, typed) }
        return true
    }

    func deleteAssets(_ ids: [String], force: Bool) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteAssets(ids, force: force) }
        return true
    }

    func restoreAssets(_ ids: [String]) async throws -> Bool {
        try await asClientErrors { try await galleryRestoreAssets(ids) }
        return true
    }
}

extension CoreConnection {
    // Changes to albums, through immich-api's own calls.

    func createAlbum(name: String, description: String?, assetIDs: [String]) async throws -> AlbumDetails? {
        TypedAlbums.details(try await asClientErrors { try await galleryCreateAlbum(name: name, description: description, assetIds: assetIDs) })
    }

    func updateAlbum(_ id: String, _ update: AlbumUpdate) async throws -> AlbumDetails? {
        let changes = GalleryAlbumChanges(name: update.albumName, description: update.description,
                                          thumbnailAssetId: update.albumThumbnailAssetId, order: update.order,
                                          activityEnabled: update.isActivityEnabled)
        return TypedAlbums.details(try await asClientErrors { try await galleryUpdateAlbum(id: id, changes) })
    }

    func deleteAlbum(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteAlbum(id: id) }
        return true
    }

    func changeAlbumAssets(_ id: String, ids: [String], removing: Bool) async throws -> [AlbumAssetResult]? {
        try await asClientErrors { try await galleryChangeAlbumAssets(id: id, assetIds: ids, removing: removing) }
            .map { AlbumAssetResult(id: $0.id, success: $0.success, error: $0.error) }
    }

    func addAlbumUser(_ id: String, userID: String, role: String) async throws -> Bool {
        try await asClientErrors { try await galleryAddAlbumMember(id: id, userId: userID, role: role) }
        return true
    }

    func updateAlbumUser(_ id: String, userID: String, role: String) async throws -> Bool {
        try await asClientErrors { try await galleryUpdateAlbumMember(id: id, userId: userID, role: role) }
        return true
    }

    func removeAlbumUser(_ id: String, userID: String) async throws -> Bool {
        try await asClientErrors { try await galleryRemoveAlbumMember(id: id, userId: userID) }
        return true
    }
}

extension CoreConnection {
    // Changes to people and faces, through immich-api's own calls.

    func createPerson(name: String) async throws -> Person? {
        TypedPeople.person(try await asClientErrors { try await galleryCreatePerson(name: name) })
    }

    func editPerson(_ id: String, _ edit: PersonEdit) async throws -> Person? {
        let changes = GalleryPersonChanges(name: edit.name, birthDate: edit.birthDate, clearBirthDate: edit.clearBirthDate,
                                           isHidden: edit.isHidden, isFavorite: edit.isFavorite,
                                           featureFaceAssetId: edit.featureFaceAssetId)
        return TypedPeople.person(try await asClientErrors { try await galleryUpdatePerson(id: id, changes) })
    }

    func mergePeople(into id: String, ids: [String]) async throws -> [PeopleOperationResult]? {
        try await asClientErrors { try await galleryMergePeople(id: id, mergedIds: ids) }
            .map { PeopleOperationResult(id: $0.id, success: $0.success, error: $0.error, errorMessage: nil) }
    }

    func reassignFace(_ faceID: String, to personID: String) async throws -> Person? {
        TypedPeople.person(try await asClientErrors { try await galleryReassignFace(faceId: faceID, personId: personID) })
    }

    func removeFace(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteFace(faceId: id) }
        return true
    }
}

extension CoreConnection {
    // Changes to shared links and partners, through immich-api's own calls.

    func createSharedLink(albumID: String?, assetIDs: [String], options: SharingOptions) async throws -> SharedLink? {
        TypedSharing.link(try await asClientErrors {
            try await galleryCreateSharedLink(albumId: albumID, assetIds: assetIDs, TypedSharing.options(options, keepPassword: false))
        })
    }

    func editSharedLink(_ id: String, options: SharingOptions, keepPassword: Bool) async throws -> SharedLink? {
        TypedSharing.link(try await asClientErrors {
            try await galleryUpdateSharedLink(id: id, TypedSharing.options(options, keepPassword: keepPassword))
        })
    }

    func deleteSharedLink(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteSharedLink(id: id) }
        return true
    }

    func changeSharedLinkAssets(_ id: String, assetIDs: [String], adding: Bool) async throws -> [AlbumAssetResult]? {
        try await asClientErrors { try await galleryChangeSharedLinkAssets(id: id, assetIds: assetIDs, removing: !adding) }
            .map { AlbumAssetResult(id: $0.id, success: $0.success, error: $0.error) }
    }

    func addSharingPartner(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryAddPartner(userId: id) }
        return true
    }

    func removeSharingPartner(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryRemovePartner(userId: id) }
        return true
    }

    func updateSharingPartner(_ id: String, inTimeline: Bool) async throws -> Bool {
        try await asClientErrors { try await gallerySetPartnerInTimeline(userId: id, inTimeline: inTimeline) }
        return true
    }
}

extension CoreConnection {
    // The server and the account, through immich-api's own calls.

    func serverVersion() async throws -> ServerVersion? {
        let version = try await asClientErrors { try await galleryServerVersion() }
        return ServerVersion(major: Int(version.major), minor: Int(version.minor), patch: Int(version.patch))
    }

    func serverFeatures() async throws -> ServerFeatures? {
        let typed = try await asClientErrors { try await galleryServerFeatures() }
        var features = ServerFeatures()
        features.ocr = typed.ocr
        features.duplicateDetection = typed.duplicateDetection
        features.smartSearch = typed.smartSearch
        features.facialRecognition = typed.facialRecognition
        features.map = typed.map
        features.trash = typed.trash
        features.passwordLogin = typed.passwordLogin
        features.oauth = typed.oauth
        return features
    }

    func currentUser() async throws -> User? {
        TypedAccount.user(try await asClientErrors { try await galleryMe() })
    }

    func exploreAuth() async throws -> ExploreAuthStatus? {
        let status = try await asClientErrors { try await galleryAuthStatus() }
        return ExploreAuthStatus(pinCode: status.pinCode, isElevated: status.isElevated, password: status.password,
                                 pinExpiresAt: status.pinExpiresAt)
    }
}

extension CoreConnection {
    // Explore's tags, map, folders, places and memories, through immich-api's own calls.

    func exploreTags() async throws -> [ExploreTag]? {
        try await asClientErrors { try await galleryTags() }
            .map { ExploreTag(id: $0.id, name: $0.name, value: $0.value, color: $0.color, parentId: $0.parentId) }
    }

    func exploreMarkers(favorites: Bool, archived: Bool, partners: Bool, after: Date?, before: Date?) async throws -> [ExploreMarker]? {
        let query = GalleryMapQuery(favoritesOnly: favorites, archived: archived, withPartners: partners,
                                    after: after.map { $0.ISO8601Format() }, before: before.map { $0.ISO8601Format() })
        return try await asClientErrors { try await galleryMapMarkers(query) }
            .map { ExploreMarker(id: $0.id, lat: $0.latitude, lon: $0.longitude, city: $0.city) }
    }

    func explorePaths() async throws -> [String]? {
        try await asClientErrors { try await galleryFolderPaths() }
    }

    func folderAssets(_ path: String) async throws -> [AssetResponse]? {
        try await asClientErrors { try await galleryFolderAssets(path: path) }.map(TypedAssets.asset)
    }

    func exploreCities() async throws -> [AssetResponse]? {
        try await asClientErrors { try await galleryCityAssets() }.map(TypedAssets.asset)
    }

    func exploreMemories(day: String, page: Int, size: Int) async throws -> [ExploreMemory]? {
        try await asClientErrors { try await galleryMemories(day: day, page: UInt32(page), size: UInt32(size)) }.map {
            ExploreMemory(id: $0.id, type: $0.kind, data: .init(year: Int($0.year), personName: $0.personName),
                          assets: $0.assets.map(TypedAssets.asset), seenAt: $0.seenAt, memoryAt: $0.memoryAt, isSaved: $0.isSaved)
        }
    }
}

extension CoreConnection {
    // What surrounds a photo, search's suggestions and Explore's groups, through immich-api's own calls.

    func assetsStack(_ id: String) async throws -> AssetsStack? {
        TypedAssets.stack(try await asClientErrors { try await galleryStack(id: id) })
    }

    func assetsDuplicates() async throws -> [AssetsDuplicate]? {
        try await asClientErrors { try await galleryDuplicates() }.map {
            AssetsDuplicate(duplicateId: $0.id, assets: $0.assets.map(TypedAssets.asset), suggestedKeepAssetIds: $0.suggestedKeepAssetIds)
        }
    }

    func faces(assetID: String) async throws -> [PeopleFace]? {
        try await asClientErrors { try await galleryFaces(assetId: assetID) }.map {
            PeopleFace(id: $0.id, imageWidth: Int($0.imageWidth), imageHeight: Int($0.imageHeight), boundingBoxX1: Int($0.left),
                       boundingBoxY1: Int($0.top), boundingBoxX2: Int($0.right), boundingBoxY2: Int($0.bottom),
                       person: $0.person.map(TypedPeople.person))
        }
    }

    func metadataEdits(_ id: String) async throws -> MetadataEdits? {
        MetadataEdits(edits: try await asClientErrors { try await galleryAssetEdits(id: id) }.map {
            MetadataEdit(action: $0.action, parameters: .init(angle: $0.angle.map(Int.init), axis: $0.axis, x: $0.x.map(Int.init),
                                                              y: $0.y.map(Int.init), width: $0.width.map(Int.init),
                                                              height: $0.height.map(Int.init)))
        })
    }

    func albumActivities(_ id: String, assetID: String?) async throws -> [AlbumActivity]? {
        try await asClientErrors { try await galleryActivities(albumId: id, assetId: assetID) }.map(TypedAlbums.activity)
    }

    func albumActivityStatistics(_ id: String, assetID: String?) async throws -> AlbumActivityStatistics? {
        let statistics = try await asClientErrors { try await galleryActivityStatistics(albumId: id, assetId: assetID) }
        return AlbumActivityStatistics(comments: Int(statistics.comments), likes: Int(statistics.likes))
    }

    func searchSuggestions(type: String, country: String?, state: String?, make: String?, model: String?) async throws -> [String]? {
        try await asClientErrors {
            try await gallerySuggestions(GallerySuggestionQuery(kind: type, country: country, state: state, cameraMake: make, cameraModel: model))
        }
    }

    func searchExplore() async throws -> [SearchExploreGroup]? {
        try await asClientErrors { try await galleryExplore() }.map { group in
            SearchExploreGroup(fieldName: group.fieldName, items: group.items.map { .init(value: $0.value, data: TypedAssets.asset($0.asset)) })
        }
    }

    /// The core answers the images' and the videos' extensions together, which is all the upload queue reads.
    func uploadMediaTypes() async throws -> UploadMediaTypes? {
        UploadMediaTypes(image: try await asClientErrors { try await galleryMediaTypes() }, video: [], sidecar: [])
    }
}

extension CoreConnection {
    // Changes to stacks, duplicates, tags, memories, edits, comments and the Locked Folder, through immich-api's own
    // calls.

    func assetsCreateStack(_ ids: [String]) async throws -> AssetsStack? {
        TypedAssets.stack(try await asClientErrors { try await galleryCreateStack(assetIds: ids) })
    }

    func assetsSetPrimary(stack: String, asset: String) async throws -> AssetsStack? {
        TypedAssets.stack(try await asClientErrors { try await gallerySetStackPrimary(id: stack, assetId: asset) })
    }

    func assetsUnstack(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteStack(id: id) }
        return true
    }

    func assetsRemoveFromStack(_ id: String, asset: String) async throws -> Bool {
        try await asClientErrors { try await galleryRemoveFromStack(id: id, assetId: asset) }
        return true
    }

    func assetsDismissDuplicate(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDismissDuplicates(id: id) }
        return true
    }

    func assetsResolveDuplicate(_ id: String, keep: [String], trash: [String]) async throws -> [AssetsBulkResult]? {
        try await asClientErrors { try await galleryResolveDuplicates(id: id, keep: keep, trash: trash) }
            .map { AssetsBulkResult(id: $0.id, success: $0.success, error: $0.error) }
    }

    func exploreCreateTag(_ path: String) async throws -> Bool {
        try await asClientErrors { try await galleryUpsertTag(path: path) }
        return true
    }

    func exploreUpdateTag(_ id: String, name: String, color: String) async throws -> Bool {
        try await asClientErrors { try await galleryUpdateTag(id: id, name: name, color: color) }
        return true
    }

    func exploreDeleteTag(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteTag(id: id) }
        return true
    }

    func exploreTagAssets(_ ids: [String], tag: String, remove: Bool) async throws -> [ExploreBulkResult]? {
        try await asClientErrors { try await galleryChangeTagAssets(id: tag, assetIds: ids, removing: remove) }
            .map { ExploreBulkResult(id: $0.id, success: $0.success, error: $0.error) }
    }

    func exploreSeenMemory(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryMarkMemorySeen(id: id) }
        return true
    }

    func exploreKeepMemory(_ id: String, keep: Bool) async throws -> Bool {
        try await asClientErrors { try await gallerySetMemorySaved(id: id, saved: keep) }
        return true
    }

    func exploreDeleteMemory(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteMemory(id: id) }
        return true
    }

    func exploreRemoveMemoryAsset(_ memory: String, asset: String) async throws -> [ExploreBulkResult]? {
        try await asClientErrors { try await galleryRemoveMemoryAssets(id: memory, assetIds: [asset]) }
            .map { ExploreBulkResult(id: $0.id, success: $0.success, error: $0.error) }
    }

    func exploreUnlock(_ pin: String, setup: Bool) async throws -> Bool {
        try await asClientErrors { try await galleryUnlockLockedFolder(pinCode: pin, setUp: setup) }
        return true
    }

    func exploreLock() async throws -> Bool {
        try await asClientErrors { try await galleryLockLockedFolder() }
        return true
    }

    func saveMetadataEdits(_ id: String, edits: [MetadataEdit]) async throws -> Bool {
        let steps = edits.map {
            GalleryEdit(action: $0.action, angle: $0.parameters.angle.map(Int32.init), axis: $0.parameters.axis,
                        x: $0.parameters.x.map(UInt32.init), y: $0.parameters.y.map(UInt32.init),
                        width: $0.parameters.width.map(UInt32.init), height: $0.parameters.height.map(UInt32.init))
        }
        try await asClientErrors { try await gallerySetAssetEdits(id: id, edits: steps) }
        return true
    }

    func createAlbumActivity(_ id: String, assetID: String?, comment: String?) async throws -> AlbumActivity? {
        TypedAlbums.activity(try await asClientErrors { try await galleryAddActivity(albumId: id, assetId: assetID, comment: comment) })
    }

    func deleteAlbumActivity(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteActivity(id: id) }
        return true
    }
}

extension CoreConnection {
    // The account's name, password, picture, keys, devices and notifications, through immich-api's own calls. Its
    // preferences go as requests: immich-api models the parts it acts on, and the app's models read more of them.

    func updateAccountName(_ name: String) async throws -> User? {
        TypedAccount.user(try await asClientErrors { try await galleryRenameAccount(name: name) })
    }

    func changeAccountPassword(current: String, new: String, invalidateSessions: Bool) async throws -> Bool {
        try await asClientErrors { try await galleryChangePassword(current: current, new: new, signOutOthers: invalidateSessions) }
        return true
    }

    func uploadAccountPicture(_ jpeg: Data) async throws -> Bool {
        try await asClientErrors { try await gallerySetProfilePicture(jpeg: jpeg) }
        return true
    }

    func removeAccountPicture() async throws -> Bool {
        try await asClientErrors { try await galleryRemoveProfilePicture() }
        return true
    }

    func accountKeys() async throws -> [AccountAPIKey]? {
        try await asClientErrors { try await galleryApiKeys() }.map(TypedAccount.key)
    }

    func createAccountKey(name: String, permissions: [String]) async throws -> AccountAPIKeySecret? {
        let made = try await asClientErrors { try await galleryCreateApiKey(name: name, permissions: permissions) }
        return AccountAPIKeySecret(secret: made.secret, apiKey: TypedAccount.key(made.key), id: made.key.id)
    }

    func renameAccountKey(id: String, name: String) async throws -> Bool {
        try await asClientErrors { try await galleryRenameApiKey(id: id, name: name) }
        return true
    }

    func deleteAccountKey(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteApiKey(id: id) }
        return true
    }

    func accountDevices() async throws -> [AccountDevice]? {
        try await asClientErrors { try await gallerySessions() }.map {
            AccountDevice(id: $0.id, current: $0.current, deviceOS: $0.deviceOs, deviceType: $0.deviceType, appVersion: $0.appVersion,
                          updatedAt: $0.updatedAt)
        }
    }

    func deleteAccountDevice(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteSession(id: id) }
        return true
    }

    func deleteOtherAccountDevices() async throws -> Bool {
        try await asClientErrors { try await galleryDeleteOtherSessions() }
        return true
    }

    func accountNotifications() async throws -> [AccountNotification]? {
        try await asClientErrors { try await galleryNotifications() }.map {
            AccountNotification(id: $0.id, title: $0.title, description: $0.description, level: $0.level, createdAt: $0.createdAt,
                                readAt: $0.readAt)
        }
    }

    func readAccountNotifications(_ ids: [String]) async throws -> Bool {
        try await asClientErrors { try await galleryMarkNotificationsRead(ids: ids) }
        return true
    }

    func deleteAccountNotification(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteNotification(id: id) }
        return true
    }
}

extension CoreConnection {
    // Administration's changes to accounts, libraries and job queues, through immich-api's own calls. Its server
    // settings, overview and a library's path check are shown as the server's JSON, so they go as requests.

    func adminSaveUser(id: String?, input: AdminUserInput) async throws -> Bool {
        let settings = GalleryAccountSettings(name: input.name, email: input.email, isAdmin: input.isAdmin, password: input.password ?? "",
                                              shouldChangePassword: input.shouldChangePassword,
                                              quotaSizeInBytes: input.quotaSizeInBytes.map(UInt64.init))
        if let id {
            try await asClientErrors { try await galleryUpdateAccount(id: id, settings) }
        } else {
            // A new account without a password is the server's to refuse, as before.
            guard input.password?.isEmpty == false else { return false }
            try await asClientErrors { try await galleryCreateAccount(settings) }
        }
        return true
    }

    func adminDeleteUser(_ id: String, force: Bool) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteAccount(id: id, force: force) }
        return true
    }

    func adminRestoreUser(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryRestoreAccount(id: id) }
        return true
    }

    func adminSaveLibrary(id: String?, input: AdminLibraryInput) async throws -> Bool {
        let settings = GalleryLibrarySettings(name: input.name, importPaths: input.importPaths, exclusionPatterns: input.exclusionPatterns)
        if let id {
            try await asClientErrors { try await galleryUpdateLibrary(id: id, settings) }
        } else {
            guard let owner = input.ownerId else { return false }
            try await asClientErrors { try await galleryCreateLibrary(ownerId: owner, settings) }
        }
        return true
    }

    func adminScanLibrary(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryScanLibrary(id: id) }
        return true
    }

    func adminDeleteLibrary(_ id: String) async throws -> Bool {
        try await asClientErrors { try await galleryDeleteLibrary(id: id) }
        return true
    }

    func adminQueueCommand(_ name: String, command: String, force: Bool?) async throws -> Bool {
        try await asClientErrors { try await galleryCommandQueue(name: name, command: command, force: force ?? false) }
        return true
    }
}

extension CoreConnection {
    // Signing in with a password and out again, through the core's sign-in. Finding the server stays the app's: it
    // reads `/.well-known/immich` and tries `http://` after `https://` for an address typed without one, which the
    // core's sign-in does not.

    func passwordSession(email: String, password: String) async throws -> String? {
        try await asClientErrors { try await gallerySignIn(email: email, password: password) }
    }

    func endSession() async -> Bool {
        await galleryEndSession()
        return true
    }

    func setReachable(_ reachable: Bool) -> Bool {
        gallerySetReachable(reachable)
        return true
    }

    func ping() async throws -> Bool {
        try await asClientErrors { try await galleryPing() }
        return true
    }
}

/// The core's account in the client's models.
enum TypedAccount {
    static func user(_ account: GalleryAccount) -> User {
        User(id: account.id, email: account.email, name: account.name, shouldChangePassword: account.shouldChangePassword,
             isAdmin: account.isAdmin, profileImagePath: account.profileImagePath, avatarColor: account.avatarColor,
             quotaUsageInBytes: account.quotaUsageInBytes.map(Int64.init), quotaSizeInBytes: account.quotaSizeInBytes.map(Int64.init))
    }

    static func key(_ key: GalleryApiKey) -> AccountAPIKey {
        AccountAPIKey(id: key.id, name: key.name, permissions: key.permissions, createdAt: key.createdAt)
    }
}

enum TypedSharing {
    /// The link editor's settings as the core takes them.
    static func options(_ options: SharingOptions, keepPassword: Bool) -> GallerySharingOptions {
        GallerySharingOptions(description: options.description, slug: options.slug, password: options.password,
                              keepPassword: keepPassword || options.keepPassword, expiresAt: options.expiresAt,
                              allowDownload: options.allowDownload, allowUpload: options.allowUpload,
                              showMetadata: options.showMetadata)
    }

    static func link(_ link: GallerySharedLink) -> SharedLink {
        SharedLink(id: link.id, key: link.key, type: link.kind, slug: link.slug, description: link.description,
                   expiresAt: link.expiresAt, password: link.password, allowDownload: link.allowDownload,
                   allowUpload: link.allowUpload, showMetadata: link.showMetadata, assets: link.assets.map(TypedAssets.asset),
                   album: link.album.map(TypedAlbums.album))
    }
}

enum TypedPeople {
    static func person(_ person: GalleryPerson) -> Person {
        Person(id: person.id, name: person.name, isHidden: person.isHidden, isFavorite: person.isFavorite, birthDate: person.birthDate)
    }
}

/// The core's albums in the client's models, as Immich's JSON would have filled them.
enum TypedAlbums {
    static func album(_ album: GalleryAlbum) -> Album {
        Album(id: album.id, albumName: album.name, albumThumbnailAssetId: album.thumbnailAssetId,
              assetCount: Int(album.assetCount), shared: album.shared, description: album.description,
              startDate: album.startDate, endDate: album.endDate,
              lastModifiedAssetTimestamp: album.lastModifiedAssetTimestamp, createdAt: album.createdAt,
              updatedAt: album.updatedAt, albumUsers: album.members.map(member))
    }

    static func details(_ album: GalleryAlbum) -> AlbumDetails {
        AlbumDetails(id: album.id, albumName: album.name, assetCount: Int(album.assetCount), shared: album.shared,
                     description: album.description, startDate: album.startDate, endDate: album.endDate,
                     order: album.order, isActivityEnabled: album.activityEnabled, albumUsers: album.members.map(member))
    }

    static func activity(_ activity: GalleryActivity) -> AlbumActivity {
        AlbumActivity(id: activity.id, type: activity.kind, user: user(activity.user), createdAt: activity.createdAt,
                      assetId: activity.assetId, comment: activity.comment)
    }

    static func member(_ member: GalleryAlbumMember) -> AlbumMember {
        AlbumMember(role: member.role, user: user(member.user))
    }

    /// Immich writes an empty path for no profile picture.
    static func user(_ user: GalleryUser) -> User {
        User(id: user.id, email: user.email, name: user.name, profileImagePath: user.profileImagePath ?? "",
             avatarColor: user.avatarColor)
    }
}

/// The core's refusals as the client's own errors, so the app handles a typed call's as it handles a request's: a
/// refused session signs out, an unreachable server is a URLError, a request the server turned down keeps its status
/// and reason.
private func asClientErrors<Value>(_ call: () async throws -> Value) async throws -> Value {
    do {
        return try await call()
    } catch let error as CoreError {
        switch error {
        case .signedOut: throw ImmichError.unauthorized(nil)
        case .notPermitted(let message): throw ImmichError.http(403, message)
        case .notFound: throw ImmichError.http(404, nil)
        case .unreachable(let message): throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: message])
        case .untrustedCertificate(let message, _): throw CoreError.certificateError(message, url: nil)
        case .refused(let status, let message): throw ImmichError.http(status, message)
        case .failed: throw error
        }
    }
}

/// Which typed call a timeline query is, and its answer in the client's columns.
enum TypedTimeline {
    /// The scope and settings that ask exactly what `query` asks; nil when none does (the map's area, for one), and
    /// the query goes as a request.
    static func call(for query: TimelineQuery) -> (TimelineSource, TimelineSettings)? {
        guard query.bbox == nil, query.order == nil || query.order == "asc" || query.order == "desc",
              query.orderBy == nil || query.orderBy == "createdAt", query.isTrashed != false, query.isFavorite != false
        else { return nil }
        var settings = TimelineSettings(favoritesOnly: false, oldestFirst: query.order == "asc",
                                        byDateAdded: query.orderBy == "createdAt", stacked: query.withStacked == true,
                                        coordinates: query.withCoordinates == true)
        let ids = [query.albumId, query.personId, query.userId, query.tagId].compactMap { $0 }
        let partners = query.withPartners == true
        guard ids.count <= 1, !partners || (ids.isEmpty && query.visibility == "timeline") else { return nil }
        let source: TimelineSource
        if query.isTrashed == true {
            guard query.visibility == nil, ids.isEmpty, query.isFavorite == nil else { return nil }
            source = .trash
        } else if let id = query.albumId {
            guard query.visibility == nil else { return nil }
            source = .album(id: id)
        } else if let id = query.tagId {
            guard query.visibility == nil else { return nil }
            source = .tag(id: id)
        } else if let id = query.personId {
            guard query.visibility == "timeline" else { return nil }
            source = .person(id: id)
        } else if let id = query.userId {
            guard query.visibility == "timeline" else { return nil }
            source = .partner(userId: id)
        } else if query.visibility == nil, query.isFavorite == true {
            return (.favorites, settings)
        } else if query.visibility == "archive" {
            source = .archive
        } else if query.visibility == "locked" {
            source = .locked
        } else if query.visibility == "timeline", partners {
            // The library as a gallery shows it: the scope has the stacks and the partners.
            guard settings.stacked else { return nil }
            settings.stacked = false
            source = .libraryStacked
        } else if query.visibility == "timeline" {
            source = .library
        } else {
            return nil
        }
        settings.favoritesOnly = query.isFavorite == true
        return (source, settings)
    }

    /// A month's Assets as the client's columns, which the grid reads.
    static func columns(_ assets: [TimelineAsset], coordinates: Bool) -> TimeBucketAssets {
        TimeBucketAssets(
            id: assets.map(\.id),
            isImage: assets.map(\.isImage),
            isFavorite: assets.map(\.isFavorite),
            isTrashed: assets.map(\.isTrashed),
            thumbhash: assets.map(\.thumbhash),
            ratio: assets.map(\.ratio),
            duration: assets.map { $0.durationMs.map { MediaDuration(milliseconds: Int($0)) } },
            fileCreatedAt: assets.map(\.fileCreatedAt),
            livePhotoVideoId: assets.map(\.livePhotoVideoId),
            visibility: assets.map(\.visibility),
            ownerId: assets.allSatisfy { $0.ownerId != nil } ? assets.map { $0.ownerId ?? "" } : nil,
            stack: assets.map { asset in asset.stackId.map { [$0, String(asset.stackCount ?? 0)] } },
            city: assets.map(\.city),
            country: assets.map(\.country),
            latitude: coordinates ? assets.map(\.latitude) : nil,
            longitude: coordinates ? assets.map(\.longitude) : nil)
    }
}

extension MediaDuration {
    init(milliseconds: Int) { self.milliseconds = milliseconds }
}
