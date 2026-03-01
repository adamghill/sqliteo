import Foundation
import GRDB
import Testing

@testable import SQLiteo

@MainActor
@Suite("Database Manager Tests")
final class DatabaseManagerTests {
    var dbURL: URL!
    var manager: DatabaseManager!

    init() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        dbURL = tempDir.appendingPathComponent("test_db_\(UUID().uuidString).sqlite")

        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER);
                        INSERT INTO users (name, age) VALUES ('Alice', 30);
                        INSERT INTO users (name, age) VALUES ('Bob', 25);
                        INSERT INTO users (name, age) VALUES ('Charlie', 35);
                        
                        CREATE TABLE posts (post_id INTEGER PRIMARY KEY, title TEXT, user_id INTEGER);
                        INSERT INTO posts (title, user_id) VALUES ('Hello World', 1);
                        INSERT INTO posts (title, user_id) VALUES ('Swift Rocks', 2);
                        
                        CREATE TABLE tags (name TEXT PRIMARY KEY) WITHOUT ROWID;
                        INSERT INTO tags (name) VALUES ('swift');
                        INSERT INTO tags (name) VALUES ('programming');
                        
                        CREATE TABLE no_pk (val TEXT);
                        INSERT INTO no_pk (val) VALUES ('item1');
                        
                        CREATE VIEW user_names AS SELECT name FROM users;
                    """)
        }

        manager = DatabaseManager()
        await manager.connect(to: dbURL)
        await manager.prefetchTask?.value
    }

    deinit {
        // No MainActor cleanup needed for URL
        if let url = dbURL, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(atPath: url.path)
        }
    }

    @Test("Connection and initialization populate correct metadata")
    func connectionAndInitialization() async throws {
        #expect(manager.fileURL == dbURL)
        #expect(manager.fileSize > 0)
        #expect(manager.creationDate != nil)
        #expect(manager.modificationDate != nil)

        #expect(manager.tableNames.sorted() == ["no_pk", "posts", "tags", "users"])
    }

    @Test("Selecting a standard table populates columns and rows")
    func selectingStandardTable() async throws {
        await manager.selectTable("users")

        #expect(manager.selectedTableName == "users")
        #expect(manager.columns == ["id", "name", "age"])
        #expect(manager.primaryKeyColumns == ["id"])
        #expect(manager.rows.count == 3)
        #expect(manager.totalRows == 3)
    }

    @Test("Selecting a WITHOUT ROWID table isolates primary keys")
    func selectingWithoutRowidTable() async throws {
        await manager.selectTable("tags")

        #expect(manager.selectedTableName == "tags")
        #expect(manager.primaryKeyColumns == ["name"])
        #expect(manager.rows.count == 2)
    }

    @Test("Pagination boundaries correctly update offsets")
    func pagination() async throws {
        try await manager.dbQueue?.write { db in
            for i in 1...2500 {
                try db.execute(
                    sql: "INSERT INTO users (name, age) VALUES (?, ?)",
                    arguments: ["User \(i)", 20 + (i % 50)])
            }
        }
        try await manager.fetchTables()

        manager.limit = 1000
        await manager.selectTable("users")

        #expect(manager.offset == 0)
        #expect(manager.rows.count == 1000)
        #expect(manager.totalRows == 2503)

        await manager.nextPage()

        #expect(manager.offset == 1000)
        #expect(manager.rows.count == 1000)

        await manager.nextPage()

        #expect(manager.offset == 2000)
        #expect(manager.rows.count == 503)

        await manager.previousPage()

        #expect(manager.offset == 1000)
        #expect(manager.rows.count == 1000)
    }

    @Test(
        "Advanced filters correctly subset database queries",
        arguments: [
            ("name", DatabaseManager.FilterOperator.equals, "Alice", 1),
            ("name", DatabaseManager.FilterOperator.contains, "ob", 1),
            ("age", DatabaseManager.FilterOperator.greaterThan, "28", 2),
        ])
    func advancedFiltering(
        column: String, op: DatabaseManager.FilterOperator, value: String, expectedCount: Int
    ) async throws {
        await manager.selectTable("users")
        manager.filters = [
            DatabaseManager.FilterCriteria(column: column, operatorType: op, value: value)
        ]
        await manager.applyFilter()
        #expect(manager.rows.count == expectedCount)

        await manager.clearFilter()
        #expect(manager.filters.count == 0)
        #expect(manager.rows.count == 3)
        #expect(manager.offset == 0)
    }

    @Test("Save active edits into valid SQL updates")
    func editingAndSavingStandardTable() async throws {
        await manager.selectTable("users")

        let firstRowId = manager.rows[0].id
        manager.startEditing(rowID: firstRowId, column: "name", currentValue: "Alice")
        manager.updateActiveEdit(rowID: firstRowId, column: "name", value: "Alicia")
        manager.applyEdits()

        #expect(manager.hasChanges)
        #expect(manager.pendingChanges[firstRowId]?["name"] == "Alicia")

        await manager.saveChanges()

        #expect(!manager.hasChanges)

        let verifyQueue = try DatabaseQueue(path: dbURL.path)
        try await verifyQueue.read { db in
            let alicias = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM users WHERE name = 'Alicia'")
            #expect(alicias == 1)
        }
    }

    @Test("Saving edits to a WITHOUT ROWID table uses primary keys dynamically")
    func editingAndSavingWithoutRowIDTable() async throws {
        await manager.selectTable("tags")
        let rowId = manager.rows[0].id
        manager.updateCell(rowID: rowId, column: "name", value: "swiftlang")
        await manager.saveChanges()

        let verifyQueue = try DatabaseQueue(path: dbURL.path)
        try await verifyQueue.read { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM tags WHERE name = 'swiftlang'")
            #expect(count == 1)
        }
    }

    @Test("Executing a custom SQL query binds ad-hoc columns")
    func customSQLConsole() async throws {
        await manager.executeCustomSQL("SELECT name, age FROM users ORDER BY age DESC LIMIT 2")

        #expect(manager.selectedTableName == nil)
        #expect(manager.columns == ["name", "age"])
        #expect(manager.rows.count == 2)
        #expect(manager.rows[0].data["name"] == "Charlie")
        #expect(manager.rows[1].data["name"] == "Alice")
    }

    @Test("State resetting methods clear relevant properties")
    func stateResetting() async throws {
        await manager.selectTable("users")
        manager.updateCell(rowID: manager.rows[0].id, column: "name", value: "New Name")
        manager.startEditing(rowID: manager.rows[1].id, column: "name", currentValue: "Bob")
        manager.filters = [
            DatabaseManager.FilterCriteria(column: "name", operatorType: .equals, value: "Alice")
        ]

        #expect(!manager.pendingChanges.isEmpty)
        #expect(!manager.activeEdits.isEmpty)
        #expect(!manager.filters.isEmpty)

        manager.selectedTableName = nil
        manager.rows = []
        manager.pendingChanges = [:]
        manager.filters = []
        #expect(manager.selectedTableName == nil)
        #expect(manager.rows.isEmpty)
        #expect(manager.pendingChanges.isEmpty)
        #expect(manager.filters.isEmpty)

        await manager.selectTable("users")
        manager.updateCell(rowID: manager.rows[0].id, column: "name", value: "New Name")
        manager.discardChanges()
        #expect(manager.pendingChanges.isEmpty)

        manager.startEditing(rowID: manager.rows[0].id, column: "name", currentValue: "Alice")
        manager.cancelEdits()
        #expect(manager.activeEdits.isEmpty)
    }

    @Test("Editing workflow prevents overwriting and applies correctly")
    func activeEditWorkflow() async throws {
        await manager.selectTable("users")
        let rowId = manager.rows[0].id

        manager.startEditing(rowID: rowId, column: "name", currentValue: "Alice")
        #expect(manager.activeEdits.count == 1)

        manager.startEditing(rowID: rowId, column: "name", currentValue: "Different")
        #expect(manager.activeEdits[rowId]?["name"] == "Alice")

        manager.updateActiveEdit(rowID: rowId, column: "name", value: "Alicia")
        manager.applyEdits()

        #expect(manager.activeEdits.isEmpty)
        #expect(manager.pendingChanges[rowId]?["name"] == "Alicia")
    }

    @Test("Pagination boundaries prevent out of bounds offsets")
    func paginationEdgeCases() async throws {
        await manager.selectTable("users")  // 3 rows
        manager.limit = 2

        #expect(manager.offset == 0)

        await manager.nextPage()
        #expect(manager.offset == 2)

        await manager.nextPage()
        #expect(manager.offset == 2)

        await manager.previousPage()
        #expect(manager.offset == 0)

        await manager.previousPage()
        #expect(manager.offset == 0)
    }

    @Test("Custom SQL with empty results still populates columns")
    func customSQLWithEmptyResults() async throws {
        await manager.executeCustomSQL("SELECT * FROM users WHERE id < 0")
        #expect(manager.rows.isEmpty)
        #expect(manager.columns == ["id", "name", "age"])
    }

    @Test(
        "All filter operators produce valid SQL and correct results",
        arguments: [
            (DatabaseManager.FilterOperator.notEquals, "Alice", 2),
            (DatabaseManager.FilterOperator.startsWith, "A", 1),
            (DatabaseManager.FilterOperator.endsWith, "e", 2),
            (DatabaseManager.FilterOperator.lessThan, "30", 1),
        ])
    func comprehensiveFiltering(
        op: DatabaseManager.FilterOperator, value: String, expectedCount: Int
    ) async throws {
        await manager.selectTable("users")
        manager.filters = [
            DatabaseManager.FilterCriteria(column: "name", operatorType: op, value: value)
        ]
        if op == .lessThan {
            manager.filters[0].column = "age"
        }
        await manager.applyFilter()
        #expect(manager.rows.count == expectedCount)
    }

    @Test("Save changes for table with no primary key using all columns fallback")
    func saveChangesWithNoPrimaryKey() async throws {
        await manager.executeCustomSQL("SELECT * FROM users")
        let viewRow = manager.rows[0]
        // This test case is a bit artificial but tests the fallback logic

        manager.selectedTableName = "users"
        manager.primaryKeyColumns = []
        manager.updateCell(rowID: viewRow.id, column: "name", value: "Alice Edited")

        manager.rows = [viewRow]
        manager.columns = ["name", "id", "age"]
        await manager.saveChanges()

        let verifyQueue = try DatabaseQueue(path: dbURL.path)
        try await verifyQueue.read { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM users WHERE name = 'Alice Edited'")
            #expect(count == 1)
        }
    }

    @Test("Database refresh picks up new external tables and columns")
    func testRefreshDatabasePicksUpExternalChanges() async throws {
        // 1. Initial State
        await manager.selectTable("users")
        #expect(manager.tableNames.contains("users"))
        #expect(!manager.tableNames.contains("new_external_table"))
        
        // 2. Simulate external change via a separate connection
        let externalDbQueue = try DatabaseQueue(path: dbURL.path)
        try await externalDbQueue.write { db in
            try db.execute(sql: "CREATE TABLE new_external_table (id INTEGER PRIMARY KEY, note TEXT);")
            try db.execute(sql: "INSERT INTO new_external_table (note) VALUES ('test note');")
            try db.execute(sql: "ALTER TABLE users ADD COLUMN external_col TEXT;")
        }
        
        // 3. Trigger refresh in the manager
        // This will internally call `selectTable("users")` which might race with prefetch
        await manager.refreshDatabase()
        
        // Ensure background schema prefetch completes so schema is fully available
        await manager.prefetchTask?.value
        
        // Let's re-select users to ensure the UI gets the updated columns from the cache
        await manager.selectTable("users")
        
        // 4. Verify new state
        #expect(manager.tableNames.contains("new_external_table"))
        
        // Verify users table picked up new column since it was technically re-selected during refresh
        #expect(manager.selectedTableName == "users")
        #expect(manager.columns.contains("external_col"))
        
        // Let's actually select the new table to prove the schema is working
        await manager.selectTable("new_external_table")
        #expect(manager.columns == ["id", "note"])
        #expect(manager.rows.count == 1)
        #expect(manager.rows[0].data["note"] == "test note")
    }
}
