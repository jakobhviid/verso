// The question about a certificate the iPhone or iPad does not trust (CertificateQuestion; ARCHITECTURE.md, "A
// certificate of the server's own"), as a sheet over the sign-in or the library, in iOS's own list: what it is and why
// that matters, the certificate's details to compare, then Trust This Certificate in red, which is the person's
// decision alone, and Cancel, which the toolbar's close button and dragging the sheet away also are.

import SwiftUI

struct CertificateQuestionSheet: View {
    let question: CertificateQuestion
    let trust: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: question.changed ? "exclamationmark.triangle.fill" : "lock.trianglebadge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(question.changed ? .red : .orange)
                            .accessibilityHidden(true)
                        Text(question.heading)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text(question.body)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                }
                Section {
                    ForEach(question.details) { detail in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detail.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(detail.value)
                                .font(detail.fingerprint ? .callout.monospaced() : .body)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                    Button("Trust This Certificate", role: .destructive) {
                        dismiss()
                        trust()
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("trustCertificate")
                    Button("Cancel", role: .cancel) { dismiss() }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("cancelCertificate")
                }
            }
            .navigationTitle("Server Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("closeCertificate")
                }
            }
        }
    }
}
