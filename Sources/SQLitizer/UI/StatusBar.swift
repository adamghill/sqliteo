import SwiftUI

struct StatusBar: View {
    @Environment(DatabaseManager.self) private var dbManager
    @Binding var selectedTab: Tab
    var showTabs: Bool = true

    var body: some View {
        HStack {
            if showTabs {
                Picker("View", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()

                Divider()
                    .padding(.vertical, 4)
            }

            Text("Rows: \(dbManager.totalRows)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if selectedTab == .data {
                Button {
                    Task {
                        await dbManager.previousPage()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(dbManager.offset == 0)

                Text("Page \(currentPage) of \(totalPages)")
                    .monospacedDigit()
                    .font(.caption)

                Button {
                    Task {
                        await dbManager.nextPage()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(dbManager.offset + dbManager.limit >= dbManager.totalRows)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(height: 28)
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

struct SchemaView: View {
    @Environment(DatabaseManager.self) private var dbManager

    var body: some View {
        ScrollView {
            Text(dbManager.tableDDL)
                .font(.system(.body, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct LoadingOverlay: View {
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ZStack {
                ProgressView("Loading...")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
            }
        }
    }
}
