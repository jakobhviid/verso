// The pictures Collections and Search show: a photo's thumbnail, a person's face in a rounded square (a person is a
// rounded square, an account a circle: DESIGN.md), and the cards of Collections' rows that the card pages do not
// draw: the map of the places, and See All. Each loads through the shared ImagePipeline and shows an empty tile until
// its picture comes; nothing fades in.

import MapKit
import SwiftUI

/// A photo filling its frame.
struct CollectionsThumbnail: View {
    let pipeline: ImagePipeline
    let assetID: String?
    var size: ImmichClient.ThumbnailSize = .thumbnail
    @State private var image: CGImage?
    /// The photo `image` belongs to: a view given another photo starts empty.
    @State private var shownID: String?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image, shownID == assetID {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: assetID) {
                guard let assetID else { return }
                if let cached = pipeline.cachedThumbnail(assetID, size: size) {
                    image = cached
                    shownID = assetID
                    return
                }
                let loaded = await pipeline.gridThumbnail(assetID, size: size)
                guard !Task.isCancelled, let loaded else { return }
                image = loaded
                shownID = assetID
            }
    }
}

/// A person's face, filling its frame; the caller gives it its rounded corners.
struct CollectionsFace: View {
    let pipeline: ImagePipeline
    let personID: String
    @State private var image: CGImage?
    @State private var shownID: String?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image, shownID == personID {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: personID) {
                let loaded = await pipeline.personThumbnail(personID)
                guard !Task.isCancelled, let loaded else { return }
                image = loaded
                shownID = personID
            }
    }
}

/// The corner every tile in Collections has, as the card pages' cards: an album's, a place's, a memory's and a person's.
let collectionsCornerRadius: CGFloat = 12

/// The map of the places, as Photos' Places card: still, the cities marked, with "Map" and how many places on a fade at
/// its top, where the map's own legal notice at its foot leaves room, opening Places when tapped.
struct CollectionsMapCard: View {
    let places: [AssetResponse]

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: []) {
            ForEach(located, id: \.id) { place in
                Marker(place.name, coordinate: place.coordinate)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Map")
                    .font(.headline)
                Text(places.count == 1 ? "1 place" : "\(places.count) places")
                    .font(.caption)
                    .opacity(0.85)
            }
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(.rect(cornerRadius: collectionsCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private struct LocatedPlace {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    private var located: [LocatedPlace] {
        places.compactMap { place in
            guard let latitude = place.exifInfo?.latitude, let longitude = place.exifInfo?.longitude else { return nil }
            return LocatedPlace(id: place.id, name: place.exifInfo?.city ?? "",
                                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
    }
}

/// The last card of a shortened row: See All, the size of the cards before it.
struct CollectionsSeeAllCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: collectionsCornerRadius)
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Label("See All", systemImage: "chevron.right")
                    .labelStyle(.titleOnly)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
            }
    }
}
