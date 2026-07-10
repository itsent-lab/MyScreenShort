import Foundation

enum AppLogService {
    static func write(_ message: String) {
        NSLog("[MyScreenShort] %@", message)
        write(message, to: URL(fileURLWithPath: "/tmp/MyScreenShort.log"))

        let fileManager = FileManager.default
        let directoryURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MyScreenShort", isDirectory: true)
        let logURL = directoryURL.appendingPathComponent("app.log")
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            write(message, to: logURL)
        } catch {
            return
        }
    }

    private static func write(_ message: String, to logURL: URL) {
        let line = "[\(Self.dateFormatter.string(from: Date()))] \(message)\n"

        do {
            if FileManager.default.fileExists(atPath: logURL.path),
               let fileHandle = try? FileHandle(forWritingTo: logURL) {
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: Data(line.utf8))
                try fileHandle.close()
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            return
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
