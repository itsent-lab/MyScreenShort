import Foundation

final class LaunchAgentService {
    private let label = "io.github.itsent-lab.MyScreenShort"
    private let legacyLabels = ["local.MyScreenShortMac"]
    private let fileManager = FileManager.default

    var canRegisterCurrentApp: Bool {
        appBundleURL != nil
    }

    var isEnabled: Bool {
        guard let appBundleURL else {
            return false
        }
        return allLaunchAgentURLs.contains { url in
            guard let savedPlist = try? String(contentsOf: url, encoding: .utf8) else {
                return false
            }
            return savedPlist.contains(appBundleURL.path)
        }
    }

    func enable() throws {
        guard let appBundleURL else {
            throw LaunchAgentError.appBundleNotFound
        }

        try fileManager.createDirectory(
            at: launchAgentsDirectoryURL,
            withIntermediateDirectories: true
        )

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>\(appBundleURL.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """

        try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
        try removeLegacyLaunchAgents()
    }

    func disable() throws {
        for url in allLaunchAgentURLs where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private var launchAgentsDirectoryURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private var launchAgentURL: URL {
        launchAgentsDirectoryURL.appendingPathComponent("\(label).plist")
    }

    func migrateLegacyRegistrationIfNeeded() {
        let oldAppName = "MyScreenShort-Mac.app"
        let needsMigration = allLaunchAgentURLs.contains { url in
            guard let savedPlist = try? String(contentsOf: url, encoding: .utf8) else {
                return false
            }
            return savedPlist.contains(oldAppName)
        }

        guard needsMigration else {
            return
        }

        do {
            try enable()
            AppLogService.write("Migrated launch agent registration to MyScreenShort")
        } catch {
            AppLogService.write("Launch agent migration failed: \(error)")
        }
    }

    private var allLaunchAgentURLs: [URL] {
        [launchAgentURL] + legacyLabels.map {
            launchAgentsDirectoryURL.appendingPathComponent("\($0).plist")
        }
    }

    private func removeLegacyLaunchAgents() throws {
        for legacyLabel in legacyLabels {
            let url = launchAgentsDirectoryURL.appendingPathComponent("\(legacyLabel).plist")
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private var appBundleURL: URL? {
        var url = Bundle.main.bundleURL
        while url.path != "/" {
            if url.pathExtension == "app" {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

enum LaunchAgentError: Error {
    case appBundleNotFound
}
