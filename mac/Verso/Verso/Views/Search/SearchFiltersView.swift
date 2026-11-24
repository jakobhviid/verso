import SwiftUI

struct SearchFiltersView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Binding var query: SearchQuery
    let ratingsEnabled: Bool
    let apply: () -> Void
    @State private var peopleName = ""
    /// The people read so far, in Immich's order: favorites, then those in the most photos.
    @State private var people: [Person] = []
    @State private var page = 1
    @State private var hasMorePeople = true
    @State private var loadingPeople = false
    @State private var peopleError: String?
    /// Show All: every person, read as the row scrolls; otherwise the first twelve.
    @State private var showingAllPeople = false
    /// Whom a typed name found on the server, anyone in the library; nil while no name is typed.
    @State private var foundPeople: [Person]?

    /// As on Linux (ARCHITECTURE.md, "Verso on the Mac"): the first twelve with any already picked, or everyone after
    /// Show All, or whom a typed name found. Only the faces shown are read, so a library naming hundreds reads twelve
    /// pictures.
    private var shownPeople: [Person] {
        if let foundPeople { return foundPeople }
        let listed = showingAllPeople ? people : Array(people.prefix(12))
        let picked = query.personIDs.sorted().filter { id in !listed.contains { $0.id == id } }.map { id in
            people.first { $0.id == id } ?? Person(id: id, name: query.personNames[id] ?? "", isHidden: false, isFavorite: nil, birthDate: nil)
        }
        return picked + listed
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search Filters").font(.title2.bold())
                Spacer()
                Button("Reset") {
                    let text = query.text; let mode = query.mode; let sort = query.sort
                    query = SearchQuery(); query.text = text; query.mode = mode; query.sort = sort
                }
            }.padding()
            Form {
                if session.features.facialRecognition {
                    Section("People") {
                        TextField("Find a Person", text: $peopleName, prompt: Text("Name"))
                            .task(id: peopleName) { await findPeople() }
                        ScrollView(.horizontal) {
                            LazyHStack {
                                ForEach(shownPeople) { person in
                                    SearchPersonButton(person: person, selected: query.personIDs.contains(person.id)) {
                                        query.personNames[person.id] = person.name.isEmpty ? "Unnamed Person" : person.name
                                        if !query.personIDs.insert(person.id).inserted { query.personIDs.remove(person.id) }
                                    }
                                    .onAppear {
                                        if showingAllPeople, foundPeople == nil, person.id == people.last?.id { Task { await loadPeople() } }
                                    }
                                }
                                if foundPeople == nil, !showingAllPeople, people.count > 12 || hasMorePeople {
                                    Button("Show All") { showingAllPeople = true; Task { await loadPeople() } }
                                }
                                if foundPeople?.isEmpty == true {
                                    Text("No one by that name.").foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }.frame(height: 90)
                        if let peopleError { Text(peopleError).foregroundStyle(.secondary) }
                    }
                }
                Section("Location") {
                    SearchSuggestionField(title: "Country", type: "country", value: $query.country, filters: query)
                    SearchSuggestionField(title: "State", type: "state", value: $query.state, filters: query)
                    SearchSuggestionField(title: "City", type: "city", value: $query.city, filters: query)
                }
                Section("Camera") {
                    SearchSuggestionField(title: "Make", type: "camera-make", value: $query.make, filters: query)
                    SearchSuggestionField(title: "Model", type: "camera-model", value: $query.model, filters: query)
                    SearchSuggestionField(title: "Lens", type: "camera-lens-model", value: $query.lensModel, filters: query)
                }
                Section("Date Taken") {
                    SearchDateFilter(title: "After", date: $query.takenAfter)
                    SearchDateFilter(title: "Before", date: $query.takenBefore)
                    if !query.validDates { Text("The start date must precede the end date.").foregroundStyle(.red) }
                }
                Section("Display") {
                    Picker("Media Type", selection: $query.mediaType) {
                        Text("All").tag(""); Text("Photos").tag("IMAGE"); Text("Videos").tag("VIDEO")
                    }
                    Toggle("Not in an album", isOn: $query.notInAlbum)
                    Toggle("Archived", isOn: $query.archived)
                    Toggle("Favorites", isOn: $query.favorites)
                    if ratingsEnabled {
                        Picker("Rating", selection: $query.rating) {
                            Text("Any").tag(nil as Int?)
                            ForEach(1...5, id: \.self) { Text("\($0) stars").tag(Optional($0)) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Search", action: apply).keyboardShortcut(.defaultAction).disabled(!query.validDates)
            }.padding()
        }
        .frame(width: 560, height: 680)
        .task { if session.features.facialRecognition { await loadPeople() } }
        .onChange(of: query.country) { query.state = ""; query.city = "" }
        .onChange(of: query.state) { query.city = "" }
        .onChange(of: query.make) { query.model = ""; query.lensModel = "" }
        .onChange(of: query.model) { query.lensModel = "" }
    }

    private func loadPeople() async {
        guard !loadingPeople, hasMorePeople else { return }
        loadingPeople = true
        defer { loadingPeople = false }
        do {
            let result = try await session.client.peoplePage(page: page, withHidden: false)
            let known = Set(people.map(\.id))
            people += result.people.filter { !known.contains($0.id) }
            hasMorePeople = result.hasNextPage ?? (result.people.count == 100)
            page += 1; peopleError = nil
        } catch { session.handle(error); peopleError = error.localizedDescription }
    }

    /// Whom a typed name finds, asked of the server a moment after typing stops.
    private func findPeople() async {
        let name = peopleName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { foundPeople = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let result = try await session.client.peoplePage(page: 1, withHidden: false, name: name)
            try Task.checkCancellation()
            foundPeople = result.people
            peopleError = nil
        } catch {
            if !error.isCancellation { session.handle(error); peopleError = error.localizedDescription }
        }
    }
}

private struct SearchSuggestionField: View {
    @Environment(LibrarySession.self) private var session
    let title: String
    let type: String
    @Binding var value: String
    let filters: SearchQuery
    @State private var suggestions: [String] = []
    @State private var unavailable = false
    @State private var errorMessage: String?

    private var dependencies: [String] {
        [type, type == "state" || type == "city" ? filters.country : "", type == "city" ? filters.state : "",
         type == "camera-model" || type == "camera-lens-model" ? filters.make : "",
         type == "camera-lens-model" ? filters.model : ""]
    }

    var body: some View {
        HStack {
            TextField(title, text: $value)
            if !unavailable {
                Menu {
                    Button("Any") { value = "" }
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { value = suggestion }
                    }
                    if let errorMessage { Text(errorMessage) }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).modifier(SuggestionMenuIndicator()).fixedSize().accessibilityLabel("\(title) suggestions")
            }
        }
        .task(id: dependencies) {
            suggestions = []
            do {
                try await Task.sleep(for: .milliseconds(250))
                let result = try await session.client.searchSuggestions(type, filters: filters)
                try Task.checkCancellation()
                suggestions = result; errorMessage = nil
            }
            catch ImmichError.http(404, _) { unavailable = true }
            catch { if !error.isCancellation { session.handle(error); errorMessage = error.localizedDescription } }
        }
    }
}

private struct SearchDateFilter: View {
    let title: String
    @Binding var date: Date?
    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? Date() : nil }))
            if date != nil {
                DatePicker(title, selection: Binding(get: { date ?? Date() }, set: { date = $0 }), displayedComponents: .date).labelsHidden()
            }
        }
    }
}

private struct SearchPersonButton: View {
    @Environment(LibrarySession.self) private var session
    let person: Person
    let selected: Bool
    let action: () -> Void
    @State private var image: CGImage?
    var body: some View {
        Button(action: action) {
            VStack {
                PersonShape().fill(.quaternary).overlay {
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                }.clipShape(PersonShape()).frame(width: 48, height: 48)
                    .overlay { PersonShape().stroke(selected ? Color.accentColor : .clear, lineWidth: 3) }
                Text(person.name.isEmpty ? "Unnamed Person" : person.name).lineLimit(1).font(.caption)
            }.frame(width: 85)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task(id: person.id) { image = await session.pipeline.personThumbnail(person.id) }
    }
}

/// macOS 15 adds its own indicator next to the chevron label, showing two chevrons.
private struct SuggestionMenuIndicator: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) { content } else { content.menuIndicator(.hidden) }
    }
}
