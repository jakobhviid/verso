import SwiftUI

/// A cluster of the map: its first photo, and how many. MapKit creates independent hosting views; all image
/// dependencies are explicit.
struct ExploreMapAnnotation: View {
    /// The cluster's photos, by id (`MapCluster.assets`).
    let assets: [String]
    let pipeline: ImagePipeline
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            RemoteThumbnail(pipeline: pipeline, assetID: assets.first)
                .frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(assets.count)").font(.caption.bold()).padding(3).background(.regularMaterial, in: Capsule())
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
        }.buttonStyle(.plain)
    }
}
