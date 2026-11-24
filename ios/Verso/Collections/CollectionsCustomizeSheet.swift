// Customize, Collections' own Edit Sidebar (ROADMAP.md, M10), as Photos' Customize and Reorder: the pages the tab bar
// holds between Library and Collections, ticked and dragged into order; the sections in a list to drag into order and
// tick to show, each opening its links to drag, tick and move to another section; a section of one's own to add,
// rename or delete; and Reset. The tab bar's pages are kept on this device (TabBarChoice); every other change goes
// straight into the shared SidebarLayout, saved where the Mac's sidebar saves it.

import SwiftUI

struct CollectionsCustomizeSheet: View {
    let session: LibrarySession
    @AppStorage(collectionsLayoutKey) private var storedLayout = ""
    @AppStorage(TabBarChoice.storageKey) private var storedTabBar = ""
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var naming = false
    @State private var newName = ""
    @State private var confirmingReset = false

    private var layout: SidebarLayout { SidebarLayout(stored: storedLayout) }
    private var tabBar: [TabBarChoice] { TabBarChoice.decode(storedTabBar) }

    var body: some View {
        NavigationStack(path: $path) {
            let layout = self.layout
            let sections = listedSections(layout)
            List {
                tabBarSection
                Section {
                    ForEach(sections) { section in
                        HStack(spacing: 12) {
                            CollectionsShownButton(shown: !section.hidden, title: section.collectionsLabel) {
                                update { $0.setSectionHidden(!section.hidden, id: section.id) }
                            }
                            section.collectionsLabel
                                .foregroundStyle(section.hidden ? .secondary : .primary)
                            Spacer()
                            Button {
                                path.append(section.id)
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Edit \(section.collectionsLabel)"))
                        }
                    }
                    .onMove { source, destination in moveSection(from: source, to: destination, among: sections) }
                } header: {
                    Text("Sections")
                } footer: {
                    Text("Drag sections into the order you want, and tick those to show. Open a section to choose and order what it shows.")
                }
                Section {
                    // Controls of their own, which editing leaves working.
                    Button("New Section", systemImage: "plus") {
                        newName = ""
                        naming = true
                    }
                    .buttonStyle(.borderless)
                    Button("Reset Collections", role: .destructive) { confirmingReset = true }
                        .buttonStyle(.borderless)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { sectionID in
                CollectionsCustomizeSectionPage(session: session, sectionID: sectionID)
            }
            .alert("New Section", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Add") { update { $0.addSection(named: newName) } }
            }
            .confirmationDialog("Reset Collections?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset Collections", role: .destructive) { storedLayout = "" }
            } message: {
                Text("This restores the default sections and order, shows hidden items, and removes custom sections. Your photos and albums are not affected.")
            }
        }
    }

    // MARK: Tab Bar

    /// The pages the tab bar holds, ticked, in their order and dragged into another; then the others, to tick while
    /// the bar has room.
    private var tabBarSection: some View {
        let chosen = tabBar
        let full = chosen.count >= TabBarChoice.most
        return Section {
            ForEach(chosen) { choice in
                tabBarRow(choice, chosen: true) { saveTabBar(chosen.filter { $0 != choice }) }
            }
            .onMove { source, destination in
                var moved = chosen
                moved.move(fromOffsets: source, toOffset: min(destination, moved.count))
                saveTabBar(moved)
            }
            ForEach(TabBarChoice.allCases.filter { !chosen.contains($0) }) { choice in
                tabBarRow(choice, chosen: false) { saveTabBar(chosen + [choice]) }
                    .disabled(full)
            }
        } header: {
            Text("Tab Bar")
        } footer: {
            Text("Library and Collections are always in the tab bar. Tick up to \(TabBarChoice.most) pages to go between them, and drag them into order. A page in the tab bar leaves Collections.")
        }
    }

    private func tabBarRow(_ choice: TabBarChoice, chosen: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            CollectionsShownButton(shown: chosen, title: Text(LocalizedStringKey(choice.title)),
                                   hint: Text("Puts it in the tab bar or takes it out"), action: toggle)
            Label { Text(LocalizedStringKey(choice.title)) } icon: { Image(systemName: choice.systemImage) }
                .foregroundStyle(chosen ? .primary : .secondary)
        }
    }

    /// Keeps the tab bar's pages. A bar of Library and Collections alone is kept as a lone comma, which reads back as
    /// no pages, as nothing kept means the defaults.
    private func saveTabBar(_ choices: [TabBarChoice]) {
        storedTabBar = TabBarChoice.encode(choices)
    }

    // MARK: Sections

    /// The sections Collections can show: a section of one's own always, a built-in one while it holds a link
    /// Collections lists, which leaves out Photos, whose links are the Library's, My Albums and Shared Albums, whose
    /// albums are in the Albums block, and a section whose pages the tab bar holds.
    private func listedSections(_ layout: SidebarLayout) -> [SidebarSection] {
        layout.sections.filter { section in
            section.isCustom || !session.collectionsLinks(in: section.id, layout: layout, tabBar: tabBar).isEmpty
        }
    }

    /// A drag among the listed sections, made a move in the layout's whole list, where the unlisted keep their place.
    private func moveSection(from source: IndexSet, to destination: Int, among listed: [SidebarSection]) {
        // Dropped where it was.
        guard let from = source.first, listed.indices.contains(from), destination != from, destination != from + 1 else { return }
        let moving = listed[from].id
        update { layout in
            guard let current = layout.sections.firstIndex(where: { $0.id == moving }) else { return }
            let anchor = destination < listed.count ? listed[destination].id : listed[listed.count - 1].id
            guard var target = layout.sections.firstIndex(where: { $0.id == anchor }) else { return }
            if target > current { target -= 1 }
            if destination >= listed.count { target += 1 }
            layout.shiftSection(id: moving, by: target - current)
        }
    }

    private func update(_ change: (inout SidebarLayout) -> Void) {
        var updated = layout
        change(&updated)
        if updated.stored != storedLayout { storedLayout = updated.stored }
    }
}

/// One section's links: dragged into order, ticked to show, moved to another section; a section of one's own renamed
/// or deleted.
private struct CollectionsCustomizeSectionPage: View {
    let session: LibrarySession
    let sectionID: String
    @AppStorage(collectionsLayoutKey) private var storedLayout = ""
    @AppStorage(TabBarChoice.storageKey) private var storedTabBar = ""
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false

