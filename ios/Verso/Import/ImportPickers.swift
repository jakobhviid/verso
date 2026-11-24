// The two ways into an import on iOS (ROADMAP.md, M10), from Collections' "+" menu: Import from Photos…, the system's
// photo picker, many at once, each written out as the original the library keeps (ImportCoordinator); and Import from
// Files…, files and folders from any place Files reaches. Both go into the library through the shared UploadQueue,
// which checks each against Immich by its checksum first, as on the Mac and Linux; the Library's title line shows how
// the import goes (ImportProgress).

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// The photo picker and the file importer, presented while `choosingPhotos` or `choosingFiles` is true; what is
    /// chosen is imported into the library.
    func importPickers(queue: UploadQueue, choosingPhotos: Binding<Bool>, choosingFiles: Binding<Bool>) -> some View {
        modifier(ImportPickers(queue: queue, choosingPhotos: choosingPhotos, choosingFiles: choosingFiles))
    }
}

private struct ImportPickers: ViewModifier {
    let queue: UploadQueue
    @Binding var choosingPhotos: Bool
    @Binding var choosingFiles: Bool
    @State private var pickedPhotos: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $choosingPhotos, selection: $pickedPhotos, maxSelectionCount: nil,
                          selectionBehavior: .ordered, matching: .any(of: [.images, .videos, .livePhotos]),
                          preferredItemEncoding: .current, photoLibrary: .shared())
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                ImportCoordinator.of(queue).importPhotos(items, albumID: nil)
            }
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.image, .movie, .folder],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    ImportCoordinator.of(queue).importFiles(urls, albumID: nil)
                case .failure(let error):
                    queue.lastError = error.localizedDescription
                }
            }
    }
}
