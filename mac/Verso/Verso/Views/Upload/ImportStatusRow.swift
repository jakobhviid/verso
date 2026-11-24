import SwiftUI

/// How an import is going, as the foot of the sidebar shows it (`ImportStatusRow`).
struct ImportStatus: Equatable {
    enum Phase { case working, done, attention }
    var phase: Phase
    var title: String
    /// A quieter line under the title once the import ended: what else it came to, or why it stopped.
    var detail: String?
    /// While it works: how far, or nil while files are still being looked for.
    var progress: Double?
    var canRetry = false

    var symbol: String {
        switch phase {
        case .working: "arrow.up"
        case .done: "checkmark"
        case .attention: "exclamationmark"
        }
    }

    var tint: Color {
        switch phase {
        case .working: .accentColor
        case .done: .green
        case .attention: .orange
        }
    }
}

/// The import at the foot of the sidebar, just above the account and laid out as its row is: where the account has
/// its picture, a circle of the same size says how the import is going (an arrow while files are sent, a tick once
/// they all came in, an exclamation mark when something needs a look); where it has its name, the import's title;
/// where it has the server, a progress bar while files are sent and a quieter line after. A click on it shows each
/// file, as Mail's activity at the foot of its sidebar does; Retry beside it when something failed; the cross cancels
/// it while it runs and closes it after.
struct ImportStatusRow: View {
    let status: ImportStatus
    var showDetails: () -> Void = {}
    var retry: () -> Void = {}
    /// Cancel while it works, Close once it ended.
    var stop: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(status.tint)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: status.symbol)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title).lineLimit(1)
                    if status.phase == .working {
                        Group {
                            if let progress = status.progress { ProgressView(value: progress) } else { ProgressView() }
                        }
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .padding(.top, 3)
                    } else if let detail = status.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: showDetails)
            .help("Show Each File")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Show Each File"), showDetails)
            if status.canRetry {
                Button(action: retry) { Image(systemName: "arrow.clockwise") }
                    .foregroundStyle(.secondary)
                    .help("Retry")
                    .accessibilityLabel("Retry")
            }
            Button(action: stop) { Image(systemName: "xmark.circle.fill") }
                .foregroundStyle(.secondary)
                .help(status.phase == .working ? "Cancel" : "Close")
                .accessibilityLabel(status.phase == .working ? "Cancel" : "Close")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
