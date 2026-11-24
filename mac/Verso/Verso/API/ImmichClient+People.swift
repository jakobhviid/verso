import Foundation

extension ImmichClient {
    func peoplePage(page: Int, withHidden: Bool, name: String? = nil, filters: [String: String] = [:]) async throws -> PeopleResponse {
        if let typed = try await Self.core?(apiURL, credential)?.peoplePage(page: page, size: 100, withHidden: withHidden, name: name, filters: filters) {
            return typed
        }
        var query: [String: String?] = ["page": String(page), "size": "100", "withHidden": String(withHidden), "name": name]
        query.merge(filters.mapValues { Optional($0) }) { $1 }
        return try await get("people", query: query)
    }
    func person(_ id: String) async throws -> Person {
        if let typed = try await Self.core?(apiURL, credential)?.person(id) { return typed }
        return try await get("people/\(id)")
    }
    func personStatistics(_ id: String) async throws -> PeopleStatistics {
        if let typed = try await Self.core?(apiURL, credential)?.personStatistics(id) { return typed }
        return try await get("people/\(id)/statistics")
    }
    func editPerson(_ id: String, _ edit: PersonEdit) async throws -> Person {
        if let typed = try await Self.core?(apiURL, credential)?.editPerson(id, edit) { return typed }
        return try await send("PUT", "people/\(id)", body: edit)
    }
    func createPerson(name: String) async throws -> Person {
        if let typed = try await Self.core?(apiURL, credential)?.createPerson(name: name) { return typed }
        return try await send("POST", "people", body: PersonEdit(name: name))
    }
    func mergePeople(into id: String, ids: [String]) async throws {
        struct Body: Encodable { let ids: [String] }
        let results: [PeopleOperationResult]
        if let typed = try await Self.core?(apiURL, credential)?.mergePeople(into: id, ids: ids) { results = typed }
        else {
            do { results = try await send("POST", "people/merge", body: Body(ids: [id] + ids)) }
            catch ImmichError.http(404, _) {
                results = try await send("POST", "people/\(id)/merge", body: Body(ids: ids))
            }
        }
        if let failed = results.first(where: { !$0.success }) {
            throw ImmichError.http(400, failed.errorMessage ?? failed.error ?? String(localized: "Couldn't merge people."))
        }
    }
    func faces(assetID: String) async throws -> [PeopleFace] {
        if let typed = try await Self.core?(apiURL, credential)?.faces(assetID: assetID) { return typed }
        return try await get("faces", query: ["id": assetID])
    }
    func reassignFace(_ faceID: String, to personID: String) async throws -> Person {
        if let typed = try await Self.core?(apiURL, credential)?.reassignFace(faceID, to: personID) { return typed }
        struct Body: Encodable { let id: String }
        return try await send("PUT", "faces/\(personID)", body: Body(id: faceID))
    }
    func removeFace(_ id: String) async throws {
        if try await Self.core?(apiURL, credential)?.removeFace(id) == true { return }
        struct Body: Encodable { let force: Bool }
        try await send("DELETE", "faces/\(id)", body: Body(force: false))
    }
}
