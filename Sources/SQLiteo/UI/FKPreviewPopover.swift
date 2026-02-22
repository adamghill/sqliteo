import SwiftUI

struct FKPreviewPopover: View {
    let tableName: String
    let rows: [DBRow]
    let columns: [String]
    let targetRowID: TableRowID?
    let onNavigate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Header
            HStack {
                Text(tableName)
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Open Table") {
                    onNavigate()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(spacing: 8) {
                        ForEach(columns, id: \.self) { col in
                            Text(col)
                                .font(.headline)
                                .frame(width: 120, alignment: .leading)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))

                    Divider()

                    // Rows
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                let isTarget = row.id == targetRowID
                                HStack(spacing: 8) {
                                    ForEach(columns, id: \.self) { col in
                                        Text(row.data[col] ?? "")
                                            .frame(width: 120, alignment: .leading)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(isTarget ? Color.accentColor.opacity(0.2) : Color.clear)

                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300, maxWidth: 800, maxHeight: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}
