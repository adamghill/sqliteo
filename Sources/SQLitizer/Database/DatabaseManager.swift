import AppKit
import Foundation
import GRDB
import UniformTypeIdentifiers

enum TableRowID: Hashable {
    case rowid(Int64)
    case pk([String: String])
    case uuid(UUID)
}

struct DBRow: Identifiable {
    let id: TableRowID
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

    // File Metadata
    var fileURL: URL?
    var fileSize: Int64 = 0
    var creationDate: Date?
    var modificationDate: Date?

    // Loading state
    var isLoading: Bool = false
    var errorMessage: String? = nil

    // Pagination
    var limit: Int = 1000
    var offset: Int = 0
    var totalRows: Int = 0

    // Advanced Filtering
    struct FilterCriteria: Identifiable, Equatable {
        let id = UUID()
        var column: String
        var operatorType: FilterOperator
        var value: String
    }

    enum FilterOperator: String, CaseIterable, Identifiable {
        case equals = "="
        case notEquals = "!="
        case contains = "CONTAINS"
        case startsWith = "STARTS WITH"
        case endsWith = "ENDS WITH"
        case greaterThan = ">"
        case lessThan = "<"

        var id: String { rawValue }

        var sqlOperator: String {
            switch self {
            case .contains, .startsWith, .endsWith: return "LIKE"
            default: return rawValue
            }
        }
    }

    var filters: [FilterCriteria] = []

    // Tracks local edits: [RowID: [ColumnName: NewValue]]
    var pendingChanges: [TableRowID: [String: String]] = [:]

    var hasChanges: Bool {
        !pendingChanges.isEmpty
    }

    // Cell Editing
    struct CellID: Hashable {
        let rowID: TableRowID
        let column: String
    }

    var activeEdits: [CellID: String] = [:]

    func startEditing(rowID: TableRowID, column: String, currentValue: String) {
        let cellID = CellID(rowID: rowID, column: column)
        if activeEdits[cellID] == nil {
            activeEdits[cellID] = currentValue
        }
    }

    func updateActiveEdit(rowID: TableRowID, column: String, value: String) {
        let cellID = CellID(rowID: rowID, column: column)
        if activeEdits[cellID] != nil {
            activeEdits[cellID] = value
        }
    }

    func applyEdits() {
        for (cell, value) in activeEdits {
            updateCell(rowID: cell.rowID, column: cell.column, value: value)
        }
        activeEdits.removeAll()
    }

    func cancelEdits() {
        activeEdits.removeAll()
    }

