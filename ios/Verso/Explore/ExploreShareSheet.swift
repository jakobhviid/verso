// Sharing a photo from a memory through the system's share sheet: its original is downloaded first, under its own
// name, so the apps it goes to get the photo or video Immich keeps, with its type, and not a preview. The download is
// removed once the sheet closes.

import SwiftUI
import UIKit

/// A photo's original, downloaded for the share sheet.
struct ExploreSharedFile: Identifiable {
    let id = UUID()
    let url: URL

    /// Downloads the original of `asset` into a folder of its own in the temporary folder.
    static func download(_ asset: AssetResponse, client: ImmichClient) async throws -> ExploreSharedFile {
        let (downloaded, response) = try await client.session.download(for: client.originalRequest(asset.id))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: downloaded)
            if http.statusCode == 401 { throw ImmichError.unauthorized(nil) }
            throw ImmichError.http(http.statusCode, nil)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sharing", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (asset.originalFileName as NSString).lastPathComponent
        let file = folder.appendingPathComponent(name.isEmpty ? asset.id : name)
        try FileManager.default.moveItem(at: downloaded, to: file)
        return ExploreSharedFile(url: file)
    }

    /// Removes the download and its folder.
    func remove() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

/// The system's share sheet for downloaded files.
struct ExploreShareSheet: UIViewControllerRepresentable {
    let file: ExploreSharedFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
