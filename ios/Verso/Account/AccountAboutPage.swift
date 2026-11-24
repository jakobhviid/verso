// About Verso on iOS, in the account's sheet: what the Mac's About panel says (mac/Verso/Verso/App/VersoAbout.swift).
// The version, the non-affiliation notice (Info.plist's NSHumanReadableCopyright, the copyright line on every
// platform), the credits, the AI disclosure, and the third-party notices the app carries.

import SwiftUI
import UIKit

struct AccountAboutPage: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    if let icon = UIImage.versoAppIcon {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 88, height: 88)
                            .clipShape(.rect(cornerRadius: 20, style: .continuous))
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: "Verso")
                        .font(.title2.weight(.semibold))
                    Text("Version \(Self.version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                Text("Your Immich photos and videos, on your \(UIDevice.current.model). By Jakob Hviid, under the MIT license.")
                Text(Self.notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Built from Immich Gallery") {
                Link(destination: URL(string: "https://github.com/IGOLz/ImmichGallery")!) {
                    Text("Immich Gallery for the Mac, by Alessandro Craciun, with contributions by Jakob Hviid")
                }
            }
            Section("The Drive and the Immich API Layer") {
                Text("[Immich Mount](https://jakob.hviid.phd/immich-mount/), whose API layer started from [immich-rs](https://github.com/boul2gom/immich-rs)")
            }
            Section("AI Disclosure") {
                Text("Parts of this project were written with the assistance of AI coding agents. All changes are reviewed by the maintainer.")
            }
            Section {
                NavigationLink("Third-Party Notices") {
                    AccountNoticesPage()
                }
            }
        }
        .navigationTitle("About Verso")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The release line's version and the build, as `--version` and the user agent say it.
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        guard let build = info["CFBundleVersion"] as? String, build != version else { return version }
        return "\(version) (\(build))"
    }

    /// The non-affiliation notice the app's Info.plist carries, which SPEC.md words.
    private static var notice: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "Verso is an independent, unofficial project. It is not affiliated with, endorsed by, or sponsored by the Immich project or FUTO. “Immich” is used only to describe the server this software works with, and remains the mark of its owner."
    }

}

/// THIRD-PARTY-NOTICES.md, which the app carries: the licenses of the code Verso is built from.
private struct AccountNoticesPage: View {
    @State private var notices: AttributedString?

    var body: some View {
        ScrollView {
            Group {
                if let notices {
                    Text(notices)
                } else {
                    Text("The notices could not be read.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Third-Party Notices")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            notices = (try? AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        }
    }
}
