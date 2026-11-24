// A person in the photos, drawn as Verso draws one on every platform: a rounded square with the corner of the album and
// place tiles, where an account is a circle (DESIGN.md, "The apps' interfaces"). On the People page the name sits on
// the face, on a fade at its foot, and the heart and the hidden mark in its corner.

import SwiftUI

/// A person's shape: a rounded square whose corner follows its size, as the Mac's.
struct PersonFaceShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        return RoundedRectangle(cornerRadius: min(12, max(4, side * 0.09)), style: .continuous).path(in: rect)
    }
}

/// A person's face alone, in their rounded square: for headers, pickers and lists, beside the name.
struct PersonFaceImage: View {
    let pipeline: ImagePipeline
    let personID: String
    @State private var image: CGImage?
    @State private var shownID: String?

    var body: some View {
        PersonFaceShape()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(PersonFaceShape())
            .aspectRatio(1, contentMode: .fit)
            .task(id: personID) {
                if shownID != personID {
                    image = nil
                    shownID = personID
                }
                let loaded = await pipeline.personThumbnail(personID)
                guard !Task.isCancelled else { return }
                image = loaded
            }
            .onReceive(NotificationCenter.default.publisher(for: .versoPersonFaceChanged)) { notification in
                guard notification.userInfo?["personID"] as? String == personID else { return }
                Task { image = await pipeline.personThumbnail(personID) }
            }
            .accessibilityHidden(true)
    }
}

/// A person on the People page: the face, their name on it on a fade at its foot (Add Name, dimmed, for someone
/// unnamed), and their heart and hidden mark in its corner.
struct PersonFaceTile: View {
    let pipeline: ImagePipeline
    let person: Person
    /// A tile two or fewer to a row, whose name is larger too.
    var large = false

    var body: some View {
        PersonFaceImage(pipeline: pipeline, personID: person.id)
            .overlay(alignment: .bottom) { name }
            .clipShape(PersonFaceShape())
            .overlay(alignment: .topTrailing) { marks }
            .contentShape(PersonFaceShape())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(person.displayName)
            .accessibilityValue(accessibilityMarks)
    }

    private var name: some View {
        Text(person.name.isEmpty ? "Add Name" : person.name)
            .font(large ? .headline : .subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(person.name.isEmpty ? 0.6 : 1))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, 20)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }

    /// The heart and the hidden mark, on a dark plate as the grid's marks are.
    @ViewBuilder private var marks: some View {
        if person.isFavorite == true || person.isHidden {
            HStack(spacing: 4) {
                if person.isFavorite == true { Image(systemName: "heart.fill") }
                if person.isHidden { Image(systemName: "eye.slash") }
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.45), in: .rect(cornerRadius: 5, style: .continuous))
            .padding(6)
        }
    }

    private var accessibilityMarks: String {
        var marks: [String] = []
        if person.isFavorite == true { marks.append(String(localized: "Favorite")) }
        if person.isHidden { marks.append(String(localized: "Hidden")) }
        return marks.formatted(.list(type: .and))
    }
}

extension Notification.Name {
    /// A person was named, hidden, made a favourite or merged: the People page and the person's page read them again.
    /// Posted with the account's `AccountServices` as its object.
    static let versoPeopleChanged = Notification.Name("dev.hviid.Verso.peopleChanged")
    /// A person's face photo changed; `userInfo["personID"]` says whose.
    static let versoPersonFaceChanged = Notification.Name("dev.hviid.Verso.personFaceChanged")
}
