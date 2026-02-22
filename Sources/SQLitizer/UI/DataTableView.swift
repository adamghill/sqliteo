import AppKit
import SwiftUI

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
                ZStack(alignment: .bottom) {
                    DataTableRepresentable()
                        .padding(.bottom, !dbManager.activeEdits.isEmpty ? 60 : 0)

                    if !dbManager.activeEdits.isEmpty {
                        EditControlBar()
                            .transition(.move(edge: .bottom))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DataTableRepresentable: NSViewRepresentable {
    @Environment(DatabaseManager.self) private var dbManager

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.headerView = NSTableHeaderView()
        tableView.cornerView = nil
        tableView.autoresizingMask = [.width, .height]
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 24

        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let tableView = nsView.documentView as! NSTableView

        let columnsChanged = context.coordinator.updateColumns(
            for: tableView, columns: dbManager.columns)

        if columnsChanged || context.coordinator.lastRowCount != dbManager.rows.count {
            context.coordinator.lastRowCount = dbManager.rows.count
            tableView.reloadData()
        } else {
            // Check if any visible rows need updating (simple approach: reload all for now)
            tableView.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: DataTableRepresentable
        var columns: [String] = []
        var lastRowCount: Int = 0

        init(_ parent: DataTableRepresentable) {
            self.parent = parent
        }

        func updateColumns(for tableView: NSTableView, columns: [String]) -> Bool {
            guard self.columns != columns else { return false }
            self.columns = columns

            // Remove existing columns
            while tableView.tableColumns.count > 0 {
                tableView.removeTableColumn(tableView.tableColumns[0])
            }

            // Add new columns
            for colName in columns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colName))
                column.title = colName
                column.width = 150
                column.sortDescriptorPrototype = NSSortDescriptor(key: colName, ascending: true)
                tableView.addTableColumn(column)
            }
            return true
        }

        func tableView(
            _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard let sortDescriptor = tableView.sortDescriptors.first else { return }

            parent.dbManager.sortColumn = sortDescriptor.key
            parent.dbManager.sortAscending = sortDescriptor.ascending

            Task {
                if let tableName = parent.dbManager.selectedTableName {
                    try? await parent.dbManager.fetchRows(for: tableName)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.dbManager.rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
            -> NSView?
        {
            guard let identifier = tableColumn?.identifier.rawValue,
                row < parent.dbManager.rows.count
            else { return nil }

            let dbRow = parent.dbManager.rows[row]
            let value = dbRow.data[identifier] ?? ""

            // Re-use or create view
            let cellIdentifier = NSUserInterfaceItemIdentifier("DataCell")
            var cellView =
                tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView

            if cellView == nil {
                cellView = NSTableCellView()
                cellView?.identifier = cellIdentifier

                let textField = NSTextField()
                textField.identifier = NSUserInterfaceItemIdentifier("TextField")
                textField.delegate = self
                textField.isEditable = true
                textField.isSelectable = true
                textField.drawsBackground = false
                textField.isBordered = false
                textField.focusRingType = .none
                textField.translatesAutoresizingMaskIntoConstraints = false

                cellView?.addSubview(textField)
                cellView?.textField = textField

                if let cell = cellView {
                    NSLayoutConstraint.activate([
                        textField.leadingAnchor.constraint(
                            equalTo: cell.leadingAnchor, constant: 4),
                        textField.trailingAnchor.constraint(
                            equalTo: cell.trailingAnchor, constant: -4),
                        textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                }

                textField.lineBreakMode = .byTruncatingTail
            }

            guard let textField = cellView?.textField else { return cellView }

            textField.stringValue = value

            // Let's set the alignment based on column type
            let type = parent.dbManager.columnTypes[identifier]?.uppercased() ?? ""
            if type.contains("INT") || type.contains("REAL") || type.contains("DOUBLE")
                || type.contains("FLOAT") || type.contains("DECIMAL")
                || type.contains("NUMERIC")
            {
                textField.alignment = .right
            } else {
                textField.alignment = .left
            }

            // Handle highlighting
            let hasPendingChange = parent.dbManager.pendingChanges[dbRow.id]?[identifier] != nil
            let isActiveEdit = parent.dbManager.activeEdits[dbRow.id]?[identifier] != nil

            if isActiveEdit {
                cellView?.layer?.backgroundColor =
                    NSColor.systemBlue.withAlphaComponent(0.15).cgColor
                cellView?.wantsLayer = true
            } else if hasPendingChange {
                cellView?.layer?.backgroundColor =
                    NSColor.systemYellow.withAlphaComponent(0.1).cgColor
                cellView?.wantsLayer = true
            } else {
                cellView?.wantsLayer = false
                cellView?.layer?.backgroundColor = nil
            }

            return cellView
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField,
                let cellView = textField.superview as? NSTableCellView,
                let tableView = cellView.superview?.superview as? NSTableView
            else { return }

            let row = tableView.row(for: textField)
            let column = tableView.column(for: textField)

            guard row != -1, column != -1 else { return }

            let colIdentifier = tableView.tableColumns[column].identifier.rawValue
            let dbRow = parent.dbManager.rows[row]
            let newValue = textField.stringValue

            parent.dbManager.updateActiveEdit(
                rowID: dbRow.id, column: colIdentifier, value: newValue)
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            // No longer need to start editing here, we track actual changes in updateActiveEdit
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField,
                let cellView = textField.superview as? NSTableCellView,
                let tableView = cellView.superview?.superview as? NSTableView
            else { return }

            let row = tableView.row(for: textField)
            let column = tableView.column(for: textField)

            guard row != -1, column != -1 else { return }

            let colIdentifier = tableView.tableColumns[column].identifier.rawValue
            let dbRow = parent.dbManager.rows[row]
            let newValue = textField.stringValue

            parent.dbManager.updateActiveEdit(
                rowID: dbRow.id, column: colIdentifier, value: newValue)
        }
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
