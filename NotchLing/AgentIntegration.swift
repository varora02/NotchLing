import Foundation

extension AgentProvider {
    /// The name `notchling-bridge install|uninstall` expects.
    var bridgeName: String {
        self == .claudeCode ? "claude" : rawValue
    }
}

enum IntegrationCatalog {
    static func connectedProviders(home: URL = homeDirectory) -> Set<AgentProvider> {
        var connected: Set<AgentProvider> = []

        // Only NotchLing's own hooks count: another tool's notify (Codex
        // Computer Use) can forward to NotchLing without it being connected.
        if containsNotchLingHook(home.appendingPathComponent(".codex/hooks.json")) {
            connected.insert(.codex)
        }

        if containsNotchLingHook(home.appendingPathComponent(".claude/settings.json")) {
            connected.insert(.claudeCode)
        }

        if containsNotchLingHook(home.appendingPathComponent(".cursor/hooks.json")) ||
            containsNotchLingHook(home.appendingPathComponent(".cursor/settings.json")) {
            connected.insert(.cursor)
        }

        if containsNotchLingHook(home.appendingPathComponent(".gemini/config/hooks.json")) ||
            containsNotchLingHook(home.appendingPathComponent(".gemini/settings.json")) {
            connected.insert(.antigravity)
        }

        return connected
    }

    /// Whether the provider's app or CLI is on this Mac. Home-relative markers
    /// (config directories, ~/Applications) are read under `home`; with
    /// `includeSystemLocations` the machine-wide locations are also checked:
    /// /Applications, Homebrew and /usr/local CLIs, and a lookup by bundle id.
    static func isInstalled(
        _ provider: AgentProvider,
        home: URL = homeDirectory,
        includeSystemLocations: Bool = true
    ) -> Bool {
        let fileManager = FileManager.default
        let appName = URL(fileURLWithPath: provider.defaultAppPath).lastPathComponent

        var paths = [home.appendingPathComponent("Applications/\(appName)").path]
        switch provider {
        case .codex:
            paths.append(home.appendingPathComponent(".codex").path)
        case .claudeCode:
            paths.append(home.appendingPathComponent(".claude").path)
            paths.append(home.appendingPathComponent(".local/bin/claude").path)
        case .antigravity:
            paths.append(home.appendingPathComponent(".gemini/antigravity").path)
        case .cursor:
            paths.append(home.appendingPathComponent(".local/bin/cursor").path)
        }
        if paths.contains(where: fileManager.fileExists(atPath:)) { return true }

        guard includeSystemLocations else { return false }
        var systemPaths = [provider.defaultAppPath]
        switch provider {
        case .claudeCode: systemPaths += ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        case .cursor: systemPaths += ["/usr/local/bin/cursor", "/opt/homebrew/bin/cursor"]
        case .codex, .antigravity: break
        }
        return systemPaths.contains(where: fileManager.fileExists(atPath:)) || provider.applicationURL != nil
    }

    /// Honors the same override the bridge and hook scripts use, so tests never read the real home.
    static var homeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["NOTCHLING_HOME_OVERRIDE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // The Python-era names stay so older installs (including another tool's notify chain that still
    // forwards to codex-notify-wrapper.py) are recognized as NotchLing's rather than treated as foreign.
    private static let hookCommandMarkers = ["notchling-bridge", "-notchling-hook.py", "codex-notify-wrapper"]

    private static func isNotchLingCommand(_ value: String) -> Bool {
        hookCommandMarkers.contains { value.contains($0) }
    }

    /// True only if a hook entry's "command" is a NotchLing handler (not just any mention of the name).
    private static func containsNotchLingHook(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }

        func walk(_ node: Any) -> Bool {
            if let dictionary = node as? [String: Any] {
                for (key, value) in dictionary {
                    if key == "command", let command = value as? String {
                        if isNotchLingCommand(command) { return true }
                    } else if walk(value) {
                        return true
                    }
                }
            } else if let array = node as? [Any] {
                return array.contains(where: walk)
            }
            return false
        }

        return walk(object)
    }

}
