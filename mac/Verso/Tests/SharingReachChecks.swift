// How far an album or a link reaches (Verso/Views/Sharing/SharingReach.swift): the widest of its people and its
// links still working, one icon for each (ARCHITECTURE.md, "Verso on the Mac").
import Foundation

@main struct SharingReachChecks {
    static func main() {
        func link(password: Bool, expires: Date? = nil) -> SharedLink {
            SharedLink(id: UUID().uuidString, key: "key", type: "ALBUM", slug: nil, description: nil,
                       expiresAt: expires?.ISO8601Format(), password: password ? "secret" : nil, allowDownload: true,
                       allowUpload: false, showMetadata: true, assets: [], album: nil)
        }
        let past = Date(timeIntervalSinceNow: -86_400), future = Date(timeIntervalSinceNow: 86_400)
        precondition(SharingReach.album(people: 0, links: []) == .personal, "nobody and no link is private")
        precondition(SharingReach.album(people: 2, links: []) == .people(2), "people without a link")
        precondition(SharingReach.album(people: 2, links: [link(password: true)]) == .passwordLink, "a password link reaches further than people")
        precondition(SharingReach.album(people: 0, links: [link(password: true), link(password: false, expires: future)]) == .publicLink,
                     "one working public link makes it public")
        precondition(SharingReach.album(people: 1, links: [link(password: false, expires: past)]) == .people(1), "an expired link reaches nobody")
        precondition(SharingReach.album(people: 0, links: [link(password: false, expires: past)]) == .personal, "only expired links is private")
        precondition(SharingReach.link(link(password: true)) == .passwordLink && SharingReach.link(link(password: false)) == .publicLink)
        precondition(!SharingReach.personal.isShared && SharingReach.people(1).isShared && SharingReach.publicLink.isShared)
        precondition(link(password: false, expires: past).isExpired && !link(password: false, expires: future).isExpired
                     && !link(password: false).isExpired)
        print("PASS sharing reach: private, people, a link with a password, a public link; expired links reach nobody")
    }
}
