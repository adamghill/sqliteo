# SQLitizer Project Decisions

## Tech Stack
- **Language**: Swift 6.
- **UI Framework**: **SwiftUI** with **AppKit** (where needed).
    - *Rationale*: Unified SwiftUI architecture for navigation and state, but uses native `NSTableView` via `NSViewRepresentable` for high-performance data grids.
- **Database Library**: **GRDB.swift**.
    - *Rationale*: A powerful and modern SQLite toolkit for Swift. It makes it easy to work with SQLite in a type-safe way and integrates well with SwiftUI's reactive state.
- **Code Editor**: **CodeEditor**.
    - *Rationale*: Used for the SQL Console to provide syntax highlighting and a better editing experience for arbitrary SQL.
- **Build System**: **Swift Package Manager (SPM)**.
- **Target OS**: macOS 14.0+.

## Core Features
1. **File Management**: Open existing `.sqlite`, `.db`, or `.sqlite3` files.
2. **Schema Browser**: Sidebar showing tables.
3. **Data Viewer**: Native `NSTableView` wrapper for high-performance data grids with robust column resizing and global sorting.
4. **Data Editor**: Inline cell editing with transaction support and change tracking, implemented via `NSTextField` delegates for responsiveness.
5. **Filtering**: Column-based filtering with support for various operators (contains, equals, etc.), performed server-side for performance.
6. **SQL Editor**: SQL Console with syntax highlighting (via CodeEditor) and fuzzy-match autocomplete for keywords, tables, and columns.
7. **File Metadata**: Displaying file name, location, size, and modification date in the sidebar.
8. **Global Sorting**: Sort large datasets natively by tapping column headers, triggering SQL-based ordering.

## Architecture & Performance Rules
- **Native Table Implementation**: **NEVER** use SwiftUI's native `Table` or large `LazyVStack` lists for the main data grid. They suffer from compiler timeouts and scrolling regressions with dynamic columns. Use `NSTableView` via `NSViewRepresentable`.
- **Concurrency**: Use Swift `async/await` for all heavy database operations to keep the UI responsive.
- **MainActor**: All UI-facing properties in `DatabaseManager` must be `@MainActor` isolated.
- **Server-Side Operations**: Always perform Sorting, Filtering, and Pagination via SQL in the database layer. Avoid processing large arrays in memory at the view layer.
- **View Recycling**: Ensure `NSTableView` uses standard view-based re-use to minimize memory footprint.
- **SQL Console Isolation**: The SQL Console is treated as a distinct mode, clearing table data and deselecting tables when active to prevent environment ambiguity.

## Implementation Roadmap

### Phase 1: Native Shell (Completed)
- Initialize SPM project for a macOS Executable/App.
- Create the `App` and `ContentView` structure.
- Implement sidebar using `NavigationSplitView`.
- Basic SQLite connection using GRDB.

### Phase 2: Data Exploration (Completed)
- Implement a custom table view for row data.
- Dynamic column generation based on table schema.
- Sorting support.
- Column-based filtering.
- File metadata display.

### Phase 3: Data Editing (Completed)
- Inline cell editing using SwiftUI `TextField`.
- State management for unsaved changes (Save/Discard) with `activeEdits` and `pendingChanges`.

### Phase 4: Querying & Polish (Completed)
- [x] SQL console with syntax highlighting.
- [x] Fuzzy-match autocomplete for SQL.
- [x] Native macOS menu bar integration.
- [x] SF Symbols integration for a native look.
- [x] GitHub Actions for automated releases.
- [x] **Performance Optimization**: Replaced SwiftUI Table with native `NSTableView`.
- [x] **Global Sorting**: Implemented server-side ordering.
- [x] **Sidebar Search**: Fuzzy-match filter for table names in the sidebar.

### Future Enhancements
- Export query results to CSV/JSON/SQL statement
- Drag-and-drop table names into SQL query (from sidebar)
- Clickable foreign key values for navigation
- Version check and update notifications (check GitHub releases)
- Tabs for multiple ad-hoc sql queries
- Package signing
