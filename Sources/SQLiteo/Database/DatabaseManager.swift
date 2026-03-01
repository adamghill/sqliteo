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

struct ForeignKeyReference: Equatable {
    let column: String
    let destinationTable: String
    let destinationColumn: String
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
    var foreignKeys: [String: ForeignKeyReference] = [:]
    var rows: [DBRow] = []

    // Tracks local edits: [RowID: [ColumnName: NewValue]]
    var pendingChanges: [TableRowID: [String: String]] = [:]

    // Pagination and Filtering
    var totalRows: Int = 0
    var offset: Int = 0
    var limit: Int = 1000
    var dataUpdateCounter: Int = 0

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

    // Highlighting State
    var highlightedRowID: TableRowID? = nil

    // Sort State
    var sortColumn: String? = nil
    var sortAscending: Bool = true

    // Track loading state
    var isLoading: Bool = false
    var errorMessage: String? = nil

    // Cached per-table metadata (not observed by views)
    @ObservationIgnored var tableHasRowid: Bool = true
    @ObservationIgnored private var columnCache: [String: [String]] = [:]

    struct TableSchema {
        let columns: [String]
        let types: [String: String]
        let primaryKeys: [String]
        let hasRowid: Bool
        let foreignKeys: [String: ForeignKeyReference]
    }
    @ObservationIgnored private var schemaCache: [String: TableSchema] = [:]
    @ObservationIgnored var prefetchTask: Task<Void, Never>?

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
        self.schemaCache = [:]

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
            self.prefetchTask?.cancel()
            self.prefetchTask = Task.detached { [weak self] in
                await self?.prefetchAllSchemas()
            }
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

