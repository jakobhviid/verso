// The places as cards, as the Mac and Linux draw them (mac/Verso/Verso/Views/Explore/ExploreView.swift): a city is its
// photo with its name on it and, where wanted, its country under the name; a country is three of its places' photos,
// one large beside two small, each with its city in small letters, and on a fade at its foot its name and how many
// places. A country pushes its cities (PlacesCountryRoutePage), a city its photos. Both come in the card sizes every
// card page shares (CardSize).

import SwiftUI

/// A city: its photo, with its name and, where wanted, its country on a fade at its foot.
struct PlaceCityTile: View {
    let pipeline: ImagePipeline
    let place: AssetResponse
    let showsCountry: Bool

    var body: some View {
        ExploreThumbnail(pipeline: pipeline, assetID: place.id, size: .preview, thumbhash: place.thumbhash)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.exifInfo?.city ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    if showsCountry, let country = place.exifInfo?.country, !country.isEmpty {
                        Text(country)
                            .font(.caption)
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
    }
}

/// A country: three of its places' photos, one large beside two small, each with its city in small dimmed letters,
/// or the first alone; on a fade at its foot its name and how many places.
struct PlaceCountryCard: View {
    let pipeline: ImagePipeline
    let title: String
    /// Its places, in the order chosen.
    let places: [AssetResponse]

    var body: some View {
        photos
            .aspectRatio(1.3, contentMode: .fit)
            .overlay(alignment: .bottom) { foot }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(cityNames.isEmpty ? placesCount : "\(placesCount), \(cityNames)")
    }

    /// One large beside two small, or the first alone.
    @ViewBuilder private var photos: some View {
        if places.count >= 3 {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    labelled(places[0], size: .preview)
                        .frame(width: geometry.size.width * 0.64)
                    VStack(spacing: 2) {
                        labelled(places[1])
                        labelled(places[2])
                    }
                }
            }
        } else {
            labelled(places.first, size: .preview)
        }
    }

    /// A place's photo with its city in small dimmed letters, context for the photo below the country's name.
    private func labelled(_ place: AssetResponse?, size: ImmichClient.ThumbnailSize = .thumbnail) -> some View {
        ExploreThumbnail(pipeline: pipeline, assetID: place?.id, size: size, thumbhash: place?.thumbhash)
            .overlay(alignment: .topLeading) {
                if let city = place?.exifInfo?.city, !city.isEmpty {
                    Text(verbatim: city)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                        .padding(6)
                }
            }
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(1)
            Text(placesCount)
                .font(.caption)
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 28)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }

    private var placesCount: String {
        places.count == 1 ? String(localized: "1 place") : String(localized: "\(places.count) places")
    }

    /// The names of its first three places, for VoiceOver.
    private var cityNames: String {
        places.prefix(3).compactMap { place in place.exifInfo?.city.flatMap { $0.isEmpty ? nil : $0 } }
            .formatted(.list(type: .and, width: .narrow))
    }
}

/// The places' card sizes: countries two to a row on iPhone, then one; cities three, then two, then one; on iPad the
/// Mac's widths.
enum PlacesLayout {
    static let countries = CardLadder(compactColumns: [2, 1, 1, 1, 1], widths: [240, 300, 370, 450, 520], spacing: 12)
    static let cities = CardLadder(compactColumns: [3, 2, 2, 1, 1], widths: [170, 210, 260, 320, 400], spacing: 12)
}
