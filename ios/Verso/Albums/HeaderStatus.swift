// A page header's controls on iOS, as on the Mac and Linux (DESIGN.md, "A page header's controls are statuses"): a
// status that can be changed (an album's reach, a person's Favorite) or an action on the page (Add Photos), each its
// icon in the accent colour and its state or name in the body's text, without a button's frame, lit while a finger is
// on it. They flow in a row under the page's details and wrap onto a second line where the phone is too narrow; the
// thin rule between the statuses and the actions shows only between two on the same line.

import SwiftUI

/// A header's status or action (`.buttonStyle(.headerStatus)`).
struct HeaderStatusStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { HeaderStatusBody(configuration: configuration) }
}

private struct HeaderStatusBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .labelStyle(HeaderStatusLabelStyle(isEnabled: isEnabled))
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(configuration.isPressed ? 1 : 0),
                        in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect(cornerRadius: 8, style: .continuous))
    }
}

/// The icon in the accent colour, which says it can be tapped; the state or name in the body's colour.
private struct HeaderStatusLabelStyle: LabelStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            configuration.title.foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
    }
}

extension ButtonStyle where Self == HeaderStatusStyle {
    /// A header's status or action (`HeaderStatusStyle`).
    static var headerStatus: HeaderStatusStyle { HeaderStatusStyle() }
}

/// A header's statuses and actions, left to right, wrapping onto the next line as they need. Its first item lines its
/// icon up with the header's text, so the row starts a status's padding to the left of the header's margin.
struct HeaderStatusRow: Layout {
    var spacing: CGFloat = 2
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = arrange(subviews, width: bounds.width)
        var top = bounds.minY
        var placed = Set<Int>()
        for line in lines {
            var left = bounds.minX
            for index in line.indices {
                let item = subviews[index]
                let size = item[HeaderStatusRuleKey.self] ? CGSize(width: ruleWidth, height: line.height * 0.6)
                    : itemSize(item, width: bounds.width)
                item.place(at: CGPoint(x: left, y: top + (line.height - size.height) / 2),
                           proposal: ProposedViewSize(size))
                placed.insert(index)
                left += size.width + spacing
            }
            top += line.height + lineSpacing
        }
        // A rule that would start or end a line is not drawn.
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: bounds.origin, proposal: .zero)
        }
    }

    /// The width a rule takes between two items.
    private let ruleWidth: CGFloat = 17

    /// An item's own size, narrowed to the row where it is wider, so its text shortens rather than spilling out.
    private func itemSize(_ item: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = item.sizeThatFits(.unspecified)
        guard ideal.width > width else { return ideal }
        return item.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index][HeaderStatusRuleKey.self] ? CGSize(width: ruleWidth, height: 0)
                : itemSize(subviews[index], width: width)
            let needed = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if needed > width, !line.indices.isEmpty {
                lines.append(line)
                line = Line()
            }
            line.indices.append(index)
            line.width = line.indices.count == 1 ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
        }
        if !line.indices.isEmpty { lines.append(line) }
        // A rule at either end of a line separates nothing there.
        return lines.map { line in
            var trimmed = line
            while let first = trimmed.indices.first, subviews[first][HeaderStatusRuleKey.self] {
                trimmed.indices.removeFirst()
                trimmed.width -= ruleWidth + spacing
            }
            while let last = trimmed.indices.last, subviews[last][HeaderStatusRuleKey.self] {
                trimmed.indices.removeLast()
                trimmed.width -= ruleWidth + spacing
            }
            return trimmed
        }
        .filter { !$0.indices.isEmpty }
    }
}

private struct HeaderStatusRuleKey: LayoutValueKey {
    static let defaultValue = false
}

/// The thin rule between a header's statuses and its actions.
struct HeaderStatusRule: View {
    var body: some View {
        HStack {
            Rectangle()
                .fill(.separator)
                .frame(width: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .layoutValue(key: HeaderStatusRuleKey.self, value: true)
    }
}
