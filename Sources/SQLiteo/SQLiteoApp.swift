import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
struct SQLiteoApp: App {
    @Environment(\.openWindow) private var openWindow

    init() {
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Database...") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [
                        UTType("org.sqlite.sqlite"),
                        UTType.database,
                        UTType.data,
                    ].compactMap { $0 }

                    panel.allowedContentTypes += [
                        UTType(filenameExtension: "sqlite"),
                        UTType(filenameExtension: "db"),
                        UTType(filenameExtension: "sqlite3"),
                    ].compactMap { $0 }

                    panel.nameFieldStringValue = "NewDatabase.sqlite"

                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            Task {
                                if !FileManager.default.fileExists(atPath: url.path) {
                                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
                                }
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Open SQLite File...") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.allowedContentTypes = [
                        UTType("org.sqlite.sqlite"),
                        UTType.database,
                        UTType.data,
                    ].compactMap { $0 }

                    panel.allowedContentTypes += [
                        UTType(filenameExtension: "sqlite"),
                        UTType(filenameExtension: "db"),
                        UTType(filenameExtension: "sqlite3"),
                    ].compactMap { $0 }

                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                RefreshCommand()
            }

            CommandGroup(replacing: .appInfo) {
                Button("About SQLiteo") {
                    let aboutWindow = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                        styleMask: [.titled, .closable],
                        backing: .buffered,
                        defer: false
                    )
                    aboutWindow.title = "About SQLiteo"
                    aboutWindow.contentView = NSHostingView(rootView: AboutView())
                    aboutWindow.center()
                    aboutWindow.makeKeyAndOrderFront(nil)
                }
            }

            CommandGroup(replacing: .help) {
                Button("SQLiteo Help") {
                    if let url = URL(string: "https://github.com/adamghill/sqliteo") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

private struct RefreshCommand: View {
    @FocusedValue(\.databaseManager) var dbManager

    var body: some View {
        Button("Refresh Database") {
            if let manager = dbManager {
                Task {
                    await manager.refreshDatabase()
                }
            }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(dbManager?.fileURL == nil)
    }
}
