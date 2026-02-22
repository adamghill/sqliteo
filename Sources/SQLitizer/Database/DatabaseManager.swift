import AppKit
import Foundation
import GRDB
import Observation
import UniformTypeIdentifiers

enum TableRowID: Hashable, Equatable {
    case rowid(Int64)
    case pk([String: String])
    case uuid(UUID)
}

struct DBRow: Identifiable, Equatable {
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
    var columnTypes: [String: String] = [:]
    var primaryKeyColumns: [String] = []
    var rows: [DBRow] = []

    // Tracks local edits: [RowID: [ColumnName: NewValue]]
    var pendingChanges: [TableRowID: [String: String]] = [:]

    // Pagination and Filtering
    var totalRows: Int = 0
    var offset: Int = 0
    var limit: Int = 1000

    struct FilterCriteria: Identifiable, Codable {
        var id = UUID()
        var column: String
        var operatorType: FilterOperator
        var value: String
    }

    enum FilterOperator: String, CaseIterable, Identifiable, Codable {
        case equals = "="
        case notEquals = "!="
        case contains = "contains"
        case startsWith = "starts with"
        case endsWith = "ends with"
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
    var tableDDL: String = ""
    var customSQL: String? = nil

    // Sort State
    var sortColumn: String? = nil
    var sortAscending: Bool = true

    // Track loading state
    var isLoading: Bool = false
    var errorMessage: String? = nil

    // Cached per-table metadata (not observed by views)
    @ObservationIgnored var tableHasRowid: Bool = true
    @ObservationIgnored private var columnCache: [String: [String]] = [:]

    // File Metadata
    var fileURL: URL?
    var fileSize: Int64 = 0
    var creationDate: Date?
    var modificationDate: Date?

    // Tracks current editing state before it is committed to pendingChanges
    var activeEdits: [TableRowID: [String: String]] = [:]

    var hasChanges: Bool {
        !pendingChanges.isEmpty
    }

    func startEditing(rowID: TableRowID, column: String, currentValue: String) {
        if activeEdits[rowID] == nil {
            activeEdits[rowID] = [:]
        }
        if activeEdits[rowID]?[column] == nil {
            activeEdits[rowID]?[column] = currentValue
        }
    }

    func updateActiveEdit(rowID: TableRowID, column: String, value: String) {
        guard let row = rows.first(where: { $0.id == rowID }) else { return }
        let originalValue = row.data[column] ?? ""

        if value != originalValue {
            if activeEdits[rowID] == nil {
                activeEdits[rowID] = [:]
            }
            activeEdits[rowID]?[column] = value
        } else {
            activeEdits[rowID]?[column] = nil
            if activeEdits[rowID]?.isEmpty == true {
                activeEdits[rowID] = nil
            }
        }
    }

    func applyEdits() {
        for (rowID, rowDict) in activeEdits {
            for (column, value) in rowDict {
                updateCell(rowID: rowID, column: column, value: value)
            }
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
        self.columnCache = [:]

        do {
            self.fileURL = url
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            self.fileSize = attr[.size] as? Int64 ?? 0
            self.creationDate = attr[.creationDate] as? Date
            self.modificationDate = attr[.modificationDate] as? Date

            let path = url.path
            let queue = try await Task.detached {
                try DatabaseQueue(path: path)
            }.value

            self.dbQueue = queue
            try await fetchTables()
        } catch {
            self.errorMessage = "Error connecting to database: \(error.localizedDescription)"
        }
    }

    func fetchTables() async throws {
        guard let dbQueue = dbQueue else { return }

        let tables = try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql:
                    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
        }
        self.tableNames = tables
    }

    func selectTable(_ tableName: String) async {
        self.selectedTableName = tableName
        self.customSQL = nil
        self.pendingChanges = [:]
        self.filters = []
        self.offset = 0
        self.tableDDL = ""
        self.columns = []
        self.rows = []
        self.totalRows = 0
        self.isLoading = true
        self.errorMessage = nil

        defer { self.isLoading = false }

        do {
            async let schemaTask: () = fetchSchema(for: tableName)
            async let ddlTask: () = fetchTableDDL(for: tableName)
            try await schemaTask
            try await ddlTask
            try await fetchRows(for: tableName)
        } catch {
            self.errorMessage = "Error loading table data: \(error.localizedDescription)"
        }
    }

