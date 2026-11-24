// swiftc Verso/API/Models.swift Verso/API/Models+Metadata.swift scripts/verify-metadata.swift -o /tmp/verify-metadata
// /tmp/verify-metadata [preferences.json asset.json edits.json]
import Foundation

@main
struct VerifyMetadata {
    static func main() throws {
        var exif = Exif()
        exif.exifImageWidth = 192
        exif.exifImageHeight = 128
        exif.orientation = "6"
        assert(exif.metadataDimensions?.width == 128 && exif.metadataDimensions?.height == 192)
        exif.orientation = "1"
        assert(exif.metadataDimensions?.width == 192 && exif.metadataDimensions?.height == 128)
        let encoder = JSONEncoder()
        func object(_ update: MetadataUpdate) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: encoder.encode(update)) as! [String: Any]
        }
        let omitted = try object(.init(ids: ["test"], description: ""))
        assert(omitted["rating"] == nil)
        assert(omitted["description"] as? String == "")
        let cleared = try object(.init(ids: ["test"], clearRating: true))
        assert(cleared["rating"] is NSNull)
        let relative = try object(.init(ids: ["a", "b"], dateTimeRelative: -90, timeZone: "Europe/Rome"))
        assert(relative["dateTimeRelative"] as? Int == -90)
        assert(relative["dateTimeOriginal"] == nil)
        assert(relative["timeZone"] as? String == "Europe/Rome")
        let preservedZones = try object(.init(ids: ["a", "b"], dateTimeRelative: 30))
        assert(preservedZones["timeZone"] == nil)
        assert(ServerVersion(major: 2, minor: 5, patch: 0).supportsMetadataEdits)
        assert(ServerVersion(major: 3, minor: 0, patch: 0).supportsMetadataEdits)
        assert(!ServerVersion(major: 1, minor: 99, patch: 0).supportsMetadataEdits)
        assert(!ServerVersion(major: 2, minor: 4, patch: 99).supportsMetadataEdits)
        assert(metadataCoordinate(latitude: 95, longitude: 541).latitude == 90)
        assert(metadataCoordinate(latitude: -95, longitude: -541).longitude == 179)
        assert(metadataCoordinate(latitude: 0, longitude: 541).longitude == -179)
        let crop = MetadataEdit(action: "crop", parameters: .init(x: 10, y: 20, width: 100, height: 80))
        let rotation = MetadataEdit(action: "rotate", parameters: .init(angle: 270))
        let edits = MetadataEdits(edits: [crop, rotation])
        let decoded = try JSONDecoder().decode(MetadataEdits.self, from: encoder.encode(edits))
        assert(decoded.edits[0].parameters.width == 100 && decoded.edits[1].parameters.angle == 270)
        assert(decoded.edits == edits.edits)
        assert(decoded.edits != [rotation, crop])
        var asset = AssetResponse(id: "asset", ownerId: "me", type: .image, originalFileName: "photo.jpg",
                                  fileCreatedAt: "", localDateTime: "", isFavorite: false, isTrashed: false, exifInfo: exif)
        assert(asset.canEditMetadataImage(userID: "me"))
        assert(!asset.canEditMetadataImage(userID: "someone-else"))
        assert(!asset.canEditMetadataImage(userID: nil))
        for suffix in ["GIF", "svg", "insp"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": "asset", "type": "IMAGE", "originalFileName": "photo.\(suffix)", "ownerId": "me",
                "fileCreatedAt": "", "localDateTime": "", "isFavorite": false, "isTrashed": false,
                "exifInfo": ["exifImageWidth": 192, "exifImageHeight": 128]
            ])
            let blocked = try JSONDecoder().decode(AssetResponse.self, from: data)
            assert(!blocked.canEditMetadataImage(userID: "me"))
        }
        asset.exifInfo?.projectionType = "EQUIRECTANGULAR"
        assert(!asset.canEditMetadataImage(userID: "me"))
        asset.exifInfo = nil
        assert(!asset.canEditMetadataImage(userID: "me"))
        checkEditList()
        if CommandLine.arguments.count == 4 {
            let decoder = JSONDecoder()
            let preferences = try decoder.decode(MetadataPreferences.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let asset = try decoder.decode(AssetResponse.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let liveEdits = try decoder.decode(MetadataEdits.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
            print("Live DTO decode passed: ratings enabled=\(preferences.ratings?.enabled ?? false), asset=\(asset.id), edits=\(liveEdits.edits.count)")
        }
        print("Metadata encoding checks passed; edit list: turns as seen, mirrored or not, the crop first")
    }

    /// The edit list as the Mac and iOS change it, by the rules of Linux's `actions::rotated` and `cropped`.
    static func checkEditList() {
        func turn(_ angle: Int) -> MetadataEdit { MetadataEdit(action: "rotate", parameters: .init(angle: angle)) }
        let flip = MetadataEdit(action: "mirror", parameters: .init(axis: "horizontal"))
        let upsideDown = MetadataEdit(action: "mirror", parameters: .init(axis: "vertical"))
        let crop = MetadataEdit(action: "crop", parameters: .init(x: 0, y: 0, width: 10, height: 10))
        let rotated = MetadataEditList.rotated

        // Linux's cases (verso-desktop, actions.rs, `turning_changes_only_the_rotation`).
        precondition(rotated([crop], 1) == [crop, turn(90)], "A new step goes last")
        precondition(rotated([turn(90), crop], -1) == [crop], "Back at zero, the step goes")
        precondition(rotated([turn(270)], 1) == [])
        precondition(rotated([turn(90)], 1) == [turn(180)])
        precondition(rotated([], -1) == [turn(270)])
        precondition(rotated([turn(90), flip], 1) == [flip], "Flipped after the turn, the step turns the other way")
        precondition(rotated([turn(90), flip, flip], 1) == [turn(180), flip, flip], "Flipped twice, it turns as it is")
        precondition(rotated([flip, turn(90)], 1) == [flip, turn(180)], "Flipped before the turn, it turns as it is")
        precondition(rotated([flip], 1) == [flip, turn(90)], "A new step goes after the flip")

        // Every list of a crop, one turn and mirrors, turned either way: the photo turns as it is seen, and only its
        // rotate step changes.
        let lists = editLists(steps: [flip, upsideDown, turn(90), turn(180), turn(270)])
        for list in lists + lists.map({ [crop] + $0 }) {
            for quarterTurns in [1, -1, 2, 3] {
                let turned = rotated(list, quarterTurns)
                var expected = Placement(list)
                for _ in 0..<((quarterTurns % 4 + 4) % 4) { expected.then(xx: 0, xy: -1, yx: 1, yy: 0) }
                precondition(Placement(turned) == expected, "\(list) turned \(quarterTurns): \(turned)")
                precondition(turned.filter { $0.action != "rotate" } == list.filter { $0.action != "rotate" }, "Only the rotate step changes")
                precondition(turned.filter { $0.action == "rotate" }.count <= 1, "One rotate step")
                precondition(turned.allSatisfy { $0.action != "rotate" || [90, 180, 270].contains($0.parameters.angle ?? 0) })
            }
        }
        // The turns summed and appended last mis-turn a photo mirrored after its turn, which the check above catches.
        var mirroredTurned = Placement([turn(90), flip])
        mirroredTurned.then(xx: 0, xy: -1, yx: 1, yy: 0)
        precondition(Placement([flip, turn(180)]) != mirroredTurned && Placement([flip]) == mirroredTurned)

        // The crop: first, in pixels of the upright original, and none for the whole picture.
        let old = MetadataEdit(action: "crop", parameters: .init(x: 1, y: 1, width: 5, height: 5))
        let quarter = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let made = MetadataEdit(action: "crop", parameters: .init(x: 1000, y: 1500, width: 2000, height: 750))
        precondition(MetadataEditList.cropped([turn(90), flip, old], crop: quarter, width: 4000, height: 3000) == [made, turn(90), flip])
        precondition(MetadataEditList.cropped([old, turn(90)], crop: MetadataEditList.wholePicture, width: 4000, height: 3000) == [turn(90)])
        precondition(MetadataEditList.crop(in: [turn(90), made], width: 4000, height: 3000) == quarter)
        precondition(MetadataEditList.crop(in: [turn(90)], width: 4000, height: 3000) == MetadataEditList.wholePicture)
        let edge = MetadataEditList.cropped([], crop: CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5), width: 100, height: 100)
        precondition(edge == [MetadataEdit(action: "crop", parameters: .init(x: 90, y: 90, width: 10, height: 10))], "Kept inside: \(edge)")
    }

    /// Every list of up to four of the steps, with one rotate step at most.
    static func editLists(steps: [MetadataEdit]) -> [[MetadataEdit]] {
        var lists: [[MetadataEdit]] = [[]]
        var longest: [[MetadataEdit]] = [[]]
        for _ in 0..<4 {
            longest = longest.flatMap { list in
                steps.compactMap { step in
                    step.action == "rotate" && list.contains { $0.action == "rotate" } ? nil : list + [step]
                }
            }
            lists += longest
        }
        return lists
    }

    /// Where the picture's points go after the steps, as Immich applies them in their order: x becomes xx·x + xy·y
    /// and y becomes yx·x + yy·y, about the middle, with x to the right and y down. The crop turns nothing.
    struct Placement: Equatable {
        var xx = 1, xy = 0, yx = 0, yy = 1

        init(_ edits: [MetadataEdit]) {
            for edit in edits {
                switch edit.action {
                case "rotate":
                    for _ in 0..<(((edit.parameters.angle ?? 0) / 90 % 4 + 4) % 4) { then(xx: 0, xy: -1, yx: 1, yy: 0) }
                case "mirror" where edit.parameters.axis == "vertical": then(xx: 1, xy: 0, yx: 0, yy: -1)
                case "mirror": then(xx: -1, xy: 0, yx: 0, yy: 1)
                default: break
                }
            }
        }

        /// A step after the ones so far.
        mutating func then(xx stepXX: Int, xy stepXY: Int, yx stepYX: Int, yy stepYY: Int) {
            (xx, xy, yx, yy) = (stepXX * xx + stepXY * yx, stepXX * xy + stepXY * yy,
                                stepYX * xx + stepYY * yx, stepYX * xy + stepYY * yy)
        }
    }
}
