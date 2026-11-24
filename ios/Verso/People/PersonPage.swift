// A person's page: their photos (AssetGridPage over the person's source), their name the large title in the bar's
// row, under a header drawn as the Mac's (mac/Verso/Verso/Views/People/PersonDetailView.swift): the face, how many
// photos, the birthday with the age (a tap edits it, Add Birthday where there is none), and a row of statuses and
// actions (HeaderStatus.swift): Favorite and Shown or Hidden, each naming what is so and changed with a tap (DESIGN.md,
// "The apps' interfaces"), then Merge and Rename (Add Name for someone unnamed). Route.person pushes it, from People
// and wherever else a person is shown.

import SwiftUI

struct PersonPage: View {
    let session: LibrarySession
    @State private var person: Person
    @State private var count: Int?
    @State private var busy = false
    @State private var error: String?
    @State private var renaming: Person?
    @State private var editingBirthday = false
    @State private var choosingMerge = false
    @State private var mergeCandidate: Person?
    /// The person chosen in the picker, asked about once the picker has closed.
    @State private var chosenCandidate: Person?

    init(session: LibrarySession, person: Person) {
        self.session = session
        _person = State(initialValue: person)
    }

    var body: some View {
        AssetGridPage(session: session, source: .person(person.id), title: person.displayName, header: AnyView(header))
            .task(id: person.id) { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: .versoPeopleChanged, object: session.services)) { _ in
                Task { await reload() }
            }
            .personRenameAlert($renaming) { _, name in save(PersonEdit(name: name)) }
            .sheet(isPresented: $editingBirthday) {
                PersonBirthdaySheet(session: session, person: person) { person = $0 }
            }
            .sheet(isPresented: $choosingMerge, onDismiss: askToMerge) {
                PersonMergePicker(session: session, target: person) { chosenCandidate = $0 }
            }
            .alert("Merge People?", isPresented: mergeConfirmationShown, presenting: mergeCandidate) { candidate in
                Button("Cancel", role: .cancel) {}
                Button("Merge", role: .destructive) { merge(candidate) }
            } message: { candidate in
                Text("All faces of \(candidate.displayName) will move to \(person.displayName). This cannot be undone.")
            }
            .alert("Can't Change This Person", isPresented: errorShown) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    // MARK: The header

    /// The face beside how many photos and the birthday, then the statuses and actions. The name is the bar's title.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                PersonFaceImage(pipeline: session.pipeline, personID: person.id)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    if let count {
                        Text(count == 1 ? String(localized: "1 photo or video")
                             : String(localized: "\(count.formatted()) photos and videos"))
                            .foregroundStyle(.secondary)
                    }
                    birthday
                }
                .font(.subheadline)
            }
            statuses
                .padding(.leading, -8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    /// The birthday with the age, which a tap edits, or Add Birthday.
    @ViewBuilder private var birthday: some View {
        if let birthday = person.birthday {
            let age = Calendar.current.dateComponents([.year], from: birthday, to: .now).year ?? 0
            Button { editingBirthday = true } label: {
                Text("Born \(birthday.formatted(date: .abbreviated, time: .omitted)) · Age \(age)")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits the birthday")
        } else {
            Button("Add Birthday") { editingBirthday = true }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
    }

    /// Favorite and Shown or Hidden, each naming what is so, its icon in the accent colour, and a tap changes it; then
    /// merging someone into them and their name.
    private var statuses: some View {
        HeaderStatusRow {
            let favorite = person.isFavorite == true
            Button { save(PersonEdit(isFavorite: !favorite)) } label: {
                Label(favorite ? "Favorite" : "Not a Favorite", systemImage: favorite ? "heart.fill" : "heart")
            }
            .accessibilityHint(favorite ? "Takes them out of Favorites" : "Makes them a favorite")
            Button { save(PersonEdit(isHidden: !person.isHidden)) } label: {
                Label(person.isHidden ? "Hidden" : "Shown", systemImage: person.isHidden ? "eye.slash" : "eye")
            }
            .accessibilityHint(person.isHidden ? "Shows them in People" : "Hides them from People")
            HeaderStatusRule()
            Button("Merge…", systemImage: "person.2") { choosingMerge = true }
                .accessibilityHint("Moves another person's faces to them")
            Button(person.name.isEmpty ? "Add Name" : "Rename", systemImage: "pencil") { renaming = person }
        }
        .buttonStyle(.headerStatus)
        .disabled(busy)
    }

    // MARK: Changes

    private var mergeConfirmationShown: Binding<Bool> {
        Binding(get: { mergeCandidate != nil }, set: { shown in if !shown { mergeCandidate = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })
    }

    private func save(_ edit: PersonEdit) {
        busy = true
        Task {
            defer { busy = false }
            do { person = try await PersonEditing.save(edit, to: person.id, session: session) }
            catch { report(error) }
        }
    }

    private func askToMerge() {
        mergeCandidate = chosenCandidate
        chosenCandidate = nil
    }

    private func merge(_ candidate: Person) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await PersonEditing.merge(candidate, into: person, session: session)
                await session.gridModel(for: .person(person.id)).reload()
            } catch { report(error) }
        }
    }

    private func reload() async {
        do {
            person = try await session.client.person(person.id)
            count = try await session.client.personStatistics(person.id).assets
        } catch is CancellationError {
        } catch {
            session.handle(error)
        }
    }

    private func report(_ error: Error) {
        session.handle(error)
        self.error = error.localizedDescription
    }
}
