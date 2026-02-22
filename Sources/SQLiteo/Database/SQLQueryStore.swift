import CryptoKit
import Foundation
import Observation

struct SQLQuery: Identifiable, Equatable {
    let id: UUID
    var name: String
    var sql: String
    /// Whether this query has been persisted to disk yet
    var isPersisted: Bool

    func rangeToExecute(withSelection selection: Range<String.Index>) -> Range<String.Index> {
        if selection.lowerBound != selection.upperBound,
            selection.lowerBound >= sql.startIndex,
            selection.upperBound <= sql.endIndex
        {
            return selection
        }

        let cursor = selection.lowerBound
        guard cursor >= sql.startIndex && cursor <= sql.endIndex else {
            return sql.startIndex..<sql.endIndex
        }

        // Find previous semicolon
        var startSubstring = sql.startIndex
        if let prevSemi = sql[..<cursor].lastIndex(of: ";") {
            startSubstring = sql.index(after: prevSemi)
        }

        // Find next semicolon
        var endSubstring = sql.endIndex
        if let nextSemi = sql[cursor...].firstIndex(of: ";") {
            endSubstring = nextSemi
        }

        // Trim bounds
        var resultStart = startSubstring
        var resultEnd = endSubstring

        while resultStart < resultEnd && sql[resultStart].isWhitespace {
            resultStart = sql.index(after: resultStart)
        }

        while resultEnd > resultStart && sql[sql.index(before: resultEnd)].isWhitespace {
            resultEnd = sql.index(before: resultEnd)
        }

        if resultStart >= resultEnd {
            return sql.startIndex..<sql.endIndex
        }

        return resultStart..<resultEnd
    }
}

@Observable
@MainActor
class SQLQueryStore {
    var queries: [SQLQuery] = []
    var selectedQueryID: UUID?

    @ObservationIgnored private var queriesDirectory: URL?

    var selectedQuery: SQLQuery? {
        guard let id = selectedQueryID else { return nil }
        return queries.first { $0.id == id }
    }

    // MARK: - Directory Management

    /// Configure the store for a specific database file.
    /// Creates a per-database subdirectory using filename + short path hash.
    func configure(for databaseURL: URL) {
        let dbName = databaseURL.deletingPathExtension().lastPathComponent
        let pathHash = shortHash(of: databaseURL.path)
        let dirName = "\(dbName)_\(pathHash)"

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        queriesDirectory =
            appSupport
            .appendingPathComponent("SQLiteo", isDirectory: true)
            .appendingPathComponent("Queries", isDirectory: true)
            .appendingPathComponent(dirName, isDirectory: true)

        load()

        // If no queries exist, create a default virtual (unpersisted) query
        if queries.isEmpty {
            let query = SQLQuery(
                id: UUID(), name: "SQL Query", sql: "", isPersisted: false)
            queries = [query]
            selectedQueryID = query.id
        }
    }

    // MARK: - CRUD Operations

    @discardableResult
    func addQuery() -> SQLQuery {
        let existingNames = Set(queries.map(\.name))
        var name = "SQL Query"
        var counter = 1
        while existingNames.contains(name) {
            counter += 1
            name = "SQL Query \(counter)"
        }

        let query = SQLQuery(id: UUID(), name: name, sql: "", isPersisted: false)
        queries.append(query)
        selectedQueryID = query.id
        return query
    }

    func deleteQuery(id: UUID) {
        guard let index = queries.firstIndex(where: { $0.id == id }) else { return }
        let query = queries[index]

        // Delete file on disk if persisted
        if query.isPersisted, let fileURL = fileURL(for: query) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        queries.remove(at: index)

        // Adjust selection
        if selectedQueryID == id {
            selectedQueryID = queries.last?.id
        }
    }

    func renameQuery(id: UUID, to newName: String) {
        guard let index = queries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let oldQuery = queries[index]

        // If persisted, rename the file on disk
        if oldQuery.isPersisted,
            let oldURL = fileURL(for: oldQuery)
        {
            var renamed = oldQuery
            renamed.name = trimmed
            if let newURL = fileURL(for: renamed) {
                try? FileManager.default.moveItem(at: oldURL, to: newURL)
            }
        }

        queries[index].name = trimmed
    }

    func updateSQL(id: UUID, sql: String) {
        guard let index = queries.firstIndex(where: { $0.id == id }) else { return }
        queries[index].sql = sql

        // Persist on first real content (lazy file creation)
        if !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !queries[index].isPersisted {
                ensureDirectoryExists()
                queries[index].isPersisted = true
            }
            writeFile(for: queries[index])
        }
    }

    // MARK: - File I/O

    func load() {
        guard let dir = queriesDirectory else { return }

        queries = []
        selectedQueryID = nil

        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        let fileURLs =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil))
            ?? []

        for fileURL in fileURLs where fileURL.pathExtension == "sql" {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            guard let (name, id) = parseFilename(filename) else { continue }
            let sql = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            queries.append(
                SQLQuery(id: id, name: name, sql: sql, isPersisted: true))
        }

        // Sort by name for consistent ordering
        queries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        selectedQueryID = queries.first?.id
    }

    // MARK: - Private Helpers

    private func ensureDirectoryExists() {
        guard let dir = queriesDirectory else { return }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
    }

    private func fileURL(for query: SQLQuery) -> URL? {
        guard let dir = queriesDirectory else { return nil }
        let sanitized = sanitizeFilename(query.name)
        return dir.appendingPathComponent(
            "\(sanitized)__\(query.id.uuidString).sql")
    }

    private func writeFile(for query: SQLQuery) {
        guard let url = fileURL(for: query) else { return }
        try? query.sql.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Parse a filename like "My Query__<UUID>.sql" into (name, UUID)
    private func parseFilename(_ filename: String) -> (String, UUID)? {
        guard let range = filename.range(of: "__", options: .backwards) else {
            return nil
        }
        let name = String(filename[filename.startIndex..<range.lowerBound])
        let uuidString = String(filename[range.upperBound...])
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        return (name, uuid)
    }

    /// Generate a short hash of a path for directory naming
    private func shortHash(of path: String) -> String {
        let data = Data(path.utf8)
        let hash = SHA256.hash(data: data)
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Remove characters that are invalid in filenames
    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }
}
