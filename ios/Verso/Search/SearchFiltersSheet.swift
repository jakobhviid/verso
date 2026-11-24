// Search's filters in a sheet (ROADMAP.md, M10), as the Mac's search filters: what the words search (smart search,
// file name, description, text in the photos, as the server offers them), people, a place, the dates taken, the media
// type, and favorites, the archive, photos in no album and a rating. Search runs the search with them.

import SwiftUI

struct SearchFiltersSheet: View {
    let session: LibrarySession
    @State var query: SearchQuery
    let ratingsEnabled: Bool
    let apply: (SearchQuery) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Search By") {
                    Picker("Search By", selection: $query.mode) {
                        ForEach(modes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if session.features.facialRecognition {
                    Section("People") {
                        SearchPeoplePicker(session: session, query: $query)
                    }
                }
                Section("Place") {
                    SearchSuggestionRow(session: session, title: "Country", type: "country", value: $query.country, filters: query)
                    SearchSuggestionRow(session: session, title: "State", type: "state", value: $query.state, filters: query)
                    SearchSuggestionRow(session: session, title: "City", type: "city", value: $query.city, filters: query)
                }
                Section {
                    SearchDateRow(title: "From", date: $query.takenAfter)
                    SearchDateRow(title: "To", date: $query.takenBefore)
                } header: {
                    Text("Date Taken")
                } footer: {
                    if !query.validDates { Text("The start date must precede the end date.").foregroundStyle(.red) }
                }
                Section("Media Type") {
                    Picker("Media Type", selection: $query.mediaType) {
                        Text("All").tag("")
                        Text("Photos").tag("IMAGE")
                        Text("Videos").tag("VIDEO")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    Toggle("Favorites Only", isOn: $query.favorites)
                    Toggle("In the Archive", isOn: $query.archived)
                    Toggle("Not in Any Album", isOn: $query.notInAlbum)
                    if ratingsEnabled {
                        Picker("Rating", selection: $query.rating) {
                            Text("Any").tag(nil as Int?)
                            ForEach(1...5, id: \.self) { stars in
                                Text(stars == 1 ? "1 star" : "\(stars) stars").tag(Optional(stars))
                            }
                        }
                    }
                }
                Section {
                    Button("Reset Filters", role: .destructive) {
                        var cleared = SearchQuery()
                        cleared.text = query.text
                        cleared.mode = query.mode
                        cleared.sort = query.sort
                        query = cleared
                    }
                    .disabled(query.chips.isEmpty)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") {
                        apply(query)
                        dismiss()
                    }
                    .disabled(!query.validDates || (query.text.trimmingCharacters(in: .whitespaces).isEmpty && query.chips.isEmpty))
                }
            }
            // A place or camera within another: choosing the wider one again clears the narrower, as on the Mac.
            .onChange(of: query.country) { query.state = ""; query.city = "" }
            .onChange(of: query.state) { query.city = "" }
        }
    }

    /// The ways the server can search words: smart search and text in the photos only where it has them on.
    private var modes: [SearchMode] {
        SearchMode.allCases.filter { mode in
            (mode != .context || session.features.smartSearch) && (mode != .ocr || session.features.ocr)
        }
    }
}

/// The people to search for: the first Immich lists, those chosen first, and whom a typed name finds; a tap chooses or
/// lets go. Faces are rounded squares, as every person in Verso.
private struct SearchPeoplePicker: View {
    let session: LibrarySession
    @Binding var query: SearchQuery
    @State private var listed: [Person] = []
    @State private var name = ""
    @State private var found: [Person]?
    @State private var error: String?

