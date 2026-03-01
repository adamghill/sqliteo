import AppKit
import UniformTypeIdentifiers

@MainActor
struct FileActions {
    static func openFile(dbManager: DatabaseManager?) {
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
                if let dbManager, dbManager.fileURL == nil {
                    Task {
                        await dbManager.connect(to: url)
                    }
                } else {
                     NSWorkspace.shared.open(url)
                }
               
            }
        }
    }

    static func createNewFile(dbManager: DatabaseManager?) {
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
                        FileManager.default.createFile(
                            atPath: url.path, contents: nil, attributes: nil)
                    }
                    if let dbManager, dbManager.fileURL == nil {
                         await dbManager.connect(to: url)
                    } else {
                         NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