    func connect(to url: URL) async {
        self.isLoading = true
        defer { self.isLoading = false }
        self.errorMessage = nil

        do {
            self.fileURL = url
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            self.fileSize = attr[.size] as? Int64 ?? 0
            self.creationDate = attr[.creationDate] as? Date
            self.modificationDate = attr[.modificationDate] as? Date

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
        self.filters = []
        self.offset = 0
        self.isLoading = true
        self.errorMessage = nil

        defer { self.isLoading = false }

        do {
            try await fetchPrimaryKeys(for: tableName)
            try await fetchColumns(for: tableName)
            try await fetchRows(for: tableName)
        } catch {
            self.errorMessage = "Error loading table data: \(error.localizedDescription)"
        }
    }

    private func fetchPrimaryKeys(for tableName: String) async throws {
        guard let dbQueue = dbQueue else { return }

        try await dbQueue.read { db in
            let columnsInfo = try db.columns(in: tableName)
            self.primaryKeyColumns = columnsInfo.filter { $0.primaryKeyIndex > 0 }.map { $0.name }
        }
    }

    private func fetchColumns(for tableName: String) async throws {
        guard let dbQueue = dbQueue else { return }

        try await dbQueue.read { db in
            let columnsInfo = try db.columns(in: tableName)
            self.columns = columnsInfo.map { $0.name }
        }
    }

    func fetchRows(for tableName: String) async throws {
        guard let dbQueue = dbQueue else { return }

        try await dbQueue.read { db in
            // 1. Get Total Count
            var countSql = "SELECT COUNT(*) FROM \(tableName)"
            var arguments: StatementArguments = []

            // Build WHERE clause
            var whereClauses: [String] = []
            var whereArgs: [DatabaseValueConvertible] = []

            for filter in self.filters {
                let sqlOp = filter.operatorType.sqlOperator
                whereClauses.append("\(filter.column) \(sqlOp) ?")

                var value: String = filter.value
                switch filter.operatorType {
                case .contains: value = "%\(value)%"
                case .startsWith: value = "\(value)%"
                case .endsWith: value = "%\(value)"
                default: break
                }
                whereArgs.append(value)
            }

            if !whereClauses.isEmpty {
                let whereString = whereClauses.joined(separator: " AND ")
                countSql += " WHERE \(whereString)"
                arguments = StatementArguments(whereArgs)
            }

            self.totalRows = try Int.fetchOne(db, sql: countSql, arguments: arguments) ?? 0

            // 2. Fetch Data
            var selectColumns = "*"
            var hasRowId = false
            do {
                _ = try db.makeStatement(sql: "SELECT rowid FROM \(tableName) LIMIT 1")
                selectColumns = "rowid, *"
                hasRowId = true
            } catch {
                hasRowId = false
            }

            var sql = "SELECT \(selectColumns) FROM \(tableName)"

            if !whereClauses.isEmpty {
                let whereString = whereClauses.joined(separator: " AND ")
                sql += " WHERE \(whereString)"
            }

            sql += " LIMIT \(self.limit) OFFSET \(self.offset)"

            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            self.rows = rows.map { row in
                var dict: [String: String] = [:]
                for column in self.columns {
                    if let val = row[column] {
                        dict[column] = "\(val)"
                    }
                }

                let id: TableRowID
                if hasRowId, let rowid = row["rowid"] as? Int64 {
                    id = .rowid(rowid)
                } else if !self.primaryKeyColumns.isEmpty {
                    var pkDict: [String: String] = [:]
                    var missingPK = false
                    for pkCol in self.primaryKeyColumns {
                        if let val = row[pkCol] {
                            pkDict[pkCol] = "\(val)"
                        } else {
                            missingPK = true
                        }
                    }
                    if !missingPK && !pkDict.isEmpty {
                        id = .pk(pkDict)
                    } else {
                        id = .uuid(UUID())
                    }
                } else {
                    id = .uuid(UUID())
                }

                return DBRow(id: id, data: dict)
            }
        }
    }

    func nextPage() {
        Task {
            if offset + limit < totalRows {
                offset += limit
                await applyFilter()
            }
        }
    }

    func previousPage() {
        Task {
            if offset - limit >= 0 {
                offset -= limit
                await applyFilter()
            }
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
                    return DBRow(id: .uuid(UUID()), data: dict)
                }
                return (cols, dbRows)
            }

            self.columns = newColumns
            self.rows = newRows
            self.primaryKeyColumns = []
            self.totalRows = self.rows.count
        } catch {
            self.errorMessage = "Error executing SQL: \(error.localizedDescription)"
        }
    }

    func applyFilter() async {
        guard let tableName = selectedTableName else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            try await fetchRows(for: tableName)
        } catch {
            self.errorMessage = "Error applying filter: \(error.localizedDescription)"
        }
    }

    func clearFilter() async {
        filters = []
        offset = 0
        await applyFilter()
    }

    func updateCell(rowID: TableRowID, column: String, value: String) {
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

        self.isLoading = true
        defer { self.isLoading = false }

        do {
            try await dbQueue.write { db in
                for (rowID, changes) in changesToSave {
                    guard let row = rowsSnapshot.first(where: { $0.id == rowID }) else { continue }

                    let setClause = changes.map { "\($0.key) = ?" }.joined(separator: ", ")

                    var whereClause = ""
                    var whereArgs: [DatabaseValueConvertible?] = []

                    switch rowID {
                    case .rowid(let id):
                        whereClause = "rowid = ?"
                        whereArgs = [id]
                    case .pk(let pkDict):
                        whereClause = pkDict.keys.map { "\($0) = ?" }.joined(separator: " AND ")
                        whereArgs = Array(pkDict.values)
                    case .uuid:
                        let whereColumns =
                            self.primaryKeyColumns.isEmpty ? self.columns : self.primaryKeyColumns
                        whereClause = whereColumns.map { "\($0) = ?" }.joined(separator: " AND ")
                        whereArgs = whereColumns.map { row.data[$0] }
                    }

                    if whereClause.isEmpty { continue }

                    let sql = "UPDATE \(tableName) SET \(setClause) WHERE \(whereClause)"

                    var arguments: [DatabaseValueConvertible?] = Array(changes.values)
                    arguments.append(contentsOf: whereArgs)

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
