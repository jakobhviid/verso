import SwiftUI

/// The question about a certificate the Mac does not trust (CertificateQuestion), as a sheet over the sign-in or the
/// library: what it is and why that matters, the certificate's details to compare, Cancel as the default, and Trust
/// This Certificate, which is the person's decision alone (ARCHITECTURE.md, "A certificate of the server's own").
struct CertificateQuestionSheet: View {
    let question: CertificateQuestion
    let trust: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: question.changed ? "exclamationmark.triangle.fill" : "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundStyle(question.changed ? .red : .orange)
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.heading).font(.headline)
                    Text(question.body).fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(question.details) { detail in
                    GridRow {
                        Text(detail.title)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(detail.value)
                            .font(detail.fingerprint ? .body.monospaced() : .body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Trust This Certificate", role: .destructive) {
                    dismiss()
                    trust()
                }
                .accessibilityIdentifier("trustCertificate")
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cancelCertificate")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
