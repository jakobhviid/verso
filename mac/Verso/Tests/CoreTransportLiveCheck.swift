// The endpoint calls through the shared Rust core, live (ARCHITECTURE.md, "Verso on the Mac"): the client's own
// methods against a real server, each answer decoded by the client's models. Built and run on a Mac by check-core.sh,
// against IMMICH_URL with IMMICH_EMAIL and IMMICH_PASSWORD, Immich's public demo by default. It signs out at the end.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct CoreTransportLiveCheck {
    static func main() async throws {
        CoreTransport.install()
        let environment = ProcessInfo.processInfo.environment
        let server = URL(string: environment["IMMICH_URL"] ?? "https://demo.immich.app")!
        let email = environment["IMMICH_EMAIL"] ?? "demo@immich.app"
        let password = environment["IMMICH_PASSWORD"] ?? "demo"
        let anonymous = ImmichClient(serverURL: server, apiURL: server.appendingPathComponent("api"), credential: nil)

        let version = try await anonymous.serverVersion()
        // A password sign-in through the core's sign-in, and the session it answers with.
        let login = try await anonymous.login(email: email, password: password)
        let client = anonymous.with(credential: .accessToken(login))
        let user = try await client.currentUser()
        precondition(user.email == email, "signed in as \(user.email), not \(email)")
        // Query items, and the answers the grid is made of.
        let buckets = try await client.timeBuckets(TimelineQuery())
        precondition(!buckets.isEmpty, "the timeline has no months")
        let month = try await client.timeBucket(buckets[0].timeBucket, TimelineQuery())
        precondition(month.id.count == buckets[0].count, "\(buckets[0].timeBucket) lists \(month.id.count) of its \(buckets[0].count) photos")
        let albums = try await client.albums()
        let people = try await client.people(page: 1, size: 10)
        // Taken as unreachable, the core's requests fail at once, as the window's banner has them, and a ping still
        // asks; told it is back, they go out again.
        client.setServerReachable(false)
        let held = Date()
        do {
            _ = try await client.currentUser()
            preconditionFailure("a request went out while the server was taken as unreachable")
        } catch is URLError {}
        precondition(Date().timeIntervalSince(held) < 1, "a request waited while the server was taken as unreachable")
        try await client.pingServer()
        client.setServerReachable(true)
        _ = try await client.currentUser()

        // A refused credential is the client's own error: the server's 401 comes back as it came.
        do {
            _ = try await anonymous.with(credential: .accessToken("not-a-session")).currentUser()
            preconditionFailure("a session that does not exist was accepted")
        } catch ImmichError.unauthorized {}
        // No server at an address: a URLError, as URLSession gives, which the app shows as it did.
        do {
            let nowhere = URL(string: "http://127.0.0.1:9")!
            _ = try await ImmichClient(serverURL: nowhere, apiURL: nowhere.appendingPathComponent("api"), credential: nil).serverVersion()
            preconditionFailure("an address with no server answered")
        } catch is URLError {}

        // The timeline through immich-api's typed calls, against the same queries sent as requests: the same months,
        // and the same first month, column by column.
        var sources: [(String, TimelineQuery)] = [
            ("library", TimelineQuery(withPartners: true)),
            ("map", TimelineQuery(withPartners: false, withCoordinates: true)),
            ("favorites", TimelineQuery(visibility: nil, isFavorite: true)),
            ("archive", TimelineQuery(visibility: "archive")),
            ("trash", TimelineQuery(visibility: nil, isTrashed: true)),
            ("oldest first", TimelineQuery(withPartners: true, order: "asc")),
        ]
        if let album = albums.first { sources.append(("album", TimelineQuery(visibility: nil, albumId: album.id))) }
        if let person = people.people.first { sources.append(("person", TimelineQuery(personId: person.id))) }
        var compared: [String] = []
        for (name, query) in sources {
            precondition(TypedTimeline.call(for: query) != nil, "\(name) is not a typed call")
            let typed = try await client.timeBuckets(query)
            let sent: [TimeBucket] = try await client.get("timeline/buckets", query: query.parameters)
            precondition(typed.map { $0.timeBucket.prefix(7) } == sent.map { $0.timeBucket.prefix(7) }
                         && typed.map(\.count) == sent.map(\.count), "\(name): the months differ")
            guard let first = sent.first else {
                compared.append("\(name) (empty)")
                continue
            }
            let typedMonth = try await client.timeBucket(first.timeBucket, query)
            var parameters = query.parameters
            parameters["timeBucket"] = first.timeBucket
            let sentMonth: TimeBucketAssets = try await client.get("timeline/bucket", query: parameters)
            same(typedMonth, sentMonth, name)
            compared.append("\(name) (\(sent.count) months, \(sentMonth.id.count) in the first)")
        }

        // The albums through immich-api's typed calls, against the same albums as requests.
        let sentAlbums: [Album] = try await client.get("albums")
        let typedAlbums = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        precondition(Set(typedAlbums.keys) == Set(sentAlbums.map(\.id)), "the albums differ")
        for sent in sentAlbums { sameAlbum(typedAlbums[sent.id]!, sent) }
        for sent in sentAlbums.prefix(3) {
            let typed = try await client.albumDetails(sent.id)
            let asked: AlbumDetails = try await client.get("albums/\(sent.id)", query: ["withoutAssets": "true"])
            precondition(typed.albumName == asked.albumName && typed.assetCount == asked.assetCount
                         && typed.shared == asked.shared && typed.order == asked.order
                         && typed.isActivityEnabled == asked.isActivityEnabled
                         && (typed.description ?? "") == (asked.description ?? "")
                         && sameDate(typed.startDate, asked.startDate) && sameDate(typed.endDate, asked.endDate)
                         && members(typed.albumUsers) == members(asked.albumUsers), "album \(sent.id): its details differ")
        }

        // People through immich-api's typed calls, against the same pages as requests.
        let pages: [(String, Int, Bool, String?, [String: String])] = [
            ("the first page", 1, false, nil, [:]), ("the second page", 2, false, nil, [:]),
            ("with hidden ones", 1, true, nil, [:]), ("favorites", 1, true, nil, ["isFavorite": "true"]),
            ("hidden ones", 1, true, nil, ["isHidden": "true"]), ("by name", 1, true, "a", [:]),
        ]
        for (name, page, withHidden, search, filters) in pages {
            let typed = try await client.peoplePage(page: page, withHidden: withHidden, name: search, filters: filters)
            var query: [String: String?] = ["page": String(page), "size": "100", "withHidden": String(withHidden), "name": search]
            query.merge(filters.mapValues { Optional($0) }) { $1 }
            let sent: PeopleResponse = try await client.get("people", query: query)
            precondition(typed.total == sent.total && (typed.hasNextPage ?? false) == (sent.hasNextPage ?? false)
                         && typed.people.map(personText) == sent.people.map(personText), "people, \(name): typed and requested differ")
        }
        for sent in people.people.prefix(3) {
            let typed = try await client.person(sent.id)
            let asked: Person = try await client.get("people/\(sent.id)")
            let count = try await client.personStatistics(sent.id)
            let askedCount: PeopleStatistics = try await client.get("people/\(sent.id)/statistics")
            precondition(personText(typed) == personText(asked) && count.assets == askedCount.assets, "person \(sent.id) differs")
        }

        // A photo's details through immich-api's typed call, against the same photos as requests: thirty from the
        // library's first months, videos and Live Photos among them where there are.
        var photoIDs: [String] = []
        for bucket in buckets.prefix(6) where photoIDs.count < 30 {
            photoIDs += try await client.timeBucket(bucket.timeBucket, TimelineQuery(withPartners: true)).id
        }
        for id in photoIDs.prefix(30) {
            let typed = try await client.asset(id)
            let asked: AssetResponse = try await client.get("assets/\(id)")
            precondition(assetText(typed) == assetText(asked), "photo \(id): typed and requested differ\n\(assetText(typed))\n\(assetText(asked))")
        }

        // Sharing through immich-api's typed calls, against the same lists as requests.
        let typedLinks = try await client.sharedLinks()
        let sentLinks: [SharedLink] = try await client.get("shared-links")
        precondition(typedLinks.map(linkText) == sentLinks.map(linkText), "the shared links differ")
        for sent in sentLinks.prefix(3) {
            let typed = try await client.sharedLink(sent.id)
            let asked: SharedLink = try await client.get("shared-links/\(sent.id)")
            precondition(linkText(typed) == linkText(asked), "shared link \(sent.id) differs")
        }
        var partnerCount = 0
        for direction in ["shared-by", "shared-with"] {
            let typed = try await client.sharingPartners(direction: direction)
            let sent: [SharingPartner] = try await client.get("partners", query: ["direction": direction])
            func text(_ partner: SharingPartner) -> String { [partner.id, partner.name, partner.email, String(partner.inTimeline ?? false)].joined(separator: "|") }
            precondition(typed.map(text) == sent.map(text), "the partners \(direction) differ")
            partnerCount += sent.count
        }
        let typedUsers = try await client.sharingUsers()
        let sentUsers: [User] = try await client.get("users")
        func userText(_ user: User) -> String { [user.id, user.name, user.email, user.avatarColor ?? "", user.profileImagePath ?? ""].joined(separator: "|") }
        precondition(typedUsers.map(userText) == sentUsers.map(userText), "the users differ")

        // Search through immich-api's typed call, against the same requests sent as they are: the search panel's
        // filters, metadata search's own fields, and smart search where the server has it.
        var searches: [(String, AdvancedSearchRequest, Bool)] = []
        func search(_ name: String, smart: Bool = false, _ fill: (inout AdvancedSearchRequest) -> Void) {
            var body = AdvancedSearchRequest(size: 100)
            fill(&body)
            searches.append((name, body, smart))
        }
        search("by file name") { $0.originalFileName = "e"; $0.order = "desc"; $0.page = 1 }
        search("videos, oldest first") { $0.type = "VIDEO"; $0.order = "asc"; $0.page = 1 }
        search("favorites with EXIF and stacks") { $0.isFavorite = true; $0.withExif = true; $0.withStacked = true; $0.page = 1 }
        if let person = people.people.first { search("a person") { $0.personIds = [person.id]; $0.page = 1 } }
        search("taken in 2024") { $0.takenAfter = "2024-01-01T00:00:00Z"; $0.takenBefore = "2024-12-31T23:59:59.999Z"; $0.page = 1 }
        search("not in an album, second page") { $0.isNotInAlbum = true; $0.page = 2 }
        search("smart", smart: true) { $0.query = "mountain"; $0.page = 1 }
        var searched: [String] = []
        for (name, body, smart) in searches {
            let sent: SearchResponse
            do { sent = try await client.send("POST", smart ? "search/smart" : "search/metadata", body: body) }
            catch ImmichError.http(let status, _) where smart && (status == 400 || status == 404) {
                searched.append("\(name) (not on this server)")
                continue
            }
            let typed = try await client.searchPage(body, smart: smart)
            precondition(typed.items.map(assetText) == sent.assets.items.map(assetText)
                         && typed.nextPage == sent.assets.nextPage.flatMap({ $0.isEmpty ? nil : $0 })
                         && typed.nextCursor == sent.assets.nextCursor.flatMap({ $0.isEmpty ? nil : $0 }),
                         "search \(name): typed and requested differ")
            searched.append("\(name) (\(sent.assets.items.count))")
        }
        // Similar photos' page, as the view asked for it before it went through the typed search.
        struct SimilarBody: Encodable {
            let type = "IMAGE", visibility = "timeline", takenAfter: String, takenBefore: String, page: Int?, cursor: String?, size: Int
            let order = "asc", withStacked = true
        }
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let (after, before) = (Date(timeIntervalSince1970: 946_684_800), Date())
        let sentSimilar: SearchResponse = try await client.send("POST", "search/metadata", body: SimilarBody(
            takenAfter: after.formatted(format), takenBefore: before.formatted(format), page: 1, cursor: nil, size: 50))
        let typedSimilar = try await client.similarPhotosPage(takenAfter: after, takenBefore: before, page: .init(page: 1), size: 50)
        precondition(typedSimilar.items.map(assetText) == sentSimilar.assets.items.map(assetText), "similar photos' page differs")
        searched.append("similar photos' page (\(sentSimilar.assets.items.count))")

        // Administration through immich-api's typed calls, when the account is an administrator.
        var administration = "not an administrator here"
        do {
            let sentUsers: [AdminUser] = try await client.get("admin/users", query: ["withDeleted": "true"])
            let typedUsers = try await client.adminUsers()
            func text(_ user: AdminUser) -> String {
                [user.id, user.name, user.email, String(user.isAdmin), user.deletedAt.flatMap(ImmichDate.parse).map { "\($0)" } ?? "",
                 user.status ?? "", "\(user.quotaSizeInBytes ?? -1)", "\(user.quotaUsageInBytes ?? -1)",
                 String(user.shouldChangePassword ?? false)].joined(separator: "|")
            }
            precondition(typedUsers.map(text) == sentUsers.map(text), "the administrator's users differ")
            let sentLibraries: [AdminLibrary] = try await client.get("libraries")
            let typedLibraries = try await client.adminLibraries()
            precondition(typedLibraries.map { "\($0.id)|\($0.name)|\($0.ownerId)|\($0.assetCount)|\($0.importPaths)|\($0.exclusionPatterns)" }
                         == sentLibraries.map { "\($0.id)|\($0.name)|\($0.ownerId)|\($0.assetCount)|\($0.importPaths)|\($0.exclusionPatterns)" },
                         "the libraries differ")
            let sentQueues: [AdminQueue] = try await client.get("queues")
            let typedQueues = try await client.adminQueues()
            precondition(typedQueues.map { "\($0.name)|\($0.isPaused)" } == sentQueues.map { "\($0.name)|\($0.isPaused)" }, "the queues differ")
            administration = "\(sentUsers.count) users, \(sentLibraries.count) libraries, \(sentQueues.count) queues"
        } catch ImmichError.http(403, _) {}

        // The server, the account and Explore's reads: typed, and as requests.
        let sentVersion: ServerVersion = try await anonymous.get("server/version")
        let typedVersion = try await anonymous.serverVersion()
        precondition(typedVersion.description == sentVersion.description, "the version differs")
        let sentFeatures: ServerFeatures = try await anonymous.get("server/features")
        let typedFeatures = try await anonymous.serverFeatures()
        precondition(featuresText(typedFeatures) == featuresText(sentFeatures),
                     "the features differ: \(featuresText(typedFeatures)) against \(featuresText(sentFeatures))")
        let sentMe: User = try await client.get("users/me")
        let typedMe = try await client.currentUser()
        func accountText(_ user: User) -> String {
            [user.id, user.email, user.name, String(describing: user.shouldChangePassword), String(describing: user.isAdmin),
             user.profileImagePath ?? "", user.avatarColor ?? "", String(describing: user.quotaUsageInBytes),
             String(describing: user.quotaSizeInBytes)].joined(separator: "|")
        }
        precondition(accountText(typedMe) == accountText(sentMe), "the account differs: \(accountText(typedMe)) against \(accountText(sentMe))")
        let sentAuth: ExploreAuthStatus = try await client.get("auth/status")
        let typedAuth = try await client.exploreAuth()
        precondition(typedAuth.pinCode == sentAuth.pinCode && typedAuth.isElevated == sentAuth.isElevated
                     && typedAuth.password == sentAuth.password && sameDate(typedAuth.pinExpiresAt, sentAuth.pinExpiresAt),
                     "the sign-in status differs")
        let sentTags: [ExploreTag] = try await client.get("tags")
        let typedTags = try await client.exploreTags()
        precondition(typedTags == sentTags, "the tags differ")
        func markerText(_ markers: [ExploreMarker]) -> [String] { markers.map { "\($0.id)|\($0.lat)|\($0.lon)|\($0.city ?? "")" } }
        var markerCounts: [Int] = []
        for (favorites, archived, partners, after) in [(false, false, true, nil), (true, false, false, nil), (false, true, false, nil),
                                                        (false, false, false, Date(timeIntervalSince1970: 1_577_836_800))] as [(Bool, Bool, Bool, Date?)] {
            let sent: [ExploreMarker] = try await client.get("map/markers", query: [
                "isFavorite": favorites ? "true" : nil, "isArchived": archived ? "true" : nil, "withPartners": String(partners),
                "fileCreatedAfter": after.map { $0.ISO8601Format() }])
            let typed = try await client.exploreMarkers(favorites: favorites, archived: archived, partners: partners, after: after, before: nil)
            precondition(markerText(typed) == markerText(sent), "the map's markers differ (favorites \(favorites), archived \(archived))")
            markerCounts.append(sent.count)
        }
        let sentPaths: [String] = try await client.get("view/folder/unique-paths")
        let typedPaths = try await client.explorePaths()
        precondition(typedPaths == sentPaths, "the folders differ")
        var folderCount = 0
        if let path = sentPaths.first {
            let sentFolder: [AssetResponse] = try await client.get("view/folder", query: ["path": path])
            let typedFolder = try await client.exploreAssets(.folder(path), page: .init()).items
            precondition(typedFolder.map(assetText) == sentFolder.filter { $0.visibility != "locked" }.map(assetText),
                         "the folder's photos differ")
            folderCount = sentFolder.count
        }
        let sentCities: [AssetResponse] = try await client.get("search/cities")
        let typedCities = try await client.exploreCities()
        precondition(typedCities.map(assetText) == sentCities.map(assetText), "the cities differ")
        let today = String(Date().ISO8601Format().prefix(10))
        let sentMemories: [ExploreMemory] = try await client.get("memories", query: ["for": today, "page": "1", "size": "100",
                                                                                     "isTrashed": "false", "isUpcoming": "false"])
        let typedMemories = try await client.exploreMemories(page: 1)
        func memoryText(_ memory: ExploreMemory) -> String {
            ([memory.id, memory.type, String(memory.data.year), memory.data.personName ?? "",
              memory.seenAt.flatMap(ImmichDate.parse).map { "\($0)" } ?? "", memory.memoryAt.flatMap(ImmichDate.parse).map { "\($0)" } ?? "",
              String(describing: memory.isSaved)] + memory.assets.map(assetText)).joined(separator: "|")
        }
        precondition(typedMemories.map(memoryText) == sentMemories.map(memoryText), "the memories differ")
        // What surrounds a photo, search's suggestions and Explore's groups: typed, and as requests.
        let sentTypes: UploadMediaTypes = try await anonymous.get("server/media-types")
        let typedTypes = try await anonymous.uploadMediaTypes()
        precondition(typedTypes.extensions == sentTypes.extensions, "the media types differ")
        var suggested: [String] = []
        var narrowing = SearchQuery()
        for kind in ["country", "state", "city", "camera-make", "camera-model", "camera-lens-model"] {
            let sent: [String] = try await client.get("search/suggestions", query: ImmichClient.searchSuggestionParameters(kind, filters: narrowing))
            let typed = try await client.searchSuggestions(kind, filters: narrowing)
            precondition(typed == sent.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "the suggestions for \(kind) differ")
            suggested.append("\(sent.count) \(kind)")
            switch kind {
            case "country": narrowing.country = sent.first ?? ""
            case "state": narrowing.state = sent.first ?? ""
            case "camera-make": narrowing.make = sent.first ?? ""
            case "camera-model": narrowing.model = sent.first ?? ""
            default: break
            }
        }
        let sentExplore: [SearchExploreGroup] = try await client.get("search/explore")
        let typedExplore = try await client.searchExplore()
        func exploreText(_ groups: [SearchExploreGroup]) -> [String] {
            groups.map { ([$0.fieldName] + $0.items.map { $0.value + ":" + assetText($0.data) }).joined(separator: "|") }
        }
        precondition(exploreText(typedExplore) == exploreText(sentExplore), "Explore's groups differ")
        func faceText(_ face: PeopleFace) -> String {
            "\(face.id)|\(face.imageWidth)x\(face.imageHeight)|\(face.boundingBoxX1),\(face.boundingBoxY1),\(face.boundingBoxX2),"
                + "\(face.boundingBoxY2)|" + (face.person.map(personText) ?? "")
        }
        func editText(_ edits: MetadataEdits) -> [String] {
            edits.edits.map { "\($0.action)|\(String(describing: $0.parameters.angle))|\($0.parameters.axis ?? "")|"
                + "\(String(describing: $0.parameters.x)),\(String(describing: $0.parameters.y)),"
                + "\(String(describing: $0.parameters.width)),\(String(describing: $0.parameters.height))" }
        }
        var faceCount = 0
        // Photos of a person have faces, where the server finds them.
        var withFaces = Array(photoIDs.prefix(12))
        if let person = people.people.first {
            withFaces += try await client.metadataSearch(personIds: [person.id], page: .init(page: 1), size: 6).items.map(\.id)
        }
        for id in withFaces {
            let sentFaces: [PeopleFace] = try await client.get("faces", query: ["id": id])
            let typedFaces = try await client.faces(assetID: id)
            precondition(typedFaces.map(faceText) == sentFaces.map(faceText), "the faces on \(id) differ")
            faceCount += sentFaces.count
            let sentEdits: MetadataEdits = try await client.get("assets/\(id)/edits")
            let typedEdits = try await client.metadataEdits(id)
            precondition(editText(typedEdits) == editText(sentEdits), "the edits of \(id) differ")
        }
        var stackText = "no stack"
        findStack: for bucket in try await client.timeBuckets(TimelineQuery(withStacked: true)).prefix(12) {
            let columns = try await client.timeBucket(bucket.timeBucket, TimelineQuery(withStacked: true))
            for case let stack? in columns.stack ?? [] {
                let sentStack: AssetsStack = try await client.get("stacks/\(stack[0])")
                let typedStack = try await client.assetsStack(stack[0])
                precondition(typedStack.id == sentStack.id && typedStack.primaryAssetId == sentStack.primaryAssetId
                             && typedStack.assets.map(assetText) == sentStack.assets.map(assetText), "the stack \(stack[0]) differs")
                stackText = "a stack of \(sentStack.assets.count)"
                break findStack
            }
        }
        let sentDuplicates: [AssetsDuplicate] = try await client.get("duplicates")
        let typedDuplicates = try await client.assetsDuplicates()
        func duplicateText(_ groups: [AssetsDuplicate]) -> [String] {
            groups.map { ([$0.duplicateId, ($0.suggestedKeepAssetIds ?? []).joined(separator: ",")] + $0.assets.map(assetText)).joined(separator: "|") }
        }
        precondition(duplicateText(typedDuplicates) == duplicateText(sentDuplicates), "the duplicates differ")
        func activityText(_ activity: AlbumActivity) -> String {
            [activity.id, activity.type, activity.user.id, activity.user.name, ImmichDate.parse(activity.createdAt).map { "\($0)" } ?? "",
             activity.assetId ?? "", activity.comment ?? ""].joined(separator: "|")
        }
        var activityCount = 0
        for album in sentAlbums.filter(\.shared).prefix(3) {
            let sentActivities: [AlbumActivity] = try await client.get("activities", query: ["albumId": album.id])
            let typedActivities = try await client.albumActivities(album.id, assetID: nil)
            precondition(typedActivities.map(activityText) == sentActivities.map(activityText), "the comments in \(album.albumName) differ")
            let sentCounts: AlbumActivityStatistics = try await client.get("activities/statistics", query: ["albumId": album.id])
            let typedCounts = try await client.albumActivityStatistics(album.id, assetID: nil)
            precondition(typedCounts.comments == sentCounts.comments && typedCounts.likes == sentCounts.likes, "the counts in \(album.albumName) differ")
            if let assetID = sentActivities.compactMap(\.assetId).first {
                let sentOnPhoto: [AlbumActivity] = try await client.get("activities", query: ["albumId": album.id, "assetId": assetID])
                let typedOnPhoto = try await client.albumActivities(album.id, assetID: assetID)
                precondition(typedOnPhoto.map(activityText) == sentOnPhoto.map(activityText), "the comments on a photo in \(album.albumName) differ")
            }
            activityCount += sentActivities.count
        }
        // The account's keys, devices and notifications: typed, and as requests.
        func keyText(_ key: AccountAPIKey) -> String {
            [key.id, key.name, key.permissions.joined(separator: ","), key.createdAt.flatMap(ImmichDate.parse).map { "\($0)" } ?? ""]
                .joined(separator: "|")
        }
        func deviceText(_ device: AccountDevice) -> String {
            // The session asking is touched by each request, so its time is left out.
            [device.id, String(device.current), device.deviceOS, device.deviceType, device.appVersion ?? "",
             device.current ? "" : ImmichDate.parse(device.updatedAt).map { "\($0)" } ?? ""].joined(separator: "|")
        }
        func notificationText(_ notification: AccountNotification) -> String {
            [notification.id, notification.title, notification.description ?? "", notification.level,
             ImmichDate.parse(notification.createdAt).map { "\($0)" } ?? "",
             notification.readAt.flatMap(ImmichDate.parse).map { "\($0)" } ?? ""].joined(separator: "|")
        }
        let sentKeys: [AccountAPIKey] = try await client.get("api-keys")
        let typedKeys = try await client.accountKeys()
        precondition(typedKeys.map(keyText) == sentKeys.map(keyText), "the API keys differ")
        let sentDevices: [AccountDevice] = try await client.get("sessions")
        let typedDevices = try await client.accountDevices()
        precondition(Set(typedDevices.map(deviceText)) == Set(sentDevices.map(deviceText)), "the devices differ")
        let sentNotifications: [AccountNotification] = try await client.get("notifications")
        let typedNotifications = try await client.accountNotifications()
        precondition(typedNotifications.map(notificationText) == sentNotifications.map(notificationText), "the notifications differ")
        let accountRead = "\(sentKeys.count) API keys, \(sentDevices.count) devices, \(sentNotifications.count) notifications"

        let surroundings = "the media types, suggestions (" + suggested.joined(separator: ", ") + "), \(sentExplore.count) of Explore's groups, "
            + "\(faceCount) faces and the edits of \(withFaces.count) photos, \(stackText), \(sentDuplicates.count) duplicate groups, "
            + "\(activityCount) comments and likes in shared albums"
        let explored = "Immich \(typedVersion), its features, the account, the sign-in status, \(sentTags.count) tags, "
            + "the map's markers \(markerCounts.map(String.init).joined(separator: "/")), \(sentPaths.count) folders "
            + "(the first with \(folderCount) photos), \(sentCities.count) cities, \(sentMemories.count) memories"

        // Changes through immich-api's typed calls, only on a server that may be changed (IMMICH_WRITES=1, the lab):
        // each made typed, read back as a request, and put back as it was.
        var changes = "not asked for (IMMICH_WRITES=1, on a lab server)"
        if environment["IMMICH_WRITES"] == "1" {
            // A photo with a place, so the place can be put back as it was.
            var located = photoIDs.first!
            for id in photoIDs {
                let photo: AssetResponse = try await client.get("assets/\(id)")
                if photo.exifInfo?.latitude != nil { located = id; break }
            }
            changes = try await checkChanges(client, located)
            changes += "; " + (try await checkSharingChanges(client, server: server, me: user.id))
            changes += "; " + (try await checkMemories(client, located))
            changes += "; " + (try await checkPhotoSurroundings(client, password: password))
            changes += "; " + (try await checkAccountChanges(client, server: server))
            changes += "; " + (try await checkAdministration(client, me: user.id))
        }

        try await client.logout()
        do {
            _ = try await client.currentUser()
            preconditionFailure("the session still works after signing out")
        } catch ImmichError.unauthorized {}
        print("PASS the endpoint calls through the core: Immich \(version), \(user.email), \(buckets.count) months "
              + "(\(buckets[0].timeBucket): \(month.id.count) photos), \(albums.count) albums, \(people.total) people, "
              + "a refused session and an unreachable server reported as before, requests held while the server is taken as "
              + "unreachable and a ping let through, signed in and out through the core's sign-in")
        print("PASS the timeline's typed calls answer as its requests: " + compared.joined(separator: ", "))
        print("PASS the albums' typed calls answer as their requests: \(sentAlbums.count) albums, the first three's details")
        print("PASS the people's typed calls answer as their requests: \(pages.count) pages, three people and their counts")
        print("PASS a photo's typed details answer as its request: \(min(photoIDs.count, 30)) photos, field by field")
        print("PASS search's typed call answers as its requests: " + searched.joined(separator: ", "))
        print("PASS administration's typed calls answer as their requests: " + administration)
        print("PASS the server's, the account's and Explore's typed calls answer as their requests: " + explored)
        print("PASS the typed calls around a photo answer as their requests: " + surroundings)
        print("PASS the account's typed calls answer as their requests: " + accountRead)
        print("PASS changes through the typed calls read back as made: " + changes)
        print("PASS sharing's typed calls answer as their requests: \(sentLinks.count) shared links, \(partnerCount) partners, \(sentUsers.count) users")
    }

    /// A shared link as text to compare, its album and photos included.
    static func linkText(_ link: SharedLink) -> String {
        let fields: [String] = [
            link.id, link.key, link.type, link.slug ?? "", link.description ?? "", link.expiresAt.flatMap(ImmichDate.parse).map { "\($0)" } ?? "",
            link.password ?? "", String(link.allowDownload), String(link.allowUpload), String(link.showMetadata),
            link.album.map { [$0.id, $0.albumName, String($0.assetCount)].joined(separator: ",") } ?? "",
        ]
        return (fields + link.assets.map(assetText)).joined(separator: "|")
    }

    static func featuresText(_ features: ServerFeatures) -> String {
        [features.ocr, features.duplicateDetection ?? false, features.smartSearch, features.facialRecognition, features.map,
         features.trash, features.passwordLogin, features.oauth].map(String.init).joined(separator: ",")
    }

    /// A link's settings and its photos' ids: Immich answers a change with the photos but without their EXIF.
    static func linkSettings(_ link: SharedLink) -> String {
        linkText(SharedLink(id: link.id, key: link.key, type: link.type, slug: link.slug, description: link.description,
                            expiresAt: link.expiresAt, password: link.password, allowDownload: link.allowDownload,
                            allowUpload: link.allowUpload, showMetadata: link.showMetadata, assets: [], album: link.album))
            + "|" + link.assets.map(\.id).joined(separator: ",")
    }

    /// Changes to one photo, each read back as a request and put back.
    static func checkChanges(_ client: ImmichClient, _ id: String) async throws -> String {
        func read() async throws -> AssetResponse { try await client.get("assets/\(id)") }
        let before = try await read()
        try await client.setFavorite([id], !before.isFavorite)
        let favorited = try await read()
        precondition(favorited.isFavorite == !before.isFavorite, "the favorite did not change")
        try await client.setFavorite([id], before.isFavorite)
        try await client.setVisibility([id], "archive")
        let archived = try await read()
        precondition(archived.visibility == "archive", "the photo was not archived")
        try await client.setVisibility([id], before.visibility ?? "timeline")
        try await client.updateMetadata(MetadataUpdate(ids: [id], description: "Verso's check", rating: 4))
        let described = try await read()
        precondition(described.exifInfo?.description == "Verso's check" && described.exifInfo?.rating == 4, "the description or rating did not change")
        try await client.updateMetadata(MetadataUpdate(ids: [id], description: before.exifInfo?.description ?? "", clearRating: true))
        let cleared = try await read()
        precondition(cleared.exifInfo?.rating == before.exifInfo?.rating, "the rating did not clear")
        try await client.assetsSetLocation([id], latitude: 55.676, longitude: 12.568)
        let placed = try await read()
        precondition(abs((placed.exifInfo?.latitude ?? 0) - 55.676) < 0.001, "the place did not change")
        if let latitude = before.exifInfo?.latitude, let longitude = before.exifInfo?.longitude {
            try await client.assetsSetLocation([id], latitude: latitude, longitude: longitude)
        }
        try await client.delete([id], force: false)
        let trashed = try await read()
        precondition(trashed.isTrashed, "the photo did not go to the trash")
        try await client.restore([id])
        let restored = try await read()
        precondition(!restored.isTrashed, "the photo did not come back from the trash")
        return "favorite, archive, description and rating, place, trash and back, on photo \(id)"
    }

    /// Changes to albums, people and faces, shared links and partners, each made typed and read back as a request.
    /// What the check makes (an account to share with, an album, two people, a face, a link) it deletes again.
    static func checkSharingChanges(_ client: ImmichClient, server: URL, me: String) async throws -> String {
        var photos: [String] = []
        for bucket in try await client.timeBuckets(TimelineQuery()) where photos.count < 2 {
            photos += try await client.timeBucket(bucket.timeBucket, TimelineQuery()).id
        }
        precondition(photos.count >= 2, "the account has fewer than two photos")
        let email = "verso-check-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let password = UUID().uuidString
        try await client.adminSaveUser(id: nil, input: AdminUserInput(name: "Verso Check", email: email, isAdmin: false,
                                                                      password: password, shouldChangePassword: false))
        guard let other = try await client.adminUsers().first(where: { $0.email == email }) else {
            preconditionFailure("the account made for the check is not listed")
        }

        // An album: made, renamed, its photos and members changed, deleted.
        let album = try await client.createAlbum(name: "Verso check", description: "made by the check", assetIDs: [photos[0]])
        func readAlbum() async throws -> AlbumDetails { try await client.get("albums/\(album.id)", query: ["withoutAssets": "true"]) }
        var sentAlbum = try await readAlbum()
        precondition(sentAlbum.albumName == "Verso check" && sentAlbum.description == "made by the check" && sentAlbum.assetCount == 1,
                     "the album was not made as asked")
        _ = try await client.updateAlbum(album.id, AlbumUpdate(albumName: "Verso check, renamed", description: "", order: "asc",
                                                               isActivityEnabled: false))
        sentAlbum = try await readAlbum()
        precondition(sentAlbum.albumName == "Verso check, renamed" && (sentAlbum.description ?? "").isEmpty
                     && sentAlbum.order == "asc" && sentAlbum.isActivityEnabled == false, "the album's changes did not take")
        try await client.changeAlbumAssets(album.id, ids: [photos[1]])
        try await client.changeAlbumAssets(album.id, ids: [photos[1]])  // A duplicate is no failure.
        let added = try await readAlbum().assetCount
        precondition(added == 2, "the photo was not added to the album")
        try await client.changeAlbumAssets(album.id, ids: [photos[1]], removing: true)
        let takenOut = try await readAlbum().assetCount
        precondition(takenOut == 1, "the photo was not taken out of the album")
        try await client.addUploadToAlbum(photos[1], albumID: album.id)
        try await client.addUploadToAlbum(photos[1], albumID: album.id)  // Already there is no failure.
        let uploaded = try await readAlbum().assetCount
        precondition(uploaded == 2, "the upload was not added to the album")
        try await client.changeAlbumAssets(album.id, ids: [photos[1]], removing: true)
        func role() async throws -> String? { try await readAlbum().albumUsers?.first(where: { $0.user.id == other.id })?.role }
        try await client.addAlbumUser(album.id, userID: other.id, role: "viewer")
        let viewer = try await role()
        precondition(viewer == "viewer", "the album was not shared")
        // A comment on the album and a like on a photo, read typed and as requests, then deleted.
        _ = try await client.updateAlbum(album.id, AlbumUpdate(isActivityEnabled: true))
        let reopened = try await readAlbum()
        precondition(reopened.isActivityEnabled == true, "the album's comments were not switched on")
        let comment = try await client.createAlbumActivity(album.id, assetID: nil, comment: "Verso's check")
        let like = try await client.createAlbumActivity(album.id, assetID: photos[0], comment: nil)
        func activityText(_ activity: AlbumActivity) -> String {
            [activity.id, activity.type, activity.user.id, activity.user.name, activity.user.email,
             ImmichDate.parse(activity.createdAt).map { "\($0)" } ?? "", activity.assetId ?? "", activity.comment ?? ""].joined(separator: "|")
        }
        for assetID in [nil, photos[0]] as [String?] {
            let sentActivities: [AlbumActivity] = try await client.get("activities", query: ["albumId": album.id, "assetId": assetID])
            let typedActivities = try await client.albumActivities(album.id, assetID: assetID)
            precondition(typedActivities.map(activityText) == sentActivities.map(activityText), "the album's comments and likes differ")
            precondition(sentActivities.count == (assetID == nil ? 2 : 1), "the comment and the like are not listed")
            let sentCounts: AlbumActivityStatistics = try await client.get("activities/statistics", query: ["albumId": album.id, "assetId": assetID])
            let typedCounts = try await client.albumActivityStatistics(album.id, assetID: assetID)
            precondition(typedCounts.comments == sentCounts.comments && typedCounts.likes == sentCounts.likes, "the album's counts differ")
        }
        try await client.deleteAlbumActivity(comment.id)
        try await client.deleteAlbumActivity(like.id)
        try await client.updateAlbumUser(album.id, userID: other.id, role: "editor")
        let editor = try await role()
        precondition(editor == "editor", "the member's role did not change")
        try await client.removeAlbumUser(album.id, userID: other.id)
        let removed = try await role()
        precondition(removed == nil, "the member was not removed")
        try await client.deleteAlbum(album.id)
        do {
            _ = try await readAlbum()
            preconditionFailure("the album was not deleted")
        } catch ImmichError.http(404, _) {} catch ImmichError.http(400, _) {}

        // People: made, changed, a face given and taken back, merged.
        let kept = try await client.createPerson(name: "Verso check A")
        let merged = try await client.createPerson(name: "Verso check B")
        func readPerson(_ id: String) async throws -> Person { try await client.get("people/\(id)") }
        _ = try await client.editPerson(kept.id, PersonEdit(name: "Verso check A, renamed", birthDate: "1990-04-23", isFavorite: true))
        var sentPerson = try await readPerson(kept.id)
        precondition(sentPerson.name == "Verso check A, renamed" && sentPerson.birthDate == "1990-04-23" && sentPerson.isFavorite == true,
                     "the person's changes did not take")
        _ = try await client.editPerson(kept.id, PersonEdit(clearBirthDate: true))
        sentPerson = try await readPerson(kept.id)
        precondition(sentPerson.birthDate == nil && sentPerson.name == "Verso check A, renamed", "the birth date was not cleared")
        struct NewFace: Encodable {
            let assetId: String, personId: String, imageWidth: Int, imageHeight: Int, x: Int, y: Int, width: Int, height: Int
        }
        try await client.send("POST", "faces", body: NewFace(assetId: photos[0], personId: kept.id, imageWidth: 100, imageHeight: 100,
                                                             x: 10, y: 10, width: 20, height: 20))
        guard let face = try await client.faces(assetID: photos[0]).first(where: { $0.person?.id == kept.id }) else {
            preconditionFailure("the face made for the check is not listed")
        }
        let given = try await client.reassignFace(face.id, to: merged.id)
        precondition(given.id == merged.id, "the face's new person is \(given.id), not \(merged.id)")
        let moved = try await client.faces(assetID: photos[0]).first(where: { $0.id == face.id })
        precondition(moved?.person?.id == merged.id, "the face did not move to the other person")
        try await client.removeFace(face.id)
        let facesLeft = try await client.faces(assetID: photos[0])
        precondition(facesLeft.allSatisfy { $0.id != face.id }, "the face was not removed")
        try await client.mergePeople(into: kept.id, ids: [merged.id])
        do {
            _ = try await readPerson(merged.id)
            preconditionFailure("the merged person is still there")
        } catch ImmichError.http(404, _) {} catch ImmichError.http(400, _) {}
        struct PersonIDs: Encodable { let ids: [String] }
        try await client.send("DELETE", "people", body: PersonIDs(ids: [kept.id]))

        // A link to chosen photos: made with a password, changed keeping it, its photos changed, deleted.
        let made = try await client.createSharedLink(albumID: nil, assetIDs: [photos[0]],
                                                     options: SharingOptions(description: "Verso check", password: "check", allowDownload: false))
        func readLink() async throws -> SharedLink { try await client.get("shared-links/\(made.id)") }
        var sentLink = try await readLink()
        precondition(linkSettings(made) == linkSettings(sentLink), "the link made differs from the link read")
        precondition(sentLink.type == "INDIVIDUAL" && sentLink.description == "Verso check" && !sentLink.allowDownload
                     && sentLink.password == "check", "the link was not made as asked")
        let expiry = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: 86_400))
        let changed = try await client.editSharedLink(made.id, options: SharingOptions(description: "Verso check, changed", slug: "verso-\(made.id.prefix(8))",
                                                                                      expiresAt: expiry), keepPassword: true)
        sentLink = try await readLink()
        precondition(linkSettings(changed) == linkSettings(sentLink), "the link changed differs from the link read")
        precondition(sentLink.description == "Verso check, changed" && sentLink.slug == "verso-\(made.id.prefix(8))"
                     && sentLink.expiresAt != nil && sentLink.password == "check" && sentLink.allowDownload,
                     "the link's changes did not take, or its password went")
        try await client.changeSharedLinkAssets(made.id, assetIDs: [photos[1]], adding: true)
        let linked = try await readLink().assets.count
        precondition(linked == 2, "the photo was not added to the link")
        try await client.changeSharedLinkAssets(made.id, assetIDs: [photos[1]], adding: false)
        let unlinked = try await readLink().assets.count
        precondition(unlinked == 1, "the photo was not taken out of the link")
        _ = try await client.editSharedLink(made.id, options: SharingOptions(description: "Verso check, changed"))
        sentLink = try await readLink()
        precondition(sentLink.password == nil && sentLink.slug == nil && sentLink.expiresAt == nil, "the link's password, slug or expiry stayed")
        try await client.deleteSharedLink(made.id)
        do {
            _ = try await readLink()
            preconditionFailure("the link was not deleted")
        } catch ImmichError.http(404, _) {} catch ImmichError.http(400, _) {}

        // Partners: shared with the other account and back; their photos on this timeline, and off; unshared.
        try await client.addSharingPartner(other.id)
        func sharedBy() async throws -> [SharingPartner] { try await client.get("partners", query: ["direction": "shared-by"]) }
        let sharing = try await sharedBy()
        precondition(sharing.contains { $0.id == other.id }, "the library was not shared")
        let login = try await ImmichClient(serverURL: server, apiURL: server.appendingPathComponent("api"), credential: nil)
            .login(email: email, password: password)
        let otherClient = client.with(credential: .accessToken(login))
        try await otherClient.addSharingPartner(me)
        func inTimeline() async throws -> Bool? {
            let partners: [SharingPartner] = try await client.get("partners", query: ["direction": "shared-with"])
            return partners.first(where: { $0.id == other.id })?.inTimeline
        }
        try await client.updateSharingPartner(other.id, inTimeline: true)
        let shown = try await inTimeline()
        precondition(shown == true, "the partner's photos are not on the timeline")
        try await client.updateSharingPartner(other.id, inTimeline: false)
        let hidden = try await inTimeline()
        precondition(hidden == false, "the partner's photos are still on the timeline")
        try await client.removeSharingPartner(other.id)
        let unshared = try await sharedBy()
        precondition(unshared.allSatisfy { $0.id != other.id }, "the library is still shared")
        try await otherClient.logout()
        try await client.adminDeleteUser(other.id, force: true)
        return "an album made, changed, shared, commented on and liked, and deleted, two people changed and merged, a face moved and removed, "
            + "a link made, changed and deleted, a partner added, shown and removed"
    }

    /// Changes to an account, on one made for the check and deleted at its end: its name, password and picture, an
    /// API key, its devices and a notification, each made typed and read back as a request.
    static func checkAccountChanges(_ client: ImmichClient, server: URL) async throws -> String {
        let email = "verso-check-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let password = UUID().uuidString
        try await client.adminSaveUser(id: nil, input: AdminUserInput(name: "Verso Check", email: email, isAdmin: false,
                                                                      password: password, shouldChangePassword: false))
        guard let made = try await client.adminUsers().first(where: { $0.email == email }) else {
            preconditionFailure("the account made for the check is not listed")
        }
        let anonymous = ImmichClient(serverURL: server, apiURL: server.appendingPathComponent("api"), credential: nil)
        func signIn(_ password: String) async throws -> ImmichClient {
            anonymous.with(credential: .accessToken(try await anonymous.login(email: email, password: password)))
        }
        let account = try await signIn(password)
        func me() async throws -> User { try await account.get("users/me") }

        // The name, the password, the picture.
        let renamed = try await account.updateAccountName("Verso Check, renamed")
        let named = try await me()
        precondition(renamed.name == "Verso Check, renamed" && named.name == renamed.name, "the account was not renamed")
        let newPassword = UUID().uuidString
        try await account.changeAccountPassword(current: password, new: newPassword, invalidateSessions: false)
        let again = try await signIn(newPassword)
        do {
            _ = try await signIn(password)
            preconditionFailure("the old password still signs in")
        } catch {
            precondition(error.localizedDescription == "Wrong email or password.", "the old password's refusal: \(error.localizedDescription)")
        }
        try await account.uploadAccountPicture(tinyJPEG())
        let pictured = try await me()
        precondition(!(pictured.profileImagePath ?? "").isEmpty, "the picture was not set")
        try await account.removeAccountPicture()
        let unpictured = try await me()
        precondition((unpictured.profileImagePath ?? "").isEmpty, "the picture was not removed")

        // An API key: made, listed, renamed, deleted.
        let key = try await account.createAccountKey(name: "Verso check", permissions: ["asset.read"])
        guard let keyID = key.apiKey?.id ?? key.id, !key.secret.isEmpty else { preconditionFailure("the key came without its id or secret") }
        func keys() async throws -> [AccountAPIKey] { try await account.get("api-keys") }
        try await account.renameAccountKey(id: keyID, name: "Verso check, renamed")
        let renamedKeys = try await keys()
        precondition(renamedKeys.first(where: { $0.id == keyID })?.name == "Verso check, renamed", "the key was not renamed")
        let typedKeys = try await account.accountKeys()
        precondition(typedKeys.map(\.id) == renamedKeys.map(\.id) && typedKeys.map(\.permissions) == renamedKeys.map(\.permissions),
                     "the keys differ")
        try await account.deleteAccountKey(keyID)
        let keysLeft = try await keys()
        precondition(!keysLeft.contains { $0.id == keyID }, "the key was not deleted")

        // Devices: three signed in, one signed out, then every other.
        let third = try await signIn(newPassword)
        func devices() async throws -> [AccountDevice] { try await account.get("sessions") }
        let signedIn = try await devices()
        let typedDevices = try await account.accountDevices()
        precondition(Set(typedDevices.map(\.id)) == Set(signedIn.map(\.id)) && signedIn.count >= 3, "the devices differ")
        guard let other = signedIn.first(where: { !$0.current }) else { preconditionFailure("no other device is listed") }
        try await account.deleteAccountDevice(other.id)
        let fewer = try await devices()
        precondition(!fewer.contains { $0.id == other.id }, "the device was not signed out")
        try await account.deleteOtherAccountDevices()
        let alone = try await devices()
        precondition(alone.count == 1 && alone[0].current, "the other devices were not signed out")
        _ = (again, third)

        // A notification from the administrator: listed, read, deleted.
        struct NewNotification: Encodable { let userId: String, title = "Verso check", description = "made by the check" }
        try await client.send("POST", "admin/notifications", body: NewNotification(userId: made.id))
        func notifications() async throws -> [AccountNotification] { try await account.get("notifications") }
        let sent = try await notifications()
        let typed = try await account.accountNotifications()
        guard let notification = sent.first(where: { $0.title == "Verso check" }) else { preconditionFailure("the notification did not arrive") }
        precondition(typed.map(\.id) == sent.map(\.id) && typed.map(\.readAt) == sent.map(\.readAt), "the notifications differ")
        try await account.readAccountNotifications([notification.id])
        let read = try await notifications()
        precondition(read.first(where: { $0.id == notification.id })?.readAt != nil, "the notification was not read")
        try await account.deleteAccountNotification(notification.id)
        let unnotified = try await notifications()
        precondition(!unnotified.contains { $0.id == notification.id }, "the notification was not deleted")

        try await account.logout()
        try await client.adminDeleteUser(made.id, force: true)
        return "an account renamed, its password changed, a picture set and removed, a key made, renamed and deleted, "
            + "devices signed out, a notification read and deleted"
    }

    /// Administration's changes, each made typed and read back as a request: an account made, changed, deleted and
    /// restored, then deleted for good; an external library made, changed, scanned and deleted; a job queue paused,
    /// resumed, emptied and started.
    static func checkAdministration(_ client: ImmichClient, me: String) async throws -> String {
        let email = "verso-check-\(UUID().uuidString.prefix(8).lowercased())@example.com"
        var input = AdminUserInput(name: "Verso Check", email: email, isAdmin: false, password: UUID().uuidString, shouldChangePassword: false)
        try await client.adminSaveUser(id: nil, input: input)
        func account() async throws -> AdminUser? {
            let users: [AdminUser] = try await client.get("admin/users", query: ["withDeleted": "true"])
            return users.first { $0.email == email }
        }
        guard let made = try await account() else { preconditionFailure("the account was not made") }
        input.name = "Verso Check, edited"
        input.password = nil
        input.shouldChangePassword = true
        input.quotaSizeInBytes = 1 << 30
        try await client.adminSaveUser(id: made.id, input: input)
        let edited = try await account()
        precondition(edited?.name == "Verso Check, edited" && edited?.shouldChangePassword == true && edited?.quotaSizeInBytes == 1 << 30,
                     "the account's changes did not take")
        input.quotaSizeInBytes = nil
        try await client.adminSaveUser(id: made.id, input: input)
        let unlimited = try await account()
        precondition(unlimited?.quotaSizeInBytes == nil, "the quota was not removed")
        try await client.adminDeleteUser(made.id, force: false)
        let deleted = try await account()
        precondition(deleted?.isDeleted == true, "the account was not deleted")
        try await client.adminRestoreUser(made.id)
        let restored = try await account()
        precondition(restored?.isDeleted == false, "the account was not restored")
        try await client.adminDeleteUser(made.id, force: true)

        // An external library: made, renamed with other paths, scanned, deleted.
        func libraries() async throws -> [AdminLibrary] { try await client.get("libraries") }
        let before = Set(try await libraries().map(\.id))
        try await client.adminSaveLibrary(id: nil, input: AdminLibraryInput(name: "Verso check", ownerId: me, importPaths: ["/tmp"],
                                                                           exclusionPatterns: []))
        guard let library = try await libraries().first(where: { !before.contains($0.id) }) else { preconditionFailure("the library was not made") }
        precondition(library.name == "Verso check" && library.importPaths == ["/tmp"], "the library was not made as asked")
        try await client.adminSaveLibrary(id: library.id, input: AdminLibraryInput(name: "Verso check, renamed", importPaths: ["/var/tmp"],
                                                                                 exclusionPatterns: ["**/*.tmp"]))
        let changed = try await libraries().first { $0.id == library.id }
        precondition(changed?.name == "Verso check, renamed" && changed?.importPaths == ["/var/tmp"]
                     && changed?.exclusionPatterns == ["**/*.tmp"], "the library's changes did not take")
        try await client.adminScanLibrary(library.id)
        try await client.adminDeleteLibrary(library.id)
        let librariesLeft = try await libraries()
        precondition(!librariesLeft.contains { $0.id == library.id }, "the library was not deleted")

        // A job queue: paused, resumed, emptied, its missing work started.
        func queue(_ name: String) async throws -> AdminQueue? {
            let queues: [AdminQueue] = try await client.get("queues")
            return queues.first { $0.name == name }
        }
        let name = "sidecar"
        try await client.adminQueueCommand(name, command: "pause")
        let paused = try await queue(name)
        precondition(paused?.isPaused == true, "the queue was not paused")
        try await client.adminQueueCommand(name, command: "resume")
        let resumed = try await queue(name)
        precondition(resumed?.isPaused == false, "the queue was not resumed")
        try await client.adminQueueCommand(name, command: "empty")
        try await client.adminQueueCommand(name, command: "start", force: false)
        return "an account made, changed, deleted, restored and deleted for good, a library made, changed, scanned and "
            + "deleted, a queue paused, resumed, emptied and started"
    }

    /// A small JPEG, for a profile picture.
    static func tinyJPEG() -> Data {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Changes to what surrounds photos, each made typed, read back as a request and undone: a stack, tags, a memory,
    /// edit steps, the Locked Folder's PIN code (when the account has none yet).
    static func checkPhotoSurroundings(_ client: ImmichClient, password: String) async throws -> String {
        var photos: [String] = []
        for bucket in try await client.timeBuckets(TimelineQuery()) where photos.count < 5 {
            photos += try await client.timeBucket(bucket.timeBucket, TimelineQuery()).id
        }
        precondition(photos.count >= 5, "the account has fewer than five photos")
        struct Anything: Decodable {}
        func gone(_ path: String) async throws -> Bool {
            do {
                let _: Anything = try await client.get(path)
                return false
            } catch ImmichError.http(404, _) { return true } catch ImmichError.http(400, _) { return true }
        }

        // A stack of three: made, its primary changed, one taken out, unstacked.
        let made = try await client.assetsCreateStack([photos[2], photos[3], photos[4]])
        func readStack() async throws -> AssetsStack { try await client.get("stacks/\(made.id)") }
        var stack = try await readStack()
        precondition(made.primaryAssetId == photos[2] && Set(stack.assets.map(\.id)) == Set(photos[2...4]), "the stack was not made as asked")
        let primary = try await client.assetsSetPrimary(stack: made.id, asset: photos[3])
        stack = try await readStack()
        precondition(primary.primaryAssetId == photos[3] && stack.primaryAssetId == photos[3], "the stack's primary did not change")
        try await client.assetsRemoveFromStack(made.id, asset: photos[4])
        stack = try await readStack()
        precondition(Set(stack.assets.map(\.id)) == Set(photos[2...3]), "the photo was not taken out of the stack")
        try await client.assetsUnstack(made.id)
        let unstacked = try await gone("stacks/\(made.id)")
        precondition(unstacked, "the stack is still there")

        // Tags: a parent and child made, the child renamed and coloured, a photo tagged and untagged, both deleted.
        let path = "Verso check \(made.id.prefix(8))/Child"
        try await client.exploreCreateTag(path)
        var tags: [ExploreTag] = try await client.get("tags")
        guard let child = tags.first(where: { $0.value == path }), let parent = tags.first(where: { $0.id == child.parentId }) else {
            preconditionFailure("the tag and its parent were not made")
        }
        try await client.exploreUpdateTag(child, name: "Renamed", color: "#ff0000")
        tags = try await client.get("tags")
        let renamed = tags.first(where: { $0.id == child.id })
        precondition(renamed?.name == "Renamed" && renamed?.color == "#ff0000", "the tag's name or colour did not change")
        try await client.exploreUpdateTag(renamed!, name: "Renamed", color: "")
        tags = try await client.get("tags")
        precondition(tags.first(where: { $0.id == child.id })?.color == nil, "the tag's colour was not removed")
        func tagged() async throws -> [String] { try await client.metadataSearch(tagIds: [child.id], page: .init(page: 1)).items.map(\.id) }
        try await client.exploreTagAssets([photos[0]], tag: child.id, remove: false)
        try await client.exploreTagAssets([photos[0]], tag: child.id, remove: false)  // Tagged already is no failure.
        let withTag = try await tagged()
        precondition(withTag == [photos[0]], "the photo was not tagged")
        try await client.exploreTagAssets([photos[0]], tag: child.id, remove: true)
        let withoutTag = try await tagged()
        precondition(withoutTag.isEmpty, "the photo was not untagged")
        try await client.exploreDeleteTag(child.id)
        try await client.exploreDeleteTag(parent.id)
        tags = try await client.get("tags")
        precondition(!tags.contains { $0.id == child.id || $0.id == parent.id }, "the tags were not deleted")

        // A memory: seen, a photo taken out, deleted.
        struct NewMemory: Encodable {
            struct Details: Encodable { let year: Int }
            let type = "on_this_day", data = Details(year: 2020), memoryAt = "2020-01-01T00:00:00.000Z", assetIds: [String]
        }
        struct Made: Decodable { let id: String }
        let memory: Made = try await client.send("POST", "memories", body: NewMemory(assetIds: [photos[0], photos[1]]))
        func readMemory() async throws -> ExploreMemory { try await client.get("memories/\(memory.id)") }
        try await client.exploreSeenMemory(memory.id)
        let seen = try await readMemory()
        precondition(seen.seenAt != nil, "the memory was not marked seen")
        try await client.exploreKeepMemory(memory.id, keep: true)
        let kept = try await readMemory()
        precondition(kept.isSaved == true, "the memory was not kept")
        try await client.exploreKeepMemory(memory.id, keep: false)
        let letGo = try await readMemory()
        precondition(letGo.isSaved == false, "the memory was still kept")
        try await client.exploreRemoveMemoryAsset(memory.id, asset: photos[1])
        let shorter = try await readMemory()
        precondition(shorter.assets.map(\.id) == [photos[0]], "the photo was not taken out of the memory")
        try await client.exploreDeleteMemory(memory.id)
        let forgotten = try await gone("memories/\(memory.id)")
        precondition(forgotten, "the memory was not deleted")

        // Edit steps: a crop (Immich takes it first only), a turn and a flip, read back typed and as a request, then
        // undone. Steps out of order are the server's 400, with its reason, as a request's are.
        let steps = [MetadataEdit(action: "crop", parameters: .init(x: 10, y: 10, width: 100, height: 100)),
                     MetadataEdit(action: "rotate", parameters: .init(angle: 90)),
                     MetadataEdit(action: "mirror", parameters: .init(axis: "horizontal"))]
        do {
            try await client.saveMetadataEdits(photos[0], edits: Array(steps.reversed()))
            preconditionFailure("a crop after a turn was accepted")
        } catch ImmichError.http(400, let reason) {
            precondition(reason?.contains("Crop") == true, "the server's reason did not come through: \(reason ?? "none")")
        }
        try await client.saveMetadataEdits(photos[0], edits: steps)
        let sentEdits: MetadataEdits = try await client.get("assets/\(photos[0])/edits")
        let typedEdits = try await client.metadataEdits(photos[0])
        precondition(sentEdits.edits == steps && typedEdits.edits == steps, "the edit steps were not saved as made")
        try await client.saveMetadataEdits(photos[0], edits: [])
        let undone: MetadataEdits = try await client.get("assets/\(photos[0])/edits")
        precondition(undone.edits.isEmpty, "the edit was not undone")

        // The Locked Folder: a PIN code set, the folder opened and closed, the PIN code removed again.
        var locked = "the Locked Folder left alone (the account has a PIN code)"
        let before = try await client.exploreAuth()
        if !before.pinCode {
            try await client.exploreUnlock("246810", setup: true)
            let opened = try await client.exploreAuth()
            precondition(opened.pinCode && opened.isElevated, "the Locked Folder did not open")
            try await client.exploreLock()
            let closed = try await client.exploreAuth()
            precondition(!closed.isElevated, "the Locked Folder did not close")
            do {
                try await client.exploreUnlock("135791", setup: false)
                preconditionFailure("a wrong PIN code opened the Locked Folder")
            } catch ImmichError.http(400, _) {}  // What Touch ID's fallback looks for.
            try await client.exploreUnlock("246810", setup: false)
            let reopened = try await client.exploreAuth()
            precondition(reopened.isElevated, "the Locked Folder did not open with its PIN code")
            try await client.exploreLock()
            struct Proof: Encodable { let password: String }
            try await client.send("DELETE", "auth/pin-code", body: Proof(password: password))
            locked = "the Locked Folder's PIN code set, opened, closed and opened again, removed"
        }
        return "a stack made, changed and unstacked, tags made, changed, used and deleted, a memory seen, kept and let go, shortened and "
            + "deleted, three edit steps saved and undone, " + locked
    }

    /// Today's memories typed and as a request, with two made for the check (an on-this-day and a birthday, shown
    /// today) and deleted again.
    static func checkMemories(_ client: ImmichClient, _ photo: String) async throws -> String {
        struct Details: Encodable { let year: Int; var personId: String?; var personName: String? }
        struct NewMemory: Encodable {
            let type: String, data: Details, memoryAt: String, showAt: String, hideAt: String, assetIds: [String]
        }
        struct Made: Decodable { let id: String }
        let today = String(Date().ISO8601Format().prefix(10))
        guard let person = try await client.people(page: 1, size: 1).people.first else { preconditionFailure("the account has no people") }
        var made: [String] = []
        for (type, details) in [("on_this_day", Details(year: 2020)),
                                ("birthday", Details(year: 1990, personId: person.id, personName: person.name))] {
            let memory = NewMemory(type: type, data: details, memoryAt: "\(details.year)-\(today.dropFirst(5))T00:00:00.000Z",
                                   showAt: "\(today)T00:00:00.000Z", hideAt: "\(today)T23:59:59.000Z", assetIds: [photo])
            let answer: Made = try await client.send("POST", "memories", body: memory)
            made.append(answer.id)
        }
        let sent: [ExploreMemory] = try await client.get("memories", query: ["for": today, "page": "1", "size": "100",
                                                                             "isTrashed": "false", "isUpcoming": "false"])
        let typed = try await client.exploreMemories(page: 1)
        func text(_ memory: ExploreMemory) -> String {
            ([memory.id, memory.type, String(memory.data.year), memory.data.personName ?? "",
              memory.seenAt.flatMap(ImmichDate.parse).map { "\($0)" } ?? "", memory.title,
              memory.memoryAt.flatMap(ImmichDate.parse).map { "\($0)" } ?? "", String(describing: memory.isSaved)]
             + memory.assets.map(assetText)).joined(separator: "|")
        }
        precondition(Set(made).isSubset(of: sent.map(\.id)), "the memories made are not listed today")
        precondition(typed.map(text) == sent.map(text), "today's memories differ")
        for id in made { try await client.exploreDeleteMemory(id) }
        return "\(sent.count) memories of today, one a birthday, read typed as sent"
    }

    /// A photo as text to compare: every field the app reads, times compared as the instants they name.
    static func assetText(_ asset: AssetResponse) -> String {
        func time(_ text: String?) -> String { text.flatMap(ImmichDate.parse).map { String($0.timeIntervalSince1970) } ?? "" }
        func number<Value>(_ value: Value?) -> String { value.map { "\($0)" } ?? "" }
        let exif = asset.exifInfo
        let fields: [String] = [
            asset.id, asset.ownerId ?? "", asset.type.rawValue, asset.originalFileName, asset.originalMimeType ?? "",
            time(asset.fileCreatedAt), time(asset.localDateTime), time(asset.createdAt), String(asset.isFavorite),
            String(asset.isTrashed), asset.visibility ?? "", number(asset.duration?.milliseconds), asset.thumbhash ?? "",
            asset.livePhotoVideoId ?? "", number(asset.width), number(asset.height), String(asset.isEdited ?? false),
            (asset.people ?? []).map { $0.id + ":" + $0.name }.sorted().joined(separator: ","),
            asset.stack.map { "\($0.id) \($0.primaryAssetId) \($0.assetCount)" } ?? "",
            exif?.make ?? "", exif?.model ?? "", exif?.lensModel ?? "", number(exif?.fNumber), number(exif?.focalLength),
            number(exif?.iso), exif?.exposureTime ?? "", exif?.orientation ?? "", number(exif?.exifImageWidth),
            number(exif?.exifImageHeight), number(exif?.fileSizeInByte), number(exif?.latitude), number(exif?.longitude),
            exif?.city ?? "", exif?.state ?? "", exif?.country ?? "", exif?.description ?? "",
            time(exif?.dateTimeOriginal), exif?.timeZone ?? "", number(exif?.rating), exif?.projectionType ?? "",
        ]
        return fields.joined(separator: "|")
    }

    static func personText(_ person: Person) -> String {
        [person.id, person.name, String(person.isHidden), String(person.isFavorite ?? false), person.birthDate ?? ""].joined(separator: "|")
    }

    /// An album from the typed call and from the request, the same in every field the app reads.
    static func sameAlbum(_ typed: Album, _ sent: Album) {
        precondition(typed.albumName == sent.albumName && typed.assetCount == sent.assetCount && typed.shared == sent.shared
                     && typed.albumThumbnailAssetId == sent.albumThumbnailAssetId
                     && (typed.description ?? "") == (sent.description ?? "")
                     && sameDate(typed.startDate, sent.startDate) && sameDate(typed.endDate, sent.endDate)
                     && sameDate(typed.createdAt, sent.createdAt) && sameDate(typed.updatedAt, sent.updatedAt)
                     && sameDate(typed.lastModifiedAssetTimestamp, sent.lastModifiedAssetTimestamp)
                     && members(typed.albumUsers) == members(sent.albumUsers),
                     "album \(sent.id) (\(sent.albumName)) differs between the typed call and the request")
    }

    static func sameDate(_ typed: String?, _ sent: String?) -> Bool {
        typed.flatMap(ImmichDate.parse) == sent.flatMap(ImmichDate.parse)
    }

    /// Each member's role and account, as text to compare.
    static func members(_ members: [AlbumMember]?) -> [String] {
        (members ?? []).map { [$0.role, $0.user.id, $0.user.name, $0.user.email, $0.user.avatarColor ?? "",
                               $0.user.profileImagePath ?? ""].joined(separator: "|") }
    }

    /// A month from the typed call and from the request, the same in every column the grid reads. Empty and missing
    /// are the same: immich-api reads an empty id or place, or a ratio of zero, as none.
    static func same(_ typed: TimeBucketAssets, _ sent: TimeBucketAssets, _ name: String) {
        func check(_ same: Bool, _ column: String) {
            precondition(same, "\(name): \(column) differs between the typed call and the request")
        }
        let rows = sent.id.count
        func known(_ text: String?) -> String? { text?.isEmpty == false ? text : nil }
        func filled<Value>(_ column: [Value?]?) -> [Value?] { column ?? Array(repeating: nil, count: rows) }
        check(typed.id == sent.id, "id")
        check(typed.isImage == sent.isImage, "isImage")
        check(typed.isFavorite == sent.isFavorite, "isFavorite")
        check(typed.isTrashed == sent.isTrashed, "isTrashed")
        check(typed.thumbhash.map(known) == sent.thumbhash.map(known), "thumbhash")
        check(zip(typed.ratio, sent.ratio).allSatisfy { mine, theirs in
            let theirs = theirs.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            return mine == theirs || (mine != nil && theirs != nil && abs(mine! - theirs!) < 1e-9)
        }, "ratio")
        check(typed.duration.map { $0?.milliseconds } == sent.duration.map { $0?.milliseconds }, "duration")
        check(zip(typed.fileCreatedAt, sent.fileCreatedAt).allSatisfy { ImmichDate.parse($0) == ImmichDate.parse($1) }, "fileCreatedAt")
        check(typed.livePhotoVideoId.map(known) == sent.livePhotoVideoId.map(known), "livePhotoVideoId")
        check(typed.visibility == sent.visibility, "visibility")
        check(typed.ownerId == sent.ownerId, "ownerId")
        check(filled(typed.stack).map { $0?.first } == filled(sent.stack).map { $0?.first }, "stack")
        check(filled(typed.stack).map { $0?.last } == filled(sent.stack).map { $0?.last }, "stack count")
        check(filled(typed.city).map(known) == filled(sent.city).map(known), "city")
        check(filled(typed.country).map(known) == filled(sent.country).map(known), "country")
        check(filled(typed.latitude) == filled(sent.latitude) && filled(typed.longitude) == filled(sent.longitude), "coordinates")
    }
}
