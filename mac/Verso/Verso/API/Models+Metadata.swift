import CoreGraphics
import Foundation

struct MetadataUpdate: Encodable, Sendable {
    var ids: [String]
    var dateTimeOriginal: String?
    var dateTimeRelative: Int?
    var timeZone: String?
    var latitude: Double?
    var longitude: Double?
    var description: String?
    var rating: Int?
    var clearRating = false

    enum CodingKeys: String, CodingKey {
        case ids, dateTimeOriginal, dateTimeRelative, timeZone, latitude, longitude, description, rating
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ids, forKey: .ids)
        try c.encodeIfPresent(dateTimeOriginal, forKey: .dateTimeOriginal)
        try c.encodeIfPresent(dateTimeRelative, forKey: .dateTimeRelative)
        try c.encodeIfPresent(timeZone, forKey: .timeZone)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encodeIfPresent(description, forKey: .description)
        if clearRating { try c.encodeNil(forKey: .rating) }
        else { try c.encodeIfPresent(rating, forKey: .rating) }
    }
}

struct MetadataPreferences: Decodable {
    struct Ratings: Decodable { var enabled: Bool }
    var ratings: Ratings?
}

struct MetadataEdit: Codable, Sendable, Equatable {
    var action: String
    var parameters: Parameters

    struct Parameters: Codable, Sendable, Equatable {
        var angle: Int?
        var axis: String?
        var x: Int?
        var y: Int?
        var width: Int?
        var height: Int?
    }
}

struct MetadataEdits: Codable, Sendable {
    var edits: [MetadataEdit]
}

/// A photo's edit list as Verso changes it on the Mac and on iOS, as Verso on Linux changes it (verso-desktop's
/// actions.rs, `rotated` and `cropped`): one rotate step, turned as the photo is seen, and the crop first, in pixels of
/// the original standing up (its EXIF orientation applied). Immich applies the crop first, then the turns and mirrors
/// in their order. Verso makes no mirror; one made in Immich's web app stays where it is.
enum MetadataEditList {
    /// The whole picture, as fractions of it.
    static let wholePicture = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The edits turned by quarter turns clockwise as the photo is seen (negative for counter-clockwise): the rotate
    /// step changes, comes last when there is none, and goes once back at zero; every other step stays. A mirror after
    /// the rotate step turns its direction around, so with an odd number of them the step turns the other way.
    static func rotated(_ edits: [MetadataEdit], quarterTurns: Int) -> [MetadataEdit] {
        var edits = edits
        let step = edits.firstIndex { $0.action == "rotate" }
        let current = step.map { edits[$0].parameters.angle ?? 0 }
        let mirrorsAfter = step.map { position in edits[position...].filter { $0.action == "mirror" }.count } ?? 0
        let turns = mirrorsAfter % 2 == 1 ? -quarterTurns : quarterTurns
        let angle = (((current ?? 0) + turns * 90) % 360 + 360) % 360
        if current == nil {
            if angle != 0 { edits.append(MetadataEdit(action: "rotate", parameters: .init(angle: angle))) }
        } else if angle == 0 {
            edits.removeAll { $0.action == "rotate" }
        } else {
            for index in edits.indices where edits[index].action == "rotate" { edits[index].parameters.angle = angle }
        }
        return edits
    }

    /// The crop among the edits, as fractions of the upright picture of `width` by `height` pixels; the whole picture
    /// without one.
    static func crop(in edits: [MetadataEdit], width: Int, height: Int) -> CGRect {
        guard width > 0, height > 0, let step = edits.first(where: { $0.action == "crop" })?.parameters else {
            return wholePicture
        }
        let rect = CGRect(x: Double(step.x ?? 0) / Double(width), y: Double(step.y ?? 0) / Double(height),
                          width: Double(step.width ?? width) / Double(width),
                          height: Double(step.height ?? height) / Double(height))
        let inside = rect.intersection(wholePicture)
        return inside.isNull || inside.isEmpty ? wholePicture : inside
    }

    /// The edits with the crop replaced: the old one goes, and a new one comes first, before any turn or mirror, in
    /// pixels of the upright original; none for the whole picture.
    static func cropped(_ edits: [MetadataEdit], crop: CGRect, width: Int, height: Int) -> [MetadataEdit] {
        var edits = edits.filter { $0.action != "crop" }
        if let step = cropStep(crop, width: width, height: height) { edits.insert(step, at: 0) }
        return edits
    }

    private static func cropStep(_ crop: CGRect, width: Int, height: Int) -> MetadataEdit? {
        guard width > 0, height > 0 else { return nil }
        let tolerance = 0.0005
        if crop.minX <= tolerance, crop.minY <= tolerance, crop.maxX >= 1 - tolerance, crop.maxY >= 1 - tolerance {
            return nil
        }
        let left = min(max(0, Int(crop.minX * Double(width))), width - 1)
        let top = min(max(0, Int(crop.minY * Double(height))), height - 1)
        let cropWidth = min(width - left, max(1, Int((crop.width * Double(width)).rounded())))
        let cropHeight = min(height - top, max(1, Int((crop.height * Double(height)).rounded())))
        return MetadataEdit(action: "crop", parameters: .init(x: left, y: top, width: cropWidth, height: cropHeight))
    }
}


extension Exif {
    var metadataDimensions: (width: Int, height: Int)? {
        guard let width = exifImageWidth, let height = exifImageHeight, width > 0, height > 0 else { return nil }
        return ["5", "6", "7", "8"].contains(orientation ?? "") ? (height, width) : (width, height)
    }
}

extension AssetResponse {
    func canEditMetadataImage(userID: String?) -> Bool {
        guard let userID, ownerId == userID, type == .image, livePhotoVideoId == nil,
              exifInfo?.projectionType != "EQUIRECTANGULAR", exifInfo?.metadataDimensions != nil else { return false }
        let name = originalFileName.lowercased()
        return ![".gif", ".svg", ".insp"].contains(where: name.hasSuffix)
            && !["image/gif", "image/svg+xml"].contains(originalMimeType?.lowercased() ?? "")
    }
}

extension ServerVersion {
    var supportsMetadataEdits: Bool { (major, minor, patch) >= (2, 5, 0) }
}

/// MapKit can return wrapped longitudes outside the server's accepted range.
func metadataCoordinate(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
    let wrapped = (longitude + 180).truncatingRemainder(dividingBy: 360)
    return (min(90, max(-90, latitude)), (wrapped < 0 ? wrapped + 360 : wrapped) - 180)
}
