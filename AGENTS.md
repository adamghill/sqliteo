# SQLitizer Project Decisions

## Tech Stack
- **Language**: Swift 6.
- **UI Framework**: **SwiftUI**.
    - *Rationale*: 100% native macOS experience. Provides the best performance, system integration (vibrancy, dark mode, system menus), and long-term maintainability for a Mac app.
- **Database Library**: **GRDB.swift**.
    - *Rationale*: A powerful and modern SQLite toolkit for Swift. It makes it easy to work with SQLite in a type-safe way and integrates well with SwiftUI's reactive state.
- **Code Editor**: **CodeEditor**.
    - *Rationale*: Used for the SQL Console to provide syntax highlighting and a better editing experience for arbitrary SQL.
- **Build System**: **Swift Package Manager (SPM)**.
- **Target OS**: macOS 14.0+.

## Core Features
1. **File Management**: Open existing `.sqlite`, `.db`, or `.sqlite3` files.
2. **Schema Browser**: Sidebar showing tables.
3. **Data Viewer**: Custom `Table` view implementation with lazy loading for high performance.
4. **Data Editor**: Inline cell editing with transaction support and change tracking.
5. **Filtering**: Column-based filtering with support for various operators (contains, equals, etc.).
6. **SQL Editor**: SQL Console with syntax highlighting (via CodeEditor) and fuzzy-match autocomplete for keywords, tables, and columns.
7. **File Metadata**: Displaying file name, location, size, and modification date in the sidebar.

## Architecture & Performance
- **Concurrency**: Use Swift `async/await` for all heavy database operations to keep the UI responsive.
- **MainActor**: Ensure all UI updates happen on the main thread via `@MainActor` isolation.
- **Reactive State**: Use `@Observable` (Observation framework) for clean state management in `DatabaseManager`.
- **Background Processing**: Execute database reads/writes on background threads to avoid blocking the main run loop.
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

### Phase 4: Querying & Polish (Completed/In-Progress)
- [x] SQL console with syntax highlighting.
- [x] Fuzzy-match autocomplete for SQL.
- [x] Native macOS menu bar integration.
- [x] SF Symbols integration for a native look.
- [x] GitHub Actions for automated releases.

### Future Enhancements
- Export query results to CSV/JSON.
- Import data from CSV/JSON.
- Drag-and-drop table names into SQL query.
- Clickable foreign key values for navigation.
- Version check and update notifications.

