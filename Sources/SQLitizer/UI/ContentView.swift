import CodeEditor
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case data = "Data"
    case schema = "Schema"
    var id: String { rawValue }
}

struct ContentView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @Environment(SQLQueryStore.self) private var queryStore
    @State private var selectedTab: Tab = .data
    @State private var tableFilter = ""
    @State private var queryFilter = ""

    // Autocomplete State
    @State private var suggestions: [String] = []
    @State private var showSuggestions = false
    @State private var currentWord = ""
    @State private var debounceTask: Task<Void, Never>?

    // Inline rename state
    @State private var editingQueryID: UUID?
    @State private var editingQueryName: String = ""

    // Editor & Sidebar UI State
    @State private var sqlSelection = "".startIndex..<"".endIndex
    @AppStorage("sqlQueriesHeight") private var savedSqlQueriesHeight: Double = 150
    @State private var activeSqlQueriesHeight: Double? = nil
    @State private var dragStartHeight: Double? = nil
    @State private var isDraggingDivider = false

    // Editor Resizing State
    @AppStorage("sqlEditorHeight") private var savedSqlEditorHeight: Double = 150
    @State private var activeSqlEditorHeight: Double? = nil
    @State private var editorDragStartHeight: Double? = nil
    @State private var isDraggingEditorDivider = false

    private var sqlQueriesHeight: Double {
        activeSqlQueriesHeight ?? savedSqlQueriesHeight
    }

    private var sqlEditorHeight: Double {
        activeSqlEditorHeight ?? savedSqlEditorHeight
    }

    private let sqlKeywords = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
        "DELETE", "CREATE", "TABLE", "DROP", "ALTER", "AND", "OR", "NOT",
        "ORDER BY", "GROUP BY", "JOIN", "INNER JOIN", "LEFT JOIN", "ON", "AS",
        "ASC", "DESC", "LIMIT", "OFFSET", "PRAGMA",
    ]

    private var filteredTableNames: [String] {
        if tableFilter.isEmpty {
            return dbManager.tableNames
        }
        return dbManager.tableNames.filter { $0.fuzzyMatch(query: tableFilter) }
    }

    private var filteredQueries: [SQLQuery] {
        let queries = queryStore.queries
        if queryFilter.isEmpty {
            return queries
        }
        return queries.filter { $0.name.fuzzyMatch(query: queryFilter) }
    }

    /// Binding into the selected query's SQL content
    private var selectedQuerySQL: Binding<String> {
        Binding(
            get: { queryStore.selectedQuery?.sql ?? "" },
            set: { newValue in
                if let id = queryStore.selectedQueryID {
                    queryStore.updateSQL(id: id, sql: newValue)
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // MARK: - SQL Queries Section
                if dbManager.fileURL != nil {
                    sqlQueriesSection
                        .frame(height: max(60, sqlQueriesHeight))

                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 1)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside {
                                NSCursor.resizeUpDown.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(coordinateSpace: .global)
                                .onChanged { value in
                                    isDraggingDivider = true
                                    if dragStartHeight == nil {
                                        dragStartHeight = sqlQueriesHeight
                                    }
                                    if let start = dragStartHeight {
                                        activeSqlQueriesHeight = max(
                                            60, start + value.translation.height)
                                    }
                                }
                                .onEnded { _ in
                                    if let finalHeight = activeSqlQueriesHeight {
                                        savedSqlQueriesHeight = finalHeight
                                    }
                                    dragStartHeight = nil
                                    activeSqlQueriesHeight = nil
                                    isDraggingDivider = false
                                }
                        )
                }

                // MARK: - Tables Section
                List(
                    filteredTableNames, id: \.self,
                    selection: Bindable(dbManager).selectedTableName
                ) { tableName in
                    Text(tableName)
                        .tag(tableName)
                }
                .navigationTitle("Tables")
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("Filter", text: $tableFilter)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !tableFilter.isEmpty {
                        Button {
                            tableFilter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)

                if let fileURL = dbManager.fileURL {
                    Divider()
                    FileMetadataView(
                        fileName: fileURL.lastPathComponent,
                        filePath: fileURL.path,
                        fileSize: dbManager.fileSize,
                        dateModified: dbManager.modificationDate ?? Date()
                    )
                    .padding()
                }
            }
            .onChange(of: dbManager.selectedTableName) { _, newValue in
                if let tableName = newValue {
                    // Deselect any query when a table is selected
                    queryStore.selectedQueryID = nil
                    Task {
                        await dbManager.selectTable(tableName)
                    }
                }
            }
            .onChange(of: queryStore.selectedQueryID) { _, newID in
                // Reset sqlSelection when changing queries to prevent out-of-bounds crashes
                // in CodeEditor if the new query's string is shorter than the old query's Selection.
                let empty = ""
                sqlSelection = empty.startIndex..<empty.endIndex
            }
            .onChange(of: dbManager.fileURL) { _, newURL in
                if let url = newURL {
                    queryStore.configure(for: url)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: dbManager.openFile) {
                        Label("Open Database", systemImage: "folder")
                    }
                }
            }
        } detail: {
            if let query = queryStore.selectedQuery {
                // SQL Query Editor
                VStack(spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        CodeEditor(
                            source: selectedQuerySQL, selection: $sqlSelection, language: .sql
                        )
                        .frame(height: max(60, sqlEditorHeight))
                        .padding(4)
                        .background(Color(NSColor.textBackgroundColor))
                        // Disable updates to this view while dragging the divider
                        .allowsHitTesting(!isDraggingEditorDivider)
                        .onChange(of: queryStore.selectedQuery?.sql) { _, newValue in
                            debounceTask?.cancel()
                            debounceTask = Task {
                                try? await Task.sleep(nanoseconds: 150_000_000)
                                guard !Task.isCancelled else { return }
                                await updateSuggestions(for: newValue ?? "")
                            }
                        }
                        .onKeyPress(.space, phases: .down) { press in
                            if press.modifiers.contains(.control) {
                                Task {
                                    await updateSuggestions(
                                        for: queryStore.selectedQuery?.sql ?? "")
                                }
                                return .handled
                            }
                            return .ignored
                        }
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.command) {
                                let range = query.rangeToExecute(withSelection: sqlSelection)
                                sqlSelection = range
                                let text = String(query.sql[range])
                                Task {
                                    await dbManager.executeCustomSQL(text)
                                }
                                return .handled
                            }
                            return .ignored
                        }

                        if showSuggestions && !suggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(suggestions, id: \.self) { suggestion in
                                        Button {
                                            insertSuggestion(suggestion)
                                        } label: {
                                            Text(suggestion)
                                                .font(.caption)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.accentColor.opacity(0.2))
                                                .cornerRadius(4)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .background(.regularMaterial)
                            .cornerRadius(6)
                            .shadow(radius: 2)
                            .padding(.leading, 8)
                            .padding(.bottom, 8)
                        }
                    }

                    HStack {
                        Button {
                            let range = query.rangeToExecute(withSelection: sqlSelection)
                            sqlSelection = range
                            let text = String(query.sql[range])
                            Task {
                                await dbManager.executeCustomSQL(text)
                            }
                        } label: {
                            Label("Run Query", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)

                        Spacer()
                    }
                    .padding(8)
                    .background(Color(NSColor.windowBackgroundColor))

                    Rectangle()
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 1)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside {
                                NSCursor.resizeUpDown.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(coordinateSpace: .global)
                                .onChanged { value in
                                    isDraggingEditorDivider = true
                                    if editorDragStartHeight == nil {
                                        editorDragStartHeight = sqlEditorHeight
                                    }
                                    if let start = editorDragStartHeight {
                                        activeSqlEditorHeight = max(
                                            60, start + value.translation.height)
                                    }
                                }
                                .onEnded { _ in
                                    if let finalHeight = activeSqlEditorHeight {
                                        savedSqlEditorHeight = finalHeight
                                    }
                                    editorDragStartHeight = nil
                                    activeSqlEditorHeight = nil
                                    isDraggingEditorDivider = false
                                }
                        )

                    DataTableView()
                    StatusBar(selectedTab: $selectedTab, showTabs: false)
                }
                .navigationTitle(query.name)
                .overlay(LoadingOverlay(isLoading: dbManager.isLoading))
            } else if let tableName = dbManager.selectedTableName {
                VStack(spacing: 0) {
                    switch selectedTab {
                    case .data:
                        DataTableView()
                    case .schema:
                        SchemaView()
                    }

                    StatusBar(selectedTab: $selectedTab)
                }
                .navigationTitle(tableName)
                .overlay(LoadingOverlay(isLoading: dbManager.isLoading))

            } else {
                VStack(spacing: 20) {
                    Image(systemName: "square.grid.3x2")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    if dbManager.fileURL != nil {
                        Text("Select a table or a SQL query")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Open a database")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Button("Open SQLite File...") {
                            dbManager.openFile()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let error = dbManager.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    // MARK: - SQL Queries Sidebar Section

    private var sqlQueriesSection: some View {
        VStack(spacing: 0) {
            // Section Header
            HStack {
                Text("SQL Queries")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    let newQuery = queryStore.addQuery()
                    // Deselect table when a query is added
                    dbManager.clearDataForSQLConsole()
                    queryStore.selectedQueryID = newQuery.id
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New SQL Query")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Query List
            List(
                selection: Binding(
                    get: { queryStore.selectedQueryID },
                    set: { newID in
                        if let id = newID {
                            queryStore.selectedQueryID = id
                            // Deselect table when query is selected
                            dbManager.clearDataForSQLConsole()
                        }
                    }
                )
            ) {
                ForEach(filteredQueries) { query in
                    queryRow(for: query)
                        .tag(query.id)
                }
            }
            .listStyle(.sidebar)

            // Query Filter
            if queryStore.queries.count > 3 {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    TextField("Filter queries", text: $queryFilter)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !queryFilter.isEmpty {
                        Button {
                            queryFilter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func queryRow(for query: SQLQuery) -> some View {
        if editingQueryID == query.id {
            TextField(
                "Query name", text: $editingQueryName,
                onCommit: {
                    queryStore.renameQuery(id: query.id, to: editingQueryName)
                    editingQueryID = nil
                }
            )
            .textFieldStyle(.plain)
            .font(.body)
            .onExitCommand {
                editingQueryID = nil
            }
        } else {
            Text(query.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Rename") {
                        editingQueryID = query.id
                        editingQueryName = query.name
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        queryStore.deleteQuery(id: query.id)
                    }
                }
        }
    }

    // MARK: - Autocomplete Logic

    private func updateSuggestions(for text: String) async {
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        guard let lastWord = words.last else {
            showSuggestions = false
            suggestions = []
            return
        }

        currentWord = lastWord
        let previousWord = words.dropLast().last?.uppercased()

        var keywordMatches: [String] = []
        var tableMatches: [String] = []
        var columnMatches: [String] = []

        let wordToMatch = lastWord.lowercased()

        // Handle alias patterns like `P.` -> suggest columns
        let components = lastWord.split(separator: ".")
        let aliasColumnPrefix =
            components.count == 2
            ? String(components[1]).lowercased() : (lastWord.hasSuffix(".") ? "" : nil)

        // If typing an alias (e.g. "P.")
        if let prefix = aliasColumnPrefix {
            // Suggest columns for tables present in the query
            let queryUpper = text.uppercased()
            let tablesInQuery = dbManager.tableNames.filter { queryUpper.contains($0.uppercased()) }
            if !tablesInQuery.isEmpty {
                let columnsForQuery = await dbManager.columns(for: tablesInQuery)
                columnMatches = columnsForQuery.filter {
                    $0.localizedCaseInsensitiveContains(prefix)
                }
            } else {
                columnMatches = dbManager.columns.filter {
                    $0.localizedCaseInsensitiveContains(prefix)
                }
            }
        }
        // If the previous word indicates we need a table (FROM, JOIN)
        else if previousWord == "FROM" || previousWord == "JOIN" {
            tableMatches = dbManager.tableNames.filter {
                $0.localizedCaseInsensitiveContains(wordToMatch)
            }
        }
        // If the previous word indicates we need a column (WHERE, ON, SELECT)
        else if previousWord == "WHERE" || previousWord == "ON" || previousWord == "SELECT" {
            // Find tables mentioned in the query to suggest their columns
            let queryUpper = text.uppercased()
            let tablesInQuery = dbManager.tableNames.filter { queryUpper.contains($0.uppercased()) }

            if !tablesInQuery.isEmpty {
                let columnsForQuery = await dbManager.columns(for: tablesInQuery)
                columnMatches = columnsForQuery.filter {
                    $0.localizedCaseInsensitiveContains(wordToMatch)
                }
            } else {
                columnMatches = dbManager.columns.filter {
                    $0.localizedCaseInsensitiveContains(wordToMatch)
                }
            }
        }
        // Otherwise, general autocomplete
        else {
            if !wordToMatch.isEmpty {
                keywordMatches = sqlKeywords.filter {
                    $0.localizedCaseInsensitiveContains(wordToMatch)
                }
                tableMatches = dbManager.tableNames.filter {
                    $0.localizedCaseInsensitiveContains(wordToMatch)
                }
                columnMatches = dbManager.columns.filter {
                    $0.localizedCaseInsensitiveContains(wordToMatch)
                }
            }
        }

        let allMatches = Array(Set(keywordMatches + tableMatches + columnMatches)).sorted()

        suggestions = allMatches
        showSuggestions = !suggestions.isEmpty
    }

    private func insertSuggestion(_ suggestion: String) {
        guard let queryID = queryStore.selectedQueryID,
            var sql = queryStore.selectedQuery?.sql
        else { return }

        if currentWord.isEmpty {
            sql += suggestion + " "
        } else {
            if currentWord.contains(".") {
                let parts = currentWord.components(separatedBy: ".")
                let prefix = parts.first ?? ""
                sql = String(sql.dropLast(currentWord.count)) + "\(prefix).\(suggestion) "
            } else {
                sql = String(sql.dropLast(currentWord.count)) + "\(suggestion) "
            }
        }

        queryStore.updateSQL(id: queryID, sql: sql)
        currentWord = ""
        showSuggestions = false
    }

    private func textToExecute(for query: SQLQuery) -> String {
        let range = query.rangeToExecute(withSelection: sqlSelection)
        return String(query.sql[range])
    }
}
