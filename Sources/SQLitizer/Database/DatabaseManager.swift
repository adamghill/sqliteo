import AppKit
import Foundation
import GRDB
import UniformTypeIdentifiers

struct DBRow: Identifiable {
    let id = UUID()
    let data: [String: String]
}

@Observable
@MainActor
class DatabaseManager {
    var dbQueue: DatabaseQueue?
    var tableNames: [String] = []
    var selectedTableName: String?
    var columns: [String] = []
    var primaryKeyColumns: [String] = []
    var rows: [DBRow] = []

    // Tracks local edits: [RowID: [ColumnName: NewValue]]
    var pendingChanges: [UUID: [String: String]] = [:]

    var filterText: String = ""

    var hasChanges: Bool {
        !pendingChanges.isEmpty
    }

    // Track loading state
    var isLoading: Bool = false
    var errorMessage: String? = nil

    // File Metadata
    var currentFileURL: URL?
    var currentFileSize: String?

    func connect(to url: URL) async {
        do {
            self.currentFileURL = url
            if let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = attr[.size] as? Int64
            {
                self.currentFileSize = ByteCountFormatter.string(
                    fromByteCount: size, countStyle: .file)
            } else {
                self.currentFileSize = "Unknown"
            }

            // DatabaseQueue instantiation is fast, but we can do it off-actor if strictly needed.
            let path = url.path
            let queue = try await Task.detached {
                try DatabaseQueue(path: path)
            }.value

            self.dbQueue = queue
            await fetchTables()
        } catch {
            self.errorMessage = "Error connecting to database: \(error.localizedDescription)"
        }
    }

    func fetchTables() async {
        guard let dbQueue = dbQueue else { return }

        self.isLoading = true
        defer { self.isLoading = false }

        do {
            let tables = try await dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql:
                        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
                )
            }
            self.tableNames = tables
        } catch {
            self.errorMessage = "Error fetching tables: \(error.localizedDescription)"
        }
    }

    func selectTable(_ tableName: String) async {
        self.selectedTableName = tableName
        self.pendingChanges = [:]
        self.filterText = ""
        self.isLoading = true
        self.errorMessage = nil

        defer { self.isLoading = false }

        do {
            guard let dbQueue = dbQueue else { return }

            // Perform all reads in one background task
            let (pks, cols, fetchedRows) = try await dbQueue.read {
                db -> ([String], [String], [DBRow]) in
                // 1. Primary Keys
                let columnsInfo = try db.columns(in: tableName)
                let pks = columnsInfo.filter { $0.primaryKeyIndex > 0 }.map { $0.name }

                // 2. Columns
                let cols = columnsInfo.map { $0.name }

                // 3. Rows (Limit 1000 for performance)
                let sql = "SELECT * FROM \(tableName) LIMIT 1000"
                let rows = try Row.fetchAll(db, sql: sql)
                let dbRows = rows.map { row in
                    var dict: [String: String] = [:]
                    for column in cols {
                        if let val = row[column] {
                            dict[column] = "\(val)"
                        }
                    }
                    return DBRow(data: dict)
                }

                return (pks, cols, dbRows)
            }

            self.primaryKeyColumns = pks
            self.columns = cols
            self.rows = fetchedRows

        } catch {
            self.errorMessage = "Error loading table data: \(error.localizedDescription)"
        }
    }

    func executeCustomSQL(_ sql: String) async {
        guard let dbQueue = dbQueue else { return }

        self.selectedTableName = nil
        self.pendingChanges = [:]
        self.isLoading = true
        self.errorMessage = nil

        defer { self.isLoading = false }

        do {
            let (newColumns, newRows) = try await dbQueue.read { db -> ([String], [DBRow]) in
                let rows = try Row.fetchAll(db, sql: sql)
                var cols: [String] = []

                if let firstRow = rows.first {
                    cols = Array(firstRow.columnNames)
                } else {
                    let statement = try db.makeStatement(sql: sql)
                    cols = Array(statement.columnNames)
                }

                let dbRows = rows.map { row in
                    var dict: [String: String] = [:]
                    for column in cols {
                        if let val = row[column] {
                            dict[column] = "\(val)"
                        }
                    }
                    return DBRow(data: dict)
                }
                return (cols, dbRows)
            }

            self.columns = newColumns
            self.rows = newRows
            self.primaryKeyColumns = []
        } catch {
            self.errorMessage = "Error executing SQL: \(error.localizedDescription)"
        }
    }

    func applyFilter() async {
        guard let tableName = selectedTableName, let dbQueue = dbQueue else { return }

        self.isLoading = true
        defer { self.isLoading = false }

        do {
            let currentFilter = self.filterText
            let currentCols = self.columns

            let filteredRows = try await dbQueue.read { db -> [DBRow] in
                var sql = "SELECT * FROM \(tableName)"
                var arguments: StatementArguments = []

                if !currentFilter.isEmpty {
                    let conditions = currentCols.map { "\($0) LIKE ?" }.joined(separator: " OR ")
                    sql += " WHERE \(conditions)"
                    arguments = StatementArguments(
                        Array(repeating: "%\(currentFilter)%", count: currentCols.count))
                }

                sql += " LIMIT 1000"
                let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
                return rows.map { row in
                    var dict: [String: String] = [:]
                    for column in currentCols {
                        if let val = row[column] {
                            dict[column] = "\(val)"
                        }
                    }
                    return DBRow(data: dict)
                }
            }
            self.rows = filteredRows
        } catch {
            self.errorMessage = "Error filtering: \(error.localizedDescription)"
        }
    }

    func clearFilter() async {
        self.filterText = ""
        await applyFilter()
    }

    func updateCell(rowID: UUID, column: String, value: String) {
        if pendingChanges[rowID] == nil {
            pendingChanges[rowID] = [:]
        }
        pendingChanges[rowID]?[column] = value
    }

    func discardChanges() {
        pendingChanges = [:]
    }

    func saveChanges() async {
        guard let dbQueue = dbQueue, let tableName = selectedTableName else { return }

        let changesToSave = self.pendingChanges
        let rowsSnapshot = self.rows
        let pks = self.primaryKeyColumns
        let allCols = self.columns

        self.isLoading = true
        defer { self.isLoading = false }

        do {
            try await dbQueue.write { db in
                for (rowID, changes) in changesToSave {
                    guard let row = rowsSnapshot.first(where: { $0.id == rowID }) else { continue }

                    let setClause = changes.map { "\($0.key) = ?" }.joined(separator: ", ")
                    let whereColumns = pks.isEmpty ? allCols : pks
                    let whereClause = whereColumns.map { "\($0) = ?" }.joined(separator: " AND ")

                    let sql = "UPDATE \(tableName) SET \(setClause) WHERE \(whereClause)"

                    var arguments: [DatabaseValueConvertible?] = Array(changes.values)
                    arguments.append(contentsOf: whereColumns.map { row.data[$0] })

                    try db.execute(sql: sql, arguments: StatementArguments(arguments))
                }
            }

            self.pendingChanges = [:]
            await self.applyFilter()

        } catch {
            self.errorMessage = "Error saving changes: \(error.localizedDescription)"
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType("org.sqlite.sqlite"),
            UTType.database,
            UTType.data,
        ].compactMap { $0 }

        panel.allowedContentTypes += [
            UTType(filenameExtension: "sqlite"),
            UTType(filenameExtension: "db"),
            UTType(filenameExtension: "sqlite3"),
        ].compactMap { $0 }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task {
                    await self.connect(to: url)
                }
            }
        }
    }
}
