// The Library's offer to back up (SPEC.md, "Backing the iPhone up"): a glass card above the tab bar, by the newest
// photos where the Library opens, while backing up is off on the account's own server. Set Up opens the Backup page,
// where it is switched on and started; Not Now hides the card on this device for good, and the account's sheet still
// leads to the page.

import SwiftUI

struct BackupInvitationCard: View {
    private var center: BackupCenter { BackupCenter.shared }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "icloud.and.arrow.up")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Back Up This \(DeviceWords.model)")
                    .font(.headline)
                Text("Send your photos and videos to Immich. Nothing goes until you have seen what is already there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Not Now") { center.dismissInvitation() }
                        .buttonStyle(.glass)
                    Button("Set Up") { center.showPage() }
                        .buttonStyle(.glassProminent)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("Backup Invitation")
    }
}
