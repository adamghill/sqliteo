# Suggestions for a Snappier SQLiteo UI

To make SQLiteo the "snappiest" SQLite editor, we need to minimize main-thread work and avoid redundant UI updates. Below are five ranked suggestions to optimize performance.

---

### 1. Surgical Table Updates (Minimize `reloadData()`)
**Current Bottleneck:** `DataTableView.updateNSView` calls `tableView.reloadData()` almost every time the `DatabaseManager` state changes. This includes every single keystroke during cell editing, which forces `NSTableView` to discard its view cache and re-query the coordinator for every visible cell.

**Suggestion:**
- Use `tableView.beginUpdates()` and `tableView.endUpdates()` for targeted changes.
- Only call `reloadData()` when the dataset changes fundamentally (e.g., new table selected, filter applied).
- For inline edits, update the `NSTableCellView` directly via its delegate or a targeted `reloadRows(at:with:)` call rather than a full reload.
- Track "dirty" rows in the coordinator to only refresh what has actually changed.

### 2. Incremental Loading (Infinite Scroll)
**Current Bottleneck:** The app currently fetches a fixed batch of 1,000 rows. For "wide" tables (many columns), this can lead to a noticeable lag when switching tables as GRDB fetches, maps, and stores 1,000 objects in memory.

**Suggestion:**
- Reduce the initial fetch to ~100 rows for instantaneous "first-paint."
- Implement "fetch-on-scroll" by detecting when the user nears the bottom of the `NSTableView` (via `tableViewVisibleRectDidChange` or `tableView(_:viewFor:row:)`).
- This makes opening any table feel instant, regardless of total row count.

### 3. Background Schema & Metadata Pre-fetching
**Current Bottleneck:** Schema information (columns, types, foreign keys) is fetched only when a table is selected. This adds latency to the first time a table is clicked.

**Suggestion:**
- When a database is first opened, spin up a background task to fetch the schema (`PRAGMA table_info`) and foreign key list for *all* tables.
- Cache this metadata in `DatabaseManager`.
- When a user clicks a table in the sidebar, the columns are already known, and the UI can immediately display the table headers while the row data fetches in the background.

### 4. Optimize Cell View Hierarchy
**Current Bottleneck:** The current `NSTableCellView` implementation uses an `NSStackView` containing an `NSTextField` and an `NSButton` for every cell. `NSStackView` is convenient but has significant auto-layout overhead when hundreds of cells are being scrolled or resized.

**Suggestion:**
- Replace `NSStackView` with manual layout constraints or frame-based layout in a custom `NSTableCellView` subclass.
- Use a single `NSTextField` and only add the "Foreign Key" button dynamically if the column actually has a relationship.
- This reduces the view count and layout complexity, leading to buttery-smooth 120fps scrolling on ProMotion displays.

### 5. Asynchronous SQL Autocomplete & Syntax Highlighting
**Current Bottleneck:** Autocomplete suggestions are updated via a `debounceTask` in `ContentView`, but the logic for matching keywords, tables, and columns can still grow heavy as the schema expands.

**Suggestion:**
- Move the fuzzy-matching and suggestion-generation logic to a dedicated background actor.
- Pre-compute the autocomplete index (keywords + table names + column names) once during the background pre-fetching phase (Suggestion #3).
- Ensure the UI only receives the final filtered list, keeping the typing experience in the SQL console lag-free.
