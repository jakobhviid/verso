// Verso's widget extension on iOS: for now backing up's Live Activity (BackupActivityAttributes), on the Lock Screen and
// in the Dynamic Island, which the app starts while it is open and keeps up to date from the background
// (BackupLiveActivity). A tap opens the Backup page through the app's own link (`<scheme>://backup`).

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VersoWidgets: WidgetBundle {
    var body: some Widget {
        BackupActivityWidget()
    }
}

struct BackupActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BackupActivityAttributes.self) { context in
            BackupLockScreen(state: context.state)
                .padding(16)
                .widgetURL(Self.backupPage)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BackupLens(state: state, size: 44, line: 3)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.total > 0, state.stage != .done {
                        Text("\(state.done.formatted()) of \(state.total.formatted())")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.headline)
                        Text(state.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                BackupLens(state: state, size: 24, line: 2)
            } compactTrailing: {
                if state.stage == .done {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                } else if state.total > 0 {
                    Text("\(state.done)/\(state.total)")
                        .font(.caption2.monospacedDigit())
                }
            } minimal: {
                BackupLens(state: state, size: 24, line: 2)
            }
            .widgetURL(Self.backupPage)
        }
    }

    /// The app's own link to its Backup page, by the scheme its Info.plist names (Verso's or Verso Dev's).
    static var backupPage: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "VersoURLScheme") as? String).flatMap { URL(string: "\($0)://backup") }
    }
}

/// The Lock Screen's activity: the lens in its ring, what is happening and how far.
private struct BackupLockScreen: View {
    let state: BackupActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            BackupLens(state: state, size: 52, line: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title).font(.headline)
                Text(state.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Verso's lens, from its app icon (Lens, written by mac/Verso/make-icons.py, its colours to its edge), close inside a
/// ring that fills as the run goes, in the stage's colour: the accent while it works, grey while it waits, green when
/// done, orange when the person is needed. Full when done or stopped. A point of space between the two, no more, so
/// the lens is as large as the ring leaves room for.
private struct BackupLens: View {
    let state: BackupActivityAttributes.ContentState
    let size: CGFloat
    let line: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: line)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image("Lens")
                .resizable()
                .scaledToFit()
                .padding(line / 2 + max(1, size / 40))
        }
        .padding(line / 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var progress: Double {
        switch state.stage {
        case .done, .stopped: 1
        case .checking, .backingUp, .waiting: state.fraction
        }
    }

    private var tint: Color {
        switch state.stage {
        case .checking, .backingUp: .accentColor
        case .waiting: .secondary
        case .done: .green
        case .stopped: .orange
        }
    }
}
