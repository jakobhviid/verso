// Changing a person, from the People page and from their own page, as the Mac's People do: a name, a birthday,
// Favorite and Hidden, and merging someone else into them, whose faces then move to them.

import SwiftUI

@MainActor
enum PersonEditing {
    /// Saves a change to a person and tells the pages that show people; answers the person as Immich has them now.
    static func save(_ edit: PersonEdit, to personID: String, session: LibrarySession) async throws -> Person {
        let updated = try await session.client.editPerson(personID, edit)
        changed(session)
        return updated
    }

    /// Moves every face of `source` to `target`.
    static func merge(_ source: Person, into target: Person, session: LibrarySession) async throws {
        try await session.client.mergePeople(into: target.id, ids: [source.id])
        changed(session)
    }

    /// The grids read again, since a person's name and faces show in them, and the people pages read their people.
    static func changed(_ session: LibrarySession) {
        session.invalidateGrids()
        NotificationCenter.default.post(name: .versoPeopleChanged, object: session.services)
    }
}

/// Naming a person, in an alert with a text field, as Photos names one.
struct PersonRenameAlert: ViewModifier {
    @Binding var person: Person?
    let rename: (Person, String) -> Void
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(person?.name.isEmpty == false ? Text("Rename Person") : Text("Add Name"), isPresented: shown,
                   presenting: person) { person in
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Save") { rename(person, name.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            .onChange(of: person?.id) { name = person?.name ?? "" }
    }

    private var shown: Binding<Bool> {
        Binding(get: { person != nil }, set: { shownNow in if !shownNow { person = nil } })
    }
}

extension View {
    /// Asks for a name for `person` while it is set.
    func personRenameAlert(_ person: Binding<Person?>, rename: @escaping (Person, String) -> Void) -> some View {
        modifier(PersonRenameAlert(person: person, rename: rename))
    }
}

/// A person's birthday, in a sheet with the date wheels Contacts has, or removed.
struct PersonBirthdaySheet: View {
    let session: LibrarySession
    let person: Person
    let saved: (Person) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var birthday = Date.now
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Birthday", selection: $birthday, in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                if person.birthday != nil {
                    Section {
                        Button("Remove Birthday", role: .destructive) { save(nil) }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(person.birthday == nil ? "Add Birthday" : "Edit Birthday")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { save(birthday) }
                        .buttonStyle(.glassProminent)
                }
            }
            .disabled(busy)
        }
        .presentationDetents([.medium, .large])
        .onAppear { birthday = person.birthday ?? .now }
    }

    private func save(_ date: Date?) {
        busy = true
        Task {
            defer { busy = false }
            let edit = PersonEdit(birthDate: date.map { Person.birthdayFormatter.string(from: $0) }, clearBirthDate: date == nil)
            do {
                saved(try await PersonEditing.save(edit, to: person.id, session: session))
                dismiss()
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }
}

/// Choosing whom to merge into a person: everyone, searchable by name, the person themselves left out.
struct PersonMergePicker: View {
    let session: LibrarySession
    /// The person the chosen one's faces move to.
    let target: Person
    let chosen: (Person) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []
    @State private var query = ""
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var requestID = UUID()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(people.filter { $0.id != target.id }) { person in
                    Button {
                        chosen(person)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PersonFaceImage(pipeline: session.pipeline, personID: person.id)
                                .frame(width: 44, height: 44)
                            Text(person.displayName)
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                            Spacer(minLength: 0)
                            if person.isHidden {
                                Image(systemName: "eye.slash")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Hidden")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onAppear { if person.id == people.last?.id { Task { await loadMore() } } }
                }
            }
            .overlay {
                if people.isEmpty {
                    if loading {
                        ProgressView()
                    } else if let error {
                        ContentUnavailableView("Can't Load People", systemImage: "person.crop.square", description: Text(error))
                    } else if !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .navigationTitle("Merge into \(target.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search People")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .task(id: query) {
                if !query.isEmpty {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                requestID = UUID()
                loading = false
                people = []
                page = 1
                hasMore = true
                error = nil
                await loadMore()
            }
        }
    }

    /// Everyone, a page at a time; while searching, the people whose name has a word starting with the text, as
    /// Immich's search finds them.
    private func loadMore() async {
        guard hasMore, !loading else { return }
        let currentRequest = requestID
        loading = true
        defer { if currentRequest == requestID { loading = false } }
        do {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                let response = try await session.client.peoplePage(page: page, withHidden: true)
                guard currentRequest == requestID else { return }
                let known = Set(people.map(\.id))
                people += response.people.filter { !known.contains($0.id) }
                hasMore = response.hasNextPage ?? (!response.people.isEmpty && page * 100 < response.total)
                page += 1
            } else {
                let found: [Person] = try await session.client.get("search/person", query: ["name": text, "withHidden": "true"])
                guard currentRequest == requestID else { return }
                people = found
                hasMore = false
            }
        } catch is CancellationError {
        } catch {
            guard currentRequest == requestID else { return }
            session.handle(error)
            self.error = error.localizedDescription
            hasMore = false
        }
    }
}
