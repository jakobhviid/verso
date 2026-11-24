// How an import goes on iOS (ROADMAP.md, M10), as the Library's title line and the import's details sheet
// (ImportDetailsSheet) say it: a ring that fills as the files go, "Importing 12 of 40", and once it ended what it came
// to, a tick or a warning in the ring. It shows from an import's start, picked photos still being written out included
// (`ImportProgress.isShown(for:)`), and goes into the notifications at the top of the account's sheet 5 seconds after it
// ended, as into the bell on the Mac and Linux (UploadQueue).

import SwiftUI

/// How an import is going, as the Library's title line and the details sheet say it.
struct ImportProgress {
    enum Phase { case preparing, looking, working, done, attention }

    var phase: Phase
    /// "Importing 12 of 40", or what it came to.
    var title: String
    /// What else it came to, or why it stopped.
    var detail: String?
    /// How far, or nil while files are still being looked for.
    var progress: Double?
    var canRetry = false

    /// Whether there is an import to show: from its start, picked photos still being written out included, until it
    /// has gone into the notifications.
    @MainActor static func isShown(for queue: UploadQueue) -> Bool {
        queue.showsBanner || ImportCoordinator.of(queue).preparing != nil
    }

    @MainActor init(queue: UploadQueue, coordinator: ImportCoordinator) {
        if let preparing = coordinator.preparing {
            phase = .preparing
            title = "Preparing \(preparing.done) of \(preparing.total)"
            detail = "From Photos"
            progress = preparing.total == 0 ? nil : Double(preparing.done) / Double(preparing.total)
        } else if queue.isRunning {
            if queue.discovering && queue.items.isEmpty {
                phase = .looking
                title = "Looking for files…"
                progress = nil
            } else {
                phase = .working
                title = "Importing \(queue.completed) of \(queue.items.count)"
                progress = queue.progress
                var others: [String] = []
                if queue.duplicates > 0 { others.append("\(queue.duplicates) already in the library") }
                if queue.failed > 0 { others.append("\(queue.failed) not imported") }
                detail = others.isEmpty ? nil : others.joined(separator: ", ")
            }
        } else {
            let outcome = queue.outcome
            phase = outcome.needsLook ? .attention : .done
            title = outcome.title
            detail = outcome.detail
            progress = 1
            canRetry = queue.failed + queue.cancelled > 0
        }
    }
}

/// The import's ring: the accent colour filling as the files go, around an arrow; a tick on green once everything
/// came in, an exclamation mark on orange when something needs a look, as the Mac's sidebar has them. It fills as the
/// import goes, without animating on its own.
struct ImportRing: View {
    let progress: ImportProgress
    let size: CGFloat

    var body: some View {
        ZStack {
            switch progress.phase {
            case .done:
                Circle().fill(.green)
                symbol("checkmark", color: .white)
            case .attention:
                Circle().fill(.orange)
                symbol("exclamationmark", color: .white)
            case .preparing, .looking, .working:
                Circle()
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: lineWidth)
                if let fraction = progress.progress {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, fraction)))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    symbol("arrow.up", color: .accentColor)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var lineWidth: CGFloat { max(2.5, size / 10) }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(color)
    }
}
