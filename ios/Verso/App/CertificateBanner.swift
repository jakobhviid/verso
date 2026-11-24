// While the server's certificate is refused (ARCHITECTURE.md, "A certificate of the server's own"), a banner across
// the top of the library says so, with Check Certificate…, and the question about it (CertificateQuestionSheet) comes
// by itself once for each certificate, as on the Mac and Linux. What is shown stays; once the person trusts the
// certificate, the library reads itself again.

import SwiftUI

struct CertificateBanner: ViewModifier {
    let services: AccountServices

    func body(content: Content) -> some View {
        @Bindable var services = services
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let refused = services.refusedCertificate {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text("\(refused.host)'s certificate is not trusted, so Verso does not connect to it.")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Check Certificate…") { services.certificateRefused(asked: true) }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("checkCertificate")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("certificateBanner")
                }
            }
            .sheet(item: $services.certificateQuestion) { question in
                CertificateQuestionSheet(question: question) {
                    services.trustCertificate(question)
                }
            }
    }
}
