import SwiftUI

@main
struct SQLiteoApp: App {
    @State private var dbManager = DatabaseManager()
    @State private var queryStore = SQLQueryStore()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(dbManager)
                .environment(queryStore)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open SQLite File...") {
                    dbManager.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("About SQLiteo") {
                    NSApp.orderFrontStandardAboutPanel(
                        options: [
                            NSApplication.AboutPanelOptionKey.credits: NSAttributedString(
                                string: "A native SQLite browser for macOS."),
                            NSApplication.AboutPanelOptionKey.applicationName: "SQLiteo",
                        ]
                    )
                }
            }
        }
    }
}
