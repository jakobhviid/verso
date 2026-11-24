import Foundation

/// Library's Years, Months and All Photos, as in Photos. What Years and Months show is arranged by the shared core
/// (`overviewYears` and `overviewPicks`, verso-core's `overview` through the bridge), as on Linux.
enum LibraryMode: String, CaseIterable, Identifiable {
    case years, months, all
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .years: "Years"
        case .months: "Months"
        case .all: "All Photos"
        }
    }
}