    private var layout: SidebarLayout { SidebarLayout(stored: storedLayout) }

    var body: some View {
        let layout = self.layout
        let section = layout.sections.first { $0.id == sectionID }
        let links = session.collectionsLinks(in: sectionID, layout: layout, tabBar: TabBarChoice.decode(storedTabBar))
        List {
            Section {
                ForEach(links, id: \.self) { link in
                    HStack(spacing: 12) {
                        CollectionsShownButton(shown: !layout.isHidden(link), title: Text(link.collectionsTitle)) {
                            update { $0.setHidden(!layout.isHidden(link), link: link) }
                        }
                        Label { Text(link.collectionsTitle) } icon: { Image(systemName: link.collectionsSymbol) }
                            .foregroundStyle(layout.isHidden(link) ? .secondary : .primary)
                        Spacer()
                        moveMenu(link, layout: layout)
                    }
                }
                .onMove { source, destination in
                    guard let from = source.first, links.indices.contains(from) else { return }
                    update { $0.move(links[from], to: sectionID, at: destination, among: links) }
                }
            } footer: {
                if links.isEmpty {
                    Text("Move items here from another section with the arrow beside them.")
                }
            }
            if section?.isCustom == true {
                Section {
                    Button("Rename Section") {
                        newName = section?.name ?? ""
                        renaming = true
                    }
                    .buttonStyle(.borderless)
                    Button("Delete Section", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(.borderless)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(section?.collectionsLabel ?? Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Section", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { update { $0.renameSection(id: sectionID, to: newName) } }
        }
        .confirmationDialog("Delete this custom section?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Section", role: .destructive) {
                update { $0.removeSection(id: sectionID) }
                dismiss()
            }
        } message: {
            Text("Items return to their default sections. Your photos and albums are not deleted.")
        }
    }

    /// Move to Section, beside the link: the other sections, by name.
    private func moveMenu(_ link: SidebarLink, layout: SidebarLayout) -> some View {
        Menu {
            Section("Move to Section") {
                ForEach(layout.sections.filter { $0.id != sectionID }) { destination in
                    Button {
                        update { $0.move(link, to: destination.id) }
                    } label: {
                        destination.collectionsLabel
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.turn.up.right")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Move to Section"))
    }

    private func update(_ change: (inout SidebarLayout) -> Void) {
        var updated = layout
        change(&updated)
        if updated.stored != storedLayout { storedLayout = updated.stored }
    }
}

/// Photos' tick in Customize: a filled checkmark while shown, an empty circle while hidden.
private struct CollectionsShownButton: View {
    let shown: Bool
    let title: Text
    var hint = Text("Shows or hides it in Collections")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(shown ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityValue(shown ? Text("Shown") : Text("Hidden"))
        .accessibilityHint(hint)
    }
}
