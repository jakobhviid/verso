// A photo's or video's original, for the viewer's Copy on iOS, and its name and format for the viewer's Share
// (ShareSheet.swift): downloaded from Immich through the account's session, as the Mac's drags and copies download it
// (ImmichClient.macIntegrationOriginal), under its own name and in its own format.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ViewerOriginal: Sendable {
    let id: String
    /// The original's file name.
    let name: String
    /// Its format when the name says one the share sheet knows, else its kind: a photo, a video or data.
    let type: UTType
    let client: ImmichClient

    /// The formats offered under their own type; any other is offered as its kind.
    static let formats: [UTType] = [.jpeg, .heic, .heif, .png, .gif, .webP, .tiff, .quickTimeMovie, .mpeg4Movie]

    /// From the photo's details once they have loaded; until then, its kind and its ID as the name.
    init(item: AssetItem, details: AssetResponse?, client: ImmichClient) {
        id = item.id
        self.client = client
        guard let details else {
            name = item.id
            type = item.isVideo ? .movie : .image
            return
        }
        let fileName = (details.originalFileName as NSString).lastPathComponent
        let kind: UTType = switch details.type {
        case .image: .image
        case .video: .movie
        default: .data
        }
        let format = kind == .data ? nil : UTType(filenameExtension: (fileName as NSString).pathExtension, conformingTo: kind)
        name = fileName.isEmpty || fileName == "." || fileName == ".." ? item.id : fileName
        type = format.flatMap { Self.formats.contains($0) ? $0 : nil } ?? kind
    }

    /// Copy: the original on the pasteboard in its own format, as Photos copies a photo.
    @MainActor
    func copyToPasteboard() async throws {
        let file = try await client.macIntegrationOriginal(id)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let data = try await Task.detached { try Data(contentsOf: file) }.value
        let fileType = UTType(filenameExtension: file.pathExtension) ?? type
        UIPasteboard.general.setData(data, forPasteboardType: fileType.identifier)
    }
}
