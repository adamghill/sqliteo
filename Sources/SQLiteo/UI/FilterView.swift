import SwiftUI

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
