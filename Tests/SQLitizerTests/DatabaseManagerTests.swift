import GRDB
import XCTest

@testable import SQLitizer

@MainActor
final class DatabaseManagerTests: XCTestCase {
    func testListTables() async throws {
        let manager = DatabaseManager()
        let dbQueue = try DatabaseQueue()  // In-memory

        // Compiler indicates this is async in this context
        try await dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)")
            try db.execute(sql: "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)")
        }

        manager.dbQueue = dbQueue
        await manager.fetchTables()

        XCTAssertTrue(manager.tableNames.contains("users"))
        XCTAssertTrue(manager.tableNames.contains("posts"))
    }
}
