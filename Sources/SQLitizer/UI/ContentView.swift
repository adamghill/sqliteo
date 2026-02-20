import SwiftUI

struct ContentView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @State private var showSQLConsole = false
    @State private var customSQL = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(
                    dbManager.tableNames, id: \.self,
                    selection: Bindable(dbManager).selectedTableName
                ) { tableName in
                    Text(tableName)
                        .tag(tableName)
                }
                .navigationTitle("Tables")
                .listStyle(.sidebar)

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
                    Task {
                        await dbManager.selectTable(tableName)
                    }
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

    var body: some View {
        VStack(spacing: 0) {
            if dbManager.selectedTableName != nil {
                FilterView()
                    .padding(.bottom, 8)
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
                    ZStack(alignment: .bottom) {
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(
                                alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]
                            ) {
                                Section(header: HeaderView(columns: dbManager.columns)) {
                                    ForEach(dbManager.rows) { row in
                                        RowView(row: row, columns: dbManager.columns)
                                    }
                                }
                            }
                            // Add extra padding at the bottom so content isn't covered by the edit bar
                            .padding(.bottom, !dbManager.activeEdits.isEmpty ? 60 : 0)
                            .frame(
                                minWidth: max(
                                    geometry.size.width, CGFloat(dbManager.columns.count) * 150),
                                minHeight: geometry.size.height,
                                alignment: .topLeading
                            )
                        }
                        .padding(.horizontal)

                        if !dbManager.activeEdits.isEmpty {
                            EditControlBar()
                                .transition(.move(edge: .bottom))
                        }
                    }
                }
            }

            StatusBar()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EditControlBar: View {
    @Environment(DatabaseManager.self) private var dbManager

    var body: some View {
        HStack {
            Text("Editing \(dbManager.activeEdits.count) cell(s)...")
                .font(.headline)
                .foregroundColor(.secondary)

            Spacer()

            Button {
                dbManager.cancelEdits()
            } label: {
                Text("Cancel")
            }
            .keyboardShortcut(.escape, modifiers: [])

            Button {
                dbManager.applyEdits()
            } label: {
                Text("Apply")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .top)
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
    let rowID: TableRowID
    let column: String
    let initialValue: String

    var body: some View {
        ZStack(alignment: .leading) {
            if isEditing {
                TextField(
                    "",
                    text: Binding(
                        get: { dbManager.activeEdits[CellID(rowID: rowID, column: column)] ?? "" },
                        set: { dbManager.updateActiveEdit(rowID: rowID, column: column, value: $0) }
                    )
                )
                .textFieldStyle(.plain)
                .padding(8)
                .frame(width: 150, alignment: .leading)
                .background(Color.blue.opacity(0.1))
                .onSubmit {
                    // dbManager.applyEdits() // Don't apply on enter, let them edit multiple
                }
            } else {
                Text(displayValue)
                    .lineLimit(1)
                    .padding(8)
                    .frame(width: 150, alignment: .leading)
                    .background(hasPendingChanges ? Color.yellow.opacity(0.1) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dbManager.startEditing(
                            rowID: rowID, column: column, currentValue: displayValue)
                    }
            }
        }
        .border(Color.secondary.opacity(0.1))
    }

    var isEditing: Bool {
        dbManager.activeEdits[CellID(rowID: rowID, column: column)] != nil
    }

    private func CellID(rowID: TableRowID, column: String) -> DatabaseManager.CellID {
        DatabaseManager.CellID(rowID: rowID, column: column)
    }

    var hasPendingChanges: Bool {
        dbManager.pendingChanges[rowID]?[column] != nil
    }

    var displayValue: String {
        if let pending = dbManager.pendingChanges[rowID]?[column] {
            return pending
        }
        return initialValue
    }
}

struct StatusBar: View {
    @Environment(DatabaseManager.self) private var dbManager

    var body: some View {
        HStack {
            Text("Total Rows: \(dbManager.totalRows)")

            Spacer()

            Button {
                dbManager.previousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(dbManager.offset == 0)

            Text("Page \(currentPage) of \(totalPages)")
                .monospacedDigit()

            Button {
                dbManager.nextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(dbManager.offset + dbManager.limit >= dbManager.totalRows)
        }
        .padding(8)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }

    var currentPage: Int {
        if dbManager.limit == 0 { return 1 }
        return (dbManager.offset / dbManager.limit) + 1
    }

    var totalPages: Int {
        if dbManager.limit == 0 { return 1 }
        return max(1, Int(ceil(Double(dbManager.totalRows) / Double(dbManager.limit))))
    }
}

struct FileMetadataView: View {
    let fileName: String
    let filePath: String
    let fileSize: Int64
    let dateModified: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fileName)
                .font(.headline)
            Text(filePath)
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Size: \(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Modified: \(dateModified.formatted())")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct FilterView: View {
    @Environment(DatabaseManager.self) private var dbManager

    var body: some View {
        @Bindable var dbManager = dbManager

        VStack(alignment: .leading, spacing: 8) {
            ForEach($dbManager.filters) { $filter in
                HStack {
                    if !dbManager.columns.isEmpty {
                        Picker("Column", selection: $filter.column) {
                            ForEach(dbManager.columns, id: \.self) { column in
                                Text(column).tag(column)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    Picker("Operator", selection: $filter.operatorType) {
                        ForEach(DatabaseManager.FilterOperator.allCases) { op in
                            Text(op.rawValue).tag(op)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)

                    TextField("Value", text: $filter.value)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        if let index = dbManager.filters.firstIndex(where: { $0.id == filter.id }) {
                            dbManager.filters.remove(at: index)
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button {
                    let firstColumn = dbManager.columns.first ?? ""
                    let newFilter = DatabaseManager.FilterCriteria(
                        column: firstColumn,
                        operatorType: .contains,
                        value: ""
                    )
                    dbManager.filters.append(newFilter)
                } label: {
                    Label("Add Filter", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(dbManager.columns.isEmpty)

                Spacer()

                Button("Apply") {
                    Task {
                        await dbManager.applyFilter()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(dbManager.filters.isEmpty)

                Button("Clear") {
                    Task {
                        await dbManager.clearFilter()
                    }
                }
                .disabled(dbManager.filters.isEmpty)
            }
        }
        .padding(8)
    }
}