    func selectTable(_ tableName: String, filter: FilterCriteria? = nil) async {
        self.selectedTableName = tableName
        self.customSQL = nil
        self.pendingChanges = [:]

        if let filter = filter {
            self.filters = [filter]
        } else {
            self.filters = []
        }
        self.offset = 0
        self.tableDDL = ""
        self.columns = []
        self.primaryKeyColumns = []
        self.foreignKeys = [:]
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

    func navigateAndHighlight(tableName: String, column: String, value: String) async {
        self.selectedTableName = tableName
        self.customSQL = nil
        self.pendingChanges = [:]
        self.filters = []
        self.tableDDL = ""
        self.columns = []
        self.primaryKeyColumns = []
        self.foreignKeys = [:]
        self.rows = []
        self.totalRows = 0
        self.isLoading = true
        self.errorMessage = nil
        self.sortColumn = nil
        self.sortAscending = true
        self.highlightedRowID = nil
        self.offset = 0

        defer { self.isLoading = false }

        do {
            async let schemaTask: () = fetchSchema(for: tableName)
            async let ddlTask: () = fetchTableDDL(for: tableName)
            try await schemaTask
            try await ddlTask

            let hasRowidSnapshot = self.tableHasRowid
            let pkSnapshot = self.primaryKeyColumns

            if let dbQueue = dbQueue {
                let offsetInfo = try await dbQueue.read { db -> (Int64?, Int) in
                    var targetRowid: Int64? = nil
                    var offset = 0
                    if hasRowidSnapshot {
                        let sql =
                            "SELECT rowid FROM \"\(tableName)\" WHERE \"\(column)\" = ? LIMIT 1"
                        if let rID = try Int64.fetchOne(db, sql: sql, arguments: [value]) {
                            targetRowid = rID
                            let countSql = "SELECT COUNT(*) FROM \"\(tableName)\" WHERE rowid < ?"
                            offset =
                                try Int.fetchOne(db, sql: countSql, arguments: [targetRowid]) ?? 0
                        }
                    } else if !pkSnapshot.isEmpty {
                        // Fallback logic for without rowid is strictly querying the offset manually
                        let pkList = pkSnapshot.map { "\"\($0)\"" }.joined(
                            separator: ", ")
                        let fetchSql =
                            "SELECT \(pkList) FROM \"\(tableName)\" WHERE \"\(column)\" = ? LIMIT 1"
                        if let firstRowMatch = try Row.fetchOne(
                            db, sql: fetchSql, arguments: [value])
                        {
                            // Find position among ALL ordered by first PK
                            let firstPk = pkSnapshot[0]
                            if let pkVal = firstRowMatch[firstPk] as? DatabaseValue {
                                let offsetSql =
                                    "SELECT COUNT(*) FROM \"\(tableName)\" WHERE \"\(firstPk)\" < ?"
                                offset =
                                    try Int.fetchOne(db, sql: offsetSql, arguments: [pkVal]) ?? 0
                            }
                        }
                    }
                    return (targetRowid, offset)
                }

                if let targetRowid = offsetInfo.0 {
                    self.highlightedRowID = .rowid(targetRowid)
                }

                let pageOffset = (offsetInfo.1 / self.limit) * self.limit
                self.offset = pageOffset
            }

            try await fetchRows(for: tableName)

            // If highlightedRowID isn't set yet (e.g. no rowid table), try to find it in fetched rows
            if self.highlightedRowID == nil {
                if let matchRow = self.rows.first(where: { $0.data[column] == value }) {
                    self.highlightedRowID = matchRow.id
                }
            }

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
        self.foreignKeys = [:]
    }

    private func fetchTableDDL(for tableName: String) async throws {
        guard let dbQueue = dbQueue else { return }

        let ddl = try await dbQueue.read { db in
            let sql = "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?"
            return try String.fetchOne(db, sql: sql, arguments: [tableName]) ?? "/* No DDL found */"
        }
        self.tableDDL = ddl
    }

    nonisolated private func extractSchema(db: GRDB.Database, tableName: String) throws
        -> TableSchema
    {
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

        var fks: [String: ForeignKeyReference] = [:]
        do {
            let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\"\(tableName)\")")
            for row in rows {
                if let table = row["table"] as? String,
                    let from = row["from"] as? String,
                    let to = row["to"] as? String
                {
                    fks[from] = ForeignKeyReference(
                        column: from, destinationTable: table, destinationColumn: to)
                }
            }
        } catch {}

        return TableSchema(
            columns: cols, types: types, primaryKeys: pks, hasRowid: hasRowid, foreignKeys: fks)
    }

    private func fetchSchema(for tableName: String) async throws {
        guard let dbQueue = dbQueue else { return }

        let schema: TableSchema
        if let cached = schemaCache[tableName] {
            schema = cached
        } else {
            schema = try await dbQueue.read { db in
                try self.extractSchema(db: db, tableName: tableName)
            }
            schemaCache[tableName] = schema
            columnCache[tableName] = schema.columns
        }

        self.columns = schema.columns
        self.columnTypes = schema.types
        self.primaryKeyColumns = schema.primaryKeys
        self.tableHasRowid = schema.hasRowid
        self.foreignKeys = schema.foreignKeys
    }

    func prefetchAllSchemas() async {
        guard let dbQueue = dbQueue else { return }

        let tables = tableNames

        do {
            let schemas = try await dbQueue.read { db in
                var results = [String: TableSchema]()
                for table in tables {
                    do {
                        let schema = try self.extractSchema(db: db, tableName: table)
                        results[table] = schema
                    } catch {
                        print("Error prefetching schema for \(table): \(error)")
                    }
                }
                return results
            }

            for (table, schema) in schemas {
                self.schemaCache[table] = schema
                self.columnCache[table] = schema.columns
            }
        } catch {
            print("Error in prefetch: \(error)")
        }
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
        self.dataUpdateCounter += 1
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
            self.dataUpdateCounter += 1
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

    func fetchSurroundingRows(for fk: ForeignKeyReference, value: String) async throws -> [DBRow] {
        guard let dbQueue = dbQueue else { return [] }

        return try await dbQueue.read { db in
            var results: [DBRow] = []

            let columnsInfo = try? db.columns(in: fk.destinationTable)
            let cols = columnsInfo?.map { $0.name } ?? []
            if cols.isEmpty { return [] }

            func mapToDBRow(_ row: GRDB.Row) -> DBRow {
                var dict: [String: String] = [:]
                for col in cols {
                    if let val = row[col] {
                        dict[col] = "\(val)"
                    }
                }
                return DBRow(id: .uuid(UUID()), data: dict)
            }

            let targetSql =
                "SELECT * FROM \"\(fk.destinationTable)\" WHERE \"\(fk.destinationColumn)\" = ? LIMIT 1"
            if let targetRow = try Row.fetchOne(db, sql: targetSql, arguments: [value]) {
                let sqlBefore = """
                    SELECT * FROM \"\(fk.destinationTable)\"
                    WHERE \"\(fk.destinationColumn)\" < ?
                    ORDER BY \"\(fk.destinationColumn)\" DESC LIMIT 3
                    """
                let beforeRows = try Row.fetchAll(db, sql: sqlBefore, arguments: [value]).map(
                    mapToDBRow
                ).reversed()

                let mappedTarget = mapToDBRow(targetRow)

                let sqlAfter = """
                    SELECT * FROM \"\(fk.destinationTable)\"
                    WHERE \"\(fk.destinationColumn)\" > ?
                    ORDER BY \"\(fk.destinationColumn)\" ASC LIMIT 3
                    """
                let afterRows = try Row.fetchAll(db, sql: sqlAfter, arguments: [value]).map(
                    mapToDBRow)

                results.append(contentsOf: beforeRows)
                results.append(mappedTarget)
                results.append(contentsOf: afterRows)
            } else {
                // Not found, try querying random 7 or what we can
                let sqlAny = "SELECT * FROM \"\(fk.destinationTable)\" LIMIT 7"
                results = try Row.fetchAll(db, sql: sqlAny).map(mapToDBRow)
            }
            return results
        }
    }

    func refreshDatabase() async {
        guard dbQueue != nil else { return }
        
        // 1. Clear Caches
        self.columnCache.removeAll()
        self.schemaCache.removeAll()
        
        // 2. Refresh physical file stats if possible
        if let url = self.fileURL, let attr = try? FileManager.default.attributesOfItem(atPath: url.path) {
            self.fileSize = attr[.size] as? Int64 ?? 0
            self.modificationDate = attr[.modificationDate] as? Date
        }
        
        // 3. Keep track of current state
        let currentTable = self.selectedTableName
        let currentCustomSQL = self.customSQL
        let currentFilters = self.filters
        // We do *not* clear active/pending edits because maybe the user wants to save them
        
        // 4. Re-fetch list of tables
        do {
            // Re-instanciate dbQueue to ensure any file-level changes are picked up and internal statement caches are flushed
            if let path = self.fileURL?.path {
                self.dbQueue = try DatabaseQueue(path: path)
            }
            try await fetchTables()
        } catch {
            self.errorMessage = "Failed to refresh table list: \(error.localizedDescription)"
        }
        
        // 5. Trigger new background schema pre-fetch
        self.prefetchTask?.cancel()
        self.prefetchTask = Task.detached { [weak self] in
            await self?.prefetchAllSchemas()
        }
        
        // 6. Restore View State
        if let table = currentTable {
            // Check if the table still exists
            if self.tableNames.contains(table) {
                // Re-select it to refresh columns and data
                // We preserve filters manually since `selectTable` overwrites them if passed nil
                if currentFilters.isEmpty {
                    await self.selectTable(table)
                } else {
                    // For multiple filters, we'd need a different signature, but sqliteo only supports one currently
                    await self.selectTable(table, filter: currentFilters.first)
                }
            } else {
                // Table was dropped externally
                self.clearDataForSQLConsole()
            }
        } else if let sql = currentCustomSQL {
            // Re-run the custom query
            await self.executeCustomSQL(sql, resetOffset: false)
        }
        
        // Force UI update
        self.dataUpdateCounter += 1
    }
}

