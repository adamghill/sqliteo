import Foundation
import Testing

@testable import SQLiteo

struct SQLQueryExtractionTests {
    @Test func testSelectionExactMatchIfRangeHasLength() {
        let sql = "SELECT * FROM users; SELECT * FROM posts;"
        let query = SQLQuery(id: UUID(), name: "Test", sql: sql, isPersisted: false)

        let start = sql.index(sql.startIndex, offsetBy: 7)
        let end = sql.index(sql.startIndex, offsetBy: 12)
        let selection = start..<end

        let range = query.rangeToExecute(withSelection: selection)
        let extracted = String(sql[range])

        #expect(extracted == "* FRO")
    }

    @Test func testSingleQueryNoSemicolon() {
        let sql = "SELECT * FROM users"
        let query = SQLQuery(id: UUID(), name: "Test", sql: sql, isPersisted: false)
        let selection = sql.startIndex..<sql.startIndex

        let range = query.rangeToExecute(withSelection: selection)
        let extracted = String(sql[range])

        #expect(extracted == "SELECT * FROM users")
    }

    @Test func testMultipleQueriesFirstSelected() {
        let sql = "SELECT * FROM users; SELECT * FROM posts;"
        let query = SQLQuery(id: UUID(), name: "Test", sql: sql, isPersisted: false)

        // Cursor at index 5 in the first query
        let cursor = sql.index(sql.startIndex, offsetBy: 5)
        let selection = cursor..<cursor

        let range = query.rangeToExecute(withSelection: selection)
        #expect(String(sql[range]) == "SELECT * FROM users")
    }

    @Test func testMultipleQueriesSecondSelected() {
        let sql = "SELECT * FROM users; SELECT * FROM posts;"
        let query = SQLQuery(id: UUID(), name: "Test", sql: sql, isPersisted: false)

        // Cursor at index 25 in the second query
        let cursor = sql.index(sql.startIndex, offsetBy: 25)
        let selection = cursor..<cursor

        let range = query.rangeToExecute(withSelection: selection)
        #expect(String(sql[range]) == "SELECT * FROM posts")
    }

    @Test func testMultipleQueriesMiddleSelected() {
        let sql = "SELECT * FROM a; SELECT * FROM b; SELECT * FROM c;"
        let query = SQLQuery(id: UUID(), name: "Test", sql: sql, isPersisted: false)

        // Cursor at index 20 in the middle query
        let cursor = sql.index(sql.startIndex, offsetBy: 20)
        let selection = cursor..<cursor

        let range = query.rangeToExecute(withSelection: selection)
        #expect(String(sql[range]) == "SELECT * FROM b")
    }

    @Test func testCursorAfterLastSemicolon() {
        let sql = "SELECT * FROM users;\n\n"
        let query = SQLQuery(id: UUID(), name: "Test", sql: sql, isPersisted: false)
        let cursor = sql.index(sql.startIndex, offsetBy: 21)  // In trailing newlines
        let selection = cursor..<cursor

        let range = query.rangeToExecute(withSelection: selection)
        let extracted = String(sql[range])
        #expect(extracted == "SELECT * FROM users;\n\n")
    }

    @Test func testCursorBeforeFirstQueryWithWhitespace() {
        let sql = "   \nSELECT * FROM users; SELECT * FROM posts;"
        let query = SQLQuery(id: UUID(), name: "Test", sql: sql, isPersisted: false)
        let cursor = sql.index(sql.startIndex, offsetBy: 1)  // In prefix whitespaces
        let selection = cursor..<cursor

        let range = query.rangeToExecute(withSelection: selection)
        let extracted = String(sql[range])

        #expect(extracted == "SELECT * FROM users")
    }
}
