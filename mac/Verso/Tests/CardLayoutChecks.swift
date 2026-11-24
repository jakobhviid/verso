// swiftc -parse-as-library Verso/App/CardLayout.swift Tests/CardLayoutChecks.swift -o build/check-card-layout && build/check-card-layout
import CoreGraphics
import Foundation

@main struct CardLayoutChecks {
    static func main() {
        let albums = CardLayout(widths: [200, 240, 300, 370, 450])

        // As SwiftUI's adaptive columns count: as many least widths as fit, with the spacing between them.
        precondition((0...4).map { albums.cardsPerLine($0, lineWidth: 900) } == [4, 3, 2, 2, 1])
        precondition(albums.cardsPerLine(0, lineWidth: 860) == 4) // 4 × 200 + 3 × 20, exactly
        precondition(albums.cardsPerLine(0, lineWidth: 859) == 3)
        precondition(albums.cardsPerLine(4, lineWidth: 100) == 1) // never none

        // A step skips a size that fits as many cards in a line: at 900 wide, sizes 2 and 3 both fit two.
        precondition(albums.size(from: 1, step: 1, lineWidth: 900) == 2)
        precondition(albums.size(from: 2, step: 1, lineWidth: 900) == 4)
        precondition(albums.size(from: 3, step: -1, lineWidth: 900) == 1)
        precondition(albums.size(from: 4, step: -1, lineWidth: 900) == 3)
        // At the ends, none: − and + are off.
        precondition(albums.size(from: 4, step: 1, lineWidth: 900) == nil)
        precondition(albums.size(from: 0, step: -1, lineWidth: 900) == nil)
        // A narrow window fits one card at every size: no step changes anything.
        precondition(albums.size(from: 0, step: 1, lineWidth: 300) == nil)
        precondition(albums.size(from: 3, step: -1, lineWidth: 300) == nil)
        // Before the page knows its width, the next size.
        precondition(albums.size(from: 2, step: 1, lineWidth: 0) == 3)
        precondition(albums.size(from: 4, step: 1, lineWidth: 0) == nil)
        precondition(albums.size(from: 0, step: -1, lineWidth: 0) == nil)
        // A size stored out of range counts as the nearest; a step of 0 goes nowhere.
        precondition(albums.size(from: 7, step: -1, lineWidth: 900) == 3)
        precondition(albums.size(from: 2, step: 0, lineWidth: 900) == nil)

        // People's tiles, closer together.
        let people = CardLayout(widths: [120, 150, 190, 240, 300], spacing: 16)
        precondition((0...4).map { people.cardsPerLine($0, lineWidth: 1000) } == [7, 6, 4, 3, 3])
        precondition(people.size(from: 3, step: 1, lineWidth: 1000) == nil)
        precondition(people.size(from: 4, step: -1, lineWidth: 1000) == 2)

        // At every width, a step lands on the nearest size that changes the count, passing only sizes that do not,
        // and there is none only where no size beyond changes it.
        for layout in [albums, people, CardLayout(widths: [170, 210, 260, 320, 400]), CardLayout(widths: [240, 300, 370, 450, 520])] {
            for lineWidth in stride(from: CGFloat(100), through: 2600, by: 7) {
                for size in 0...4 {
                    let shown = layout.cardsPerLine(size, lineWidth: lineWidth)
                    for step in [1, -1] {
                        let beyond = Array(stride(from: size + step, through: step > 0 ? 4 : 0, by: step))
                        if let next = layout.size(from: size, step: step, lineWidth: lineWidth) {
                            precondition(layout.cardsPerLine(next, lineWidth: lineWidth) != shown)
                            let passed = beyond.prefix { $0 != next }
                            precondition(passed.allSatisfy { layout.cardsPerLine($0, lineWidth: lineWidth) == shown })
                        } else {
                            precondition(beyond.allSatisfy { layout.cardsPerLine($0, lineWidth: lineWidth) == shown })
                        }
                    }
                }
            }
        }
        print("Card layout checks passed.")
    }
}