    var body: some View {
        TextField("Find a Person", text: $name)
            .textInputAutocapitalization(.words)
            .task(id: name) { await find() }
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(shown) { person in
                    let chosen = query.personIDs.contains(person.id)
                    Button {
                        toggle(person)
                    } label: {
                        VStack(spacing: 4) {
                            CollectionsFace(pipeline: session.pipeline, personID: person.id)
                                .frame(width: 60, height: 60)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(chosen ? Color.accentColor : .clear, lineWidth: 3)
                                }
                            Group {
                                if person.name.isEmpty { Text("Unnamed Person") } else { Text(verbatim: person.name) }
                            }
                            .font(.caption)
                            .lineLimit(1)
                        }
                        .frame(width: 72)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
                if found?.isEmpty == true {
                    Text("No one by that name.").foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .task { await loadListed() }
        if let error {
            Text(error).font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Those chosen first, then whom the name found, or the people listed.
    private var shown: [Person] {
        let candidates = found ?? listed
        let chosen = query.personIDs.sorted().filter { id in !candidates.contains { $0.id == id } }.map { id in
            (listed + (found ?? [])).first { $0.id == id }
                ?? Person(id: id, name: query.personNames[id] ?? "", isHidden: false, isFavorite: nil, birthDate: nil)
        }
        return chosen + candidates
    }

    private func toggle(_ person: Person) {
        if query.personIDs.remove(person.id) == nil {
            query.personIDs.insert(person.id)
            query.personNames[person.id] = person.name.isEmpty ? String(localized: "Unnamed Person") : person.name
        } else {
            query.personNames[person.id] = nil
        }
    }

    private func loadListed() async {
        guard listed.isEmpty else { return }
        do {
            listed = Array(try await session.client.peoplePage(page: 1, withHidden: false).people.prefix(24))
            error = nil
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }

    private func find() async {
        let typed = name.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { found = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let result = try await session.client.peoplePage(page: 1, withHidden: false, name: typed)
            try Task.checkCancellation()
            found = result.people
            error = nil
        } catch {
            if !error.isCancellation { session.handle(error); self.error = error.localizedDescription }
        }
    }
}

/// A place filter: its value, and a page of the values Immich has for it, within the wider ones chosen.
private struct SearchSuggestionRow: View {
    let session: LibrarySession
    let title: LocalizedStringKey
    /// Immich's suggestion type: country, state, city.
    let type: String
    @Binding var value: String
    let filters: SearchQuery

    var body: some View {
        NavigationLink {
            SearchSuggestionList(session: session, title: title, type: type, value: $value, filters: filters)
        } label: {
            LabeledContent(title) {
                if value.isEmpty { Text("Any") } else { Text(verbatim: value) }
            }
        }
    }
}

private struct SearchSuggestionList: View {
    let session: LibrarySession
    let title: LocalizedStringKey
    let type: String
    @Binding var value: String
    let filters: SearchQuery
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [String]?
    @State private var unavailable = false
    @State private var error: String?
    @State private var filter = ""

    var body: some View {
        List {
            if unavailable {
                // The server lists no suggestions: the value typed.
                TextField(title, text: $value)
                    .onSubmit { dismiss() }
            } else {
                choice(Text("Any"), value: "")
                ForEach((suggestions ?? []).filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }, id: \.self) { suggestion in
                    choice(Text(verbatim: suggestion), value: suggestion)
                }
            }
        }
        .overlay {
            if suggestions == nil && !unavailable && error == nil {
                ProgressView()
            } else if let error {
                ContentUnavailableView("Suggestions Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            }
        }
        .searchable(text: $filter)
        .navigationTitle(title)
        .task {
            do {
                suggestions = try await session.client.searchSuggestions(type, filters: filters)
            } catch ImmichError.http(404, _) {
                unavailable = true
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }

    private func choice(_ label: Text, value choice: String) -> some View {
        Button {
            value = choice
            dismiss()
        } label: {
            HStack {
                label.foregroundStyle(.primary)
                Spacer()
                if value == choice { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }
}

/// A date the photos were taken from or to, off until switched on.
private struct SearchDateRow: View {
    let title: LocalizedStringKey
    @Binding var date: Date?

    var body: some View {
        Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? Date() : nil }))
        if let current = date {
            DatePicker(title, selection: Binding(get: { current }, set: { date = $0 }), displayedComponents: .date)
        }
    }
}
