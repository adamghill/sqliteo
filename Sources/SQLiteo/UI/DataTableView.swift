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

        if let highlightId = dbManager.highlightedRowID,
            highlightId != context.coordinator.lastHighlightedRowID
        {
            context.coordinator.lastHighlightedRowID = highlightId
            if let index = dbManager.rows.firstIndex(where: { $0.id == highlightId }) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                tableView.scrollRowToVisible(index)
            }
        } else if dbManager.highlightedRowID == nil {
            context.coordinator.lastHighlightedRowID = nil
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
        var lastHighlightedRowID: TableRowID? = nil

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

                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = 4
                stack.translatesAutoresizingMaskIntoConstraints = false

                let textField = NSTextField()
                textField.identifier = NSUserInterfaceItemIdentifier("TextField")
                textField.delegate = self
                textField.isEditable = true
                textField.isSelectable = true
                textField.drawsBackground = false
                textField.isBordered = false
                textField.focusRingType = .none

                let fkButton = NSButton()
                fkButton.identifier = NSUserInterfaceItemIdentifier("FKButton")
                fkButton.image = NSImage(
                    systemSymbolName: "key.fill", accessibilityDescription: "Foreign Key")
                fkButton.isBordered = false
                fkButton.imagePosition = .imageOnly
                fkButton.target = self
                fkButton.action = #selector(fkButtonClicked(_:))
                fkButton.controlSize = .small
                fkButton.contentTintColor = .tertiaryLabelColor
                fkButton.isHidden = true

                stack.addArrangedSubview(textField)
                stack.addArrangedSubview(fkButton)

                cellView?.addSubview(stack)
                cellView?.textField = textField

                if let cell = cellView {
                    NSLayoutConstraint.activate([
                        stack.leadingAnchor.constraint(
                            equalTo: cell.leadingAnchor, constant: 4),
                        stack.trailingAnchor.constraint(
                            equalTo: cell.trailingAnchor, constant: -4),
                        stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                    fkButton.setContentCompressionResistancePriority(.required, for: .horizontal)
                    textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                }

                textField.lineBreakMode = .byTruncatingTail
            }

            guard let textField = cellView?.textField else { return cellView }

            if let stack = cellView?.subviews.first as? NSStackView,
                let fkButton = stack.arrangedSubviews.last as? NSButton
            {
                fkButton.isHidden = (parent.dbManager.foreignKeys[identifier] == nil)
            }

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

        @objc func fkButtonClicked(_ sender: NSButton) {
            guard let cellView = sender.superview?.superview as? NSTableCellView,
                let tableView = cellView.superview?.superview as? NSTableView
            else { return }

            let row = tableView.row(for: cellView)
            let column = tableView.column(for: cellView)
            guard row != -1, column != -1 else { return }

            let colIdentifier = tableView.tableColumns[column].identifier.rawValue
            let dbRow = parent.dbManager.rows[row]
            let value = dbRow.data[colIdentifier] ?? ""

            if let fk = parent.dbManager.foreignKeys[colIdentifier] {
                Task { @MainActor in
                    do {
                        let rows = try await parent.dbManager.fetchSurroundingRows(
                            for: fk, value: value)
                        let targetRow = rows.first(where: { $0.data[fk.destinationColumn] == value }
                        )
                        let targetRowID = targetRow?.id

                        let allCols = rows.first?.data.keys.sorted() ?? []

                        let popover = NSPopover()
                        let popoverView = FKPreviewPopover(
                            tableName: fk.destinationTable,
                            rows: rows,
                            columns: allCols,
                            targetRowID: targetRowID,
                            onNavigate: { [weak self] in
                                guard let self = self else { return }
                                popover.performClose(nil)
                                Task { @MainActor in
                                    await self.parent.dbManager.navigateAndHighlight(
                                        tableName: fk.destinationTable,
                                        column: fk.destinationColumn,
                                        value: value
                                    )
                                }
                            }
                        )
                        popover.contentViewController = NSHostingController(rootView: popoverView)
                        popover.behavior = .transient
                        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
                    } catch {
                        print("Error fetching FK rows: \(error)")
                    }
                }
            }
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
