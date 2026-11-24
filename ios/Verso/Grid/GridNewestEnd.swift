// Which end of a timeline its newest photos are at on iOS: the bottom, as Photos' Library has them, by default, or the
// top. One setting, kept on this device, for every grid that opens at its newest photos (AssetGridPage's timelines: the
// Library, Favorites, Videos, the Archive, Recently Deleted, a person's photos and the like), in each one's View
// Options; an album keeps its own sort and order, as on the Mac. Everything that knows where the newest end is follows
// it: where the grid opens and lands (TimelineGrid), the way scrolling shrinks the tab bar and when Years, Months and
// All show (LibraryTabs), the line under the title, the viewer's order, and Years and Months (LibraryOverviewPage).

import SwiftUI

enum GridNewestEnd: String, CaseIterable, Identifiable {
    case bottom, top

    /// The `@AppStorage` key it is kept under.
    static let storageKey = "grid.newestEnd"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .bottom: "Newest at the Bottom"
        case .top: "Newest at the Top"
        }
    }
}

/// View Options' choice of the end a timeline's newest photos are at, as a menu's checked pair.
struct GridNewestEndPicker: View {
    @AppStorage(GridNewestEnd.storageKey) private var newestEnd = GridNewestEnd.bottom

    var body: some View {
        Picker(selection: $newestEnd) {
            ForEach(GridNewestEnd.allCases) { end in
                Text(end.title).tag(end)
            }
        } label: {
            Text("Newest Photos")
        }
        .pickerStyle(.inline)
    }
}
