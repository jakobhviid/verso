// Making a shared link, or changing one, in a sheet: what it is called, its own address, a password, until when it
// works, and what visitors may do. A new link's address follows, to copy or share; made from the share sheet's Create
// Link… (ShareLinkActivity), it opens in a share sheet at once, and the form is the share sheet's to close.

import SwiftUI

struct SharedLinkForm: View {
    let session: LibrarySession
    /// The link to change; nil for a new one.
    var link: SharedLink?
    /// The album a new link shares, or nil for chosen photos.
    var albumID: String?
    /// The photos a new link to chosen photos shares.
    var assetIDs: [String] = []
    /// Shown by the share sheet's Create Link…: told when it is done, with whether a link was made, in place of closing
    /// itself, as the share sheet closes it.
    var finish: ((Bool) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var options = SharingOptions()
    @State private var expires = false
    @State private var expiry = Date().addingTimeInterval(7 * 86_400)
    @State private var keepsPassword = true
    @State private var busy = false
    @State private var error: String?
    /// The new link's address, once it is made.
    @State private var madeAddress: URL?
    /// The new link's address in a share sheet, from the share sheet's Create Link….
    @State private var sharedAddress: SharedLinkAddress?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                if let madeAddress {
                    made(madeAddress)
                } else {
                    fields
                }
            }
            .navigationTitle(link == nil ? "New Link" : "Edit Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .alert(errorTitle, isPresented: errorShown) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .sensoryFeedback(.success, trigger: copied)
            // Sent or copied, the share sheet's Create Link… is done; closed, the address shows here still.
            .shareSheet(address: $sharedAddress) { completed in if completed { close(made: true) } }
        }
        // The share sheet's form closes only through Cancel or Done, which tell the share sheet.
        .interactiveDismissDisabled(busy || finish != nil)
        .onAppear(perform: fillFromLink)
    }

    /// Closes the form, or tells the share sheet it is done, which closes it.
    private func close(made: Bool) {
        if let finish { finish(made) } else { dismiss() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if madeAddress != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { close(made: true) }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { close(made: false) }
                    .disabled(busy)
            }
            ToolbarItem(placement: .confirmationAction) {
                if busy {
                    ProgressView()
                } else {
                    Button(link == nil ? "Create" : "Save") { Task { await save() } }
                }
            }
        }
    }

    @ViewBuilder private var fields: some View {
        Section {
            TextField("Description", text: $options.description)
            TextField("Custom Address", text: $options.slug)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } footer: {
            Text("A custom address replaces the link's random one, so it is easier to type.")
        }
        Section {
            if link?.hasPassword == true {
                Toggle("Keep the Password", isOn: $keepsPassword)
            }
            if link?.hasPassword != true || !keepsPassword {
                SecureField("Password", text: $options.password)
            }
        } header: {
            Text("Password")
        } footer: {
            Text("Without a password, anyone with the link can open it.")
        }
        Section {
            Toggle("Expires", isOn: $expires)
            if expires {
                DatePicker("Works Until", selection: $expiry, in: min(Date(), expiry)...)
            }
        }
        Section {
            Toggle("Show Metadata", isOn: $options.showMetadata)
                .onChange(of: options.showMetadata) { _, shown in if !shown { options.allowDownload = false } }
            Toggle("Allow Download", isOn: $options.allowDownload)
                .disabled(!options.showMetadata)
            Toggle("Allow Upload", isOn: $options.allowUpload)
        } header: {
            Text("Visitors")
        } footer: {
            if options.allowUpload {
                Text("Visitors can upload photos to your account.")
            } else {
                Text("Metadata is each photo's details, such as its date, place and camera.")
            }
        }
    }

    private func made(_ address: URL) -> some View {
        SharedLinkAddressSection(address: address, title: "Link Created", footer: madeFooter, copied: $copied)
    }

    private var errorTitle: String { link == nil ? "Couldn't Make the Link" : "Couldn't Save the Link" }

    /// Who can open the new link.
    private var madeFooter: String {
        options.password.isEmpty ? "Anyone with the link can open it." : "Anyone with the link and its password can open it."
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })
    }

    private func fillFromLink() {
        guard let link else { return }
        options.description = link.description ?? ""
        options.slug = link.slug ?? ""
        options.allowDownload = link.allowDownload
        options.allowUpload = link.allowUpload
        options.showMetadata = link.showMetadata
        if let date = link.expiresAt.flatMap(ImmichDate.parse) {
            expires = true
            expiry = date
        }
    }

    private func save() async {
        error = nil
        busy = true
        defer { busy = false }
        options.expiresAt = expires ? expiry.ISO8601Format() : nil
        do {
            if let link {
                // The server says only whether a link has a password; its masked value is never sent back.
                let edited = try await session.client.editSharedLink(link.id, options: options,
                                                                     keepPassword: link.hasPassword && keepsPassword)
                session.services.linkPreviews.forget(edited.id)
                await session.sharing.reload()
                close(made: true)
            } else {
                let created = try await session.client.createSharedLink(albumID: albumID, assetIDs: assetIDs, options: options)
                await session.sharing.reload()
                let address = try await SharedLinkAddresses.shared.address(created, client: session.client)
                madeAddress = address
                if finish != nil { sharedAddress = SharedLinkAddress(url: address) }
            }
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }
}

/// A link's address with Copy Link and Share Link, once it is made or photos were added to it.
struct SharedLinkAddressSection: View {
    let address: URL
    let title: LocalizedStringKey
    let footer: String
    @Binding var copied: Bool

    var body: some View {
        Section {
            Text(address.absoluteString)
                .textSelection(.enabled)
                .font(.callout.monospaced())
            Button("Copy Link", systemImage: "doc.on.doc") {
                SharedLinkAddresses.copy(address)
                copied.toggle()
            }
            ShareLink(item: address) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}