    func clearDataForSQLConsole() {
        self.selectedTableName = nil
        self.customSQL = nil
        self.columns = []
        self.rows = []
        self.totalRows = 0
        self.offset = 0
        self.pendingChanges = [:]
        self.filters = []
        self.tableDDL = ""
        self.primaryKeyColumns = []
    }

    private func fetchTableDDL(for tableName: String) async throws {
        guard let dbQueue = dbQueue else { return }

        let ddl = try await dbQueue.read { db in
            let sql = "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?"
            return try String.fetchOne(db, sql: sql, arguments: [tableName]) ?? "/* No DDL found */"
        }
        self.tableDDL = ddl
    }

    private func fetchSchema(for tableName: String) async throws {
        guard let dbQueue = dbQueue else { return }

        let (cols, types, pks, hasRowid) = try await dbQueue.read {
            db -> ([String], [String: String], [String], Bool) in
            let columnsInfo = try db.columns(in: tableName)
            let cols = columnsInfo.map { $0.name }
            let types = Dictionary(uniqueKeysWithValues: columnsInfo.map { ($0.name, $0.type) })
            let pks = columnsInfo.filter { $0.primaryKeyIndex > 0 }.map { $0.name }

            var hasRowid = false
            do {
                _ = try db.makeStatement(
                    sql: "SELECT rowid FROM \"\(tableName)\" LIMIT 1")
                hasRowid = true
            } catch {}

            return (cols, types, pks, hasRowid)
        }
        self.columns = cols
        self.columnTypes = types
        self.primaryKeyColumns = pks
        self.tableHasRowid = hasRowid
        self.columnCache[tableName] = cols
    }

    func columns(for tables: [String]) async -> [String] {
        guard let dbQueue = dbQueue else { return [] }
        var allColumns = Set<String>()

        for table in tables {
            if let cached = columnCache[table] {
                allColumns.formUnion(cached)
            } else {
                let cols =
                    try? await dbQueue.read { db in
                        try db.columns(in: table).map { $0.name }
                    }
                if let cols = cols {
                    columnCache[table] = cols
                    allColumns.formUnion(cols)
                }
            }
        }
        return Array(allColumns).sorted()
    }

