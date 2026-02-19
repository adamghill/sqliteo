import SwiftUI

struct ContentView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @State private var showSQLConsole = false
    @State private var customSQL = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if let url = dbManager.currentFileURL, let size = dbManager.currentFileSize {
                    FileMetadataView(url: url, size: size)
                }

                List(
                    dbManager.tableNames, id: \.self,
                    selection: Bindable(dbManager).selectedTableName
                ) { tableName in
                    Text(tableName)
                        .tag(tableName)
                }
                .navigationTitle("Tables")
                .listStyle(.sidebar)
            }
            .onChange(of: dbManager.selectedTableName) { _, newValue in
                if let tableName = newValue {
                    Task {
                        await dbManager.selectTable(tableName)
                    }
                }
            }
        } detail: {
            if showSQLConsole {
                VStack(spacing: 0) {
                    TextEditor(text: $customSQL)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 150)
                        .padding(4)
                        .background(Color(NSColor.textBackgroundColor))

                    HStack {
                        Button {
                            Task {
                                await dbManager.executeCustomSQL(customSQL)
                            }
                        } label: {
                            Label("Run Query", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)

                        Spacer()

                        Button {
                            showSQLConsole = false
                        } label: {
                            Label("Hide", systemImage: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color(NSColor.windowBackgroundColor))

                    Divider()

                    DataTableView()
                }
                .navigationTitle("SQL Console")
            } else if let tableName = dbManager.selectedTableName {
                DataTableView()
                    .navigationTitle(tableName)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showSQLConsole.toggle()
                            } label: {
                                Label("SQL Console", systemImage: "terminal")
                            }
                            .help("Open SQL Console (Cmd+T)")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button {
                                Task {
                                    await dbManager.saveChanges()
                                }
                            } label: {
                                Label("Save", systemImage: "checkmark.circle.fill")
                            }
                            .disabled(!dbManager.hasChanges)
                            .help("Save changes to database")
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                dbManager.discardChanges()
                            } label: {
                                Label("Discard", systemImage: "arrow.uturn.backward.circle")
                            }
                            .disabled(!dbManager.hasChanges)
                            .help("Discard unsaved changes")
                        }
                    }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "square.grid.3x2")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a table or open a database")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Button("Open SQLite File...") {
                        dbManager.openFile()
                    }
                    .buttonStyle(.borderedProminent)

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
        .overlay {
            if dbManager.isLoading {
                ZStack {
                    Color.black.opacity(0.1)
                    ProgressView("Loading...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }
            }
        }
    }
}

struct DataTableView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @State private var localFilterText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if dbManager.selectedTableName != nil {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(.secondary)

                    TextField("Filter rows...", text: $localFilterText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            dbManager.filterText = localFilterText
                            Task {
                                await dbManager.applyFilter()
                            }
                        }

                    Button {
                        dbManager.filterText = localFilterText
                        Task {
                            await dbManager.applyFilter()
                        }
                    } label: {
                        Label("Apply", systemImage: "line.3.horizontal.decrease.circle.fill")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        localFilterText = ""
                        Task {
                            await dbManager.clearFilter()
                        }
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .disabled(localFilterText.isEmpty && dbManager.filterText.isEmpty)
                }
                .padding(8)
                .background(Color(NSColor.windowBackgroundColor))

                Divider()
            }

            if dbManager.columns.isEmpty {
                VStack {
                    Spacer()
                    Text("No data to display")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders])
                        {
                            Section(header: HeaderView(columns: dbManager.columns)) {
                                ForEach(dbManager.rows) { row in
                                    RowView(row: row, columns: dbManager.columns)
                                }
                            }
                        }
                        .frame(
                            minWidth: max(
                                geometry.size.width, CGFloat(dbManager.columns.count) * 150),
                            minHeight: geometry.size.height,
                            alignment: .topLeading
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HeaderView: View {
    let columns: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                Text(column)
                    .font(.headline)
                    .padding(8)
                    .frame(width: 150, alignment: .leading)
                    .background(Color(NSColor.windowBackgroundColor))
                    .border(Color.secondary.opacity(0.2))
            }
            Spacer(minLength: 0)
        }
    }
}

struct RowView: View {
    let row: DBRow
    let columns: [String]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                CellView(
                    rowID: row.id, column: column,
                    initialValue: row.data[column] ?? "")
            }
            Spacer(minLength: 0)
        }
    }
}

struct CellView: View {
    @Environment(DatabaseManager.self) private var dbManager
    let rowID: UUID
    let column: String
    let initialValue: String

    @State private var text: String

    init(rowID: UUID, column: String, initialValue: String) {
        self.rowID = rowID
        self.column = column
        self.initialValue = initialValue
        _text = State(initialValue: initialValue)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .padding(8)
            .frame(width: 150, alignment: .leading)
            .background(isEdited ? Color.blue.opacity(0.1) : Color.clear)
            .border(Color.secondary.opacity(0.1))
            .onChange(of: text) { _, newValue in
                if newValue != initialValue {
                    dbManager.updateCell(rowID: rowID, column: column, value: newValue)
                }
            }
            .onChange(of: dbManager.pendingChanges) { _, _ in
                // If changes were discarded or saved (pendingChanges cleared), reset text to current db value if it's not in pending
                if dbManager.pendingChanges[rowID]?[column] == nil {
                    text = initialValue
                }
            }
    }

    var isEdited: Bool {
        dbManager.pendingChanges[rowID]?[column] != nil
    }
}

struct FileMetadataView: View {
    let url: URL
    let size: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "cylinder.split.1x2.fill")
                    .foregroundColor(.accentColor)
                Text(url.lastPathComponent)
                    .font(.headline)
            }

            Text(url.path)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)

            Text(size)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
