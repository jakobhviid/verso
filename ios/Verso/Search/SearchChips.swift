// Search's suggestions and filters as glass chips (ROADMAP.md, M10): the system's glass button style, laid out to wrap
// line after line, or in a row that scrolls sideways. The chips are controls on the page's own background, never on
// photos.

import SwiftUI

/// Chips that wrap onto as many lines as they need, each line starting at the leading edge.
struct SearchChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let height = lines.last.map { $0.top + $0.height } ?? 0
        let width = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for line in arrange(subviews, width: bounds.width) {
            var leading = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: leading, y: bounds.minY + line.top), proposal: ProposedViewSize(size))
                leading += size.width + spacing
            }
        }
    }

    private struct Line {
        var indices: [Int] = []
        var top: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !line.indices.isEmpty, line.width + spacing + size.width > width {
                lines.append(line)
                line = Line(top: line.top + line.height + spacing)
            }
            line.width += (line.indices.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

/// A chip: a symbol, or a picture in a rounded square (a person's face), and its title.
struct SearchChip<Picture: View>: View {
    let title: Text
    let action: () -> Void
    @ViewBuilder let picture: Picture

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                picture
                title.lineLimit(1)
            }
        }
        .buttonStyle(.glass)
    }
}

extension SearchChip where Picture == Image {
    init(_ title: Text, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        self.picture = Image(systemName: systemImage)
    }
}

/// A person as a chip: the face in a small rounded square, then the name.
struct SearchPersonChip: View {
    let pipeline: ImagePipeline
    let person: Person
    let action: () -> Void

    var body: some View {
        SearchChip(title: person.name.isEmpty ? Text("Unnamed Person") : Text(verbatim: person.name), action: action) {
            CollectionsFace(pipeline: pipeline, personID: person.id)
                .frame(width: 24, height: 24)
                .clipShape(.rect(cornerRadius: 6))
        }
    }
}

/// The filters set on a search, each a chip that takes it off, and Clear, which takes off all of them.
struct SearchFilterChips: View {
    let query: SearchQuery
    let remove: (SearchQuery.Filter) -> Void
    let clear: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(query.filterChips, id: \.id) { chip in
                        Button {
                            remove(chip.id)
                        } label: {
                            HStack(spacing: 4) {
                                Text(verbatim: chip.title).lineLimit(1)
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel(Text("Remove \(chip.title) filter"))
                    }
                    if query.filterChips.count > 1 {
                        Button("Clear", action: clear)
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollIndicators(.hidden)
    }
}