    func fetchRows(for tableName: String) async throws {
        guard let dbQueue = dbQueue else { return }

        let filtersSnapshot = self.filters
        let limitSnapshot = self.limit
        let offsetSnapshot = self.offset
        let columnsSnapshot = self.columns
        let pksSnapshot = self.primaryKeyColumns
        let hasRowidSnapshot = self.tableHasRowid
        let sortColumnSnapshot = self.sortColumn
        let sortAscendingSnapshot = self.sortAscending

        let (total, fetchedRows) = try await dbQueue.read { db -> (Int, [DBRow]) in
            // 1. Get Total Count
            var countSql = "SELECT COUNT(*) FROM \"\(tableName)\""
            var arguments: StatementArguments = []

            var whereClauses: [String] = []
            var whereArgs: [DatabaseValueConvertible] = []

            for filter in filtersSnapshot {
                let sqlOp = filter.operatorType.sqlOperator
                whereClauses.append("\"\(filter.column)\" \(sqlOp) ?")

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

            let total = try Int.fetchOne(db, sql: countSql, arguments: arguments) ?? 0

            // 2. Fetch Data
            let selectColumns = hasRowidSnapshot ? "rowid, *" : "*"

            var sql = "SELECT \(selectColumns) FROM \"\(tableName)\""
            if !whereClauses.isEmpty {
                let whereString = whereClauses.joined(separator: " AND ")
                sql += " WHERE \(whereString)"
            }

            if let sortCol = sortColumnSnapshot {
                let direction = sortAscendingSnapshot ? "ASC" : "DESC"
                sql += " ORDER BY \"\(sortCol)\" \(direction)"
            }

            sql += " LIMIT \(limitSnapshot) OFFSET \(offsetSnapshot)"

            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            let dbRows = rows.map { row in
                var dict: [String: String] = [:]
                for column in columnsSnapshot {
                    if let val = row[column] {
                        dict[column] = "\(val)"
                    }
                }

                let id: TableRowID
                if hasRowidSnapshot, let rowid = row["rowid"] as? Int64 {
                    id = .rowid(rowid)
                } else if !pksSnapshot.isEmpty {
                    var pkDict: [String: String] = [:]
                    var missingPK = false
                    for pkCol in pksSnapshot {
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
            return (total, dbRows)
        }

        self.totalRows = total
        self.rows = fetchedRows
    }

    func nextPage() async {
        if offset + limit < totalRows {
            offset += limit
            if selectedTableName != nil {
                await applyFilter()
            } else if let sql = customSQL {
                await executeCustomSQL(sql, resetOffset: false)
            }
        }
    }

    func previousPage() async {
        if offset - limit >= 0 {
            offset -= limit
            if selectedTableName != nil {
                await applyFilter()
            } else if let sql = customSQL {
                await executeCustomSQL(sql, resetOffset: false)
            }
        }
    }

    func executeCustomSQL(_ sql: String, resetOffset: Bool = true) async {
        guard let dbQueue = dbQueue else { return }

        self.selectedTableName = nil
        self.customSQL = sql
        self.pendingChanges = [:]
        self.isLoading = true
        self.errorMessage = nil
        if resetOffset {
            self.offset = 0
            self.columns = []
            self.rows = []
            self.totalRows = 0
        }

        defer { self.isLoading = false }

        do {
            let offsetSnapshot = self.offset
            let limitSnapshot = self.limit

            let (newColumns, total, newRows) = try await dbQueue.read {
                db -> ([String], Int, [DBRow]) in
                var count = 0
                var cleanSQL = sql.trimmingCharacters(in: .whitespacesAndNewlines)
                while cleanSQL.hasSuffix(";") {
                    cleanSQL.removeLast()
                    cleanSQL = cleanSQL.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                let isSelect = cleanSQL.uppercased().hasPrefix("SELECT")

                var paginatedSQL = cleanSQL
                if isSelect {
                    do {
                        count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (\(cleanSQL))") ?? 0
                        paginatedSQL =
                            "SELECT * FROM (\(cleanSQL)) LIMIT \(limitSnapshot) OFFSET \(offsetSnapshot)"
                    } catch {
                        // Fallback if counting fails (e.g. invalid syntax for subquery)
                    }
                }

                let statement = try db.makeStatement(sql: paginatedSQL)
                let cols = Array(statement.columnNames)
                let rows = try Row.fetchAll(statement)

                if !isSelect || count == 0 {
                    count = rows.count
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
                return (cols, count, dbRows)
            }

            self.columns = newColumns
            self.rows = newRows
            self.totalRows = total
            self.primaryKeyColumns = []
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
        let columnsSnapshot = self.columns
        let pksSnapshot = self.primaryKeyColumns

        self.isLoading = true
        defer { self.isLoading = false }

        do {
            try await dbQueue.write { db in
                for (rowID, changes) in changesToSave {
                    guard let row = rowsSnapshot.first(where: { $0.id == rowID }) else { continue }

                    let setClause = changes.map { "\"\($0.key)\" = ?" }.joined(
                        separator: ", ")

                    var whereClause = ""
                    var whereArgs: [DatabaseValueConvertible?] = []

                    switch rowID {
                    case .rowid(let id):
                        whereClause = "rowid = ?"
                        whereArgs = [id]
                    case .pk(let pkDict):
                        whereClause =
                            pkDict.keys.map { "\"\($0)\" = ?" }.joined(
                                separator: " AND ")
                        whereArgs = Array(pkDict.values)
                    case .uuid:
                        let whereColumns =
                            pksSnapshot.isEmpty ? columnsSnapshot : pksSnapshot
                        whereClause =
                            whereColumns.map { "\"\($0)\" = ?" }.joined(
                                separator: " AND ")
                        whereArgs = whereColumns.map { row.data[$0] }
                    }

                    if whereClause.isEmpty { continue }

                    let sql =
                        "UPDATE \"\(tableName)\" SET \(setClause) WHERE \(whereClause)"

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
