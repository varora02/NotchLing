import AppKit
import Foundation
import ServiceManagement

// MARK: - Flow sequencing

/// The pages of the first-run flow, in order.
enum OnboardingStep: Int, CaseIterable {
    case welcome, companion, connect, codexTrust, done

    /// The page after this one. Connected Codex tools get a trust page
    /// because Codex skips new hooks until the user trusts them.
    func next(connected: Set<AgentProvider>) -> OnboardingStep? {
        switch self {
        case .welcome: return .companion
        case .companion: return .connect
        case .connect: return connected.contains(.codex) ? .codexTrust : .done
        case .codexTrust: return .done
        case .done: return nil
        }
    }

    var previous: OnboardingStep? {
        switch self {
        case .companion: return .welcome
        case .connect: return .companion
        case .welcome, .codexTrust, .done: return nil
        }
    }

    /// The pages the user will see, for the page dots.
    static func pages(connected: Set<AgentProvider>) -> [OnboardingStep] {
        var pages: [OnboardingStep] = [.welcome, .companion, .connect]
        if connected.contains(.codex) { pages.append(.codexTrust) }
        pages.append(.done)
        return pages
    }
}

/// Whether a connected provider has really reported yet.
enum ConnectionHealth: Equatable {
    case waiting
    case live(lastEvent: Date)

    /// Only an event after the install proves the hook runs; with no
    /// install time (hooks installed outside the app) any hook event counts.
    static func resolve(installedAt: Date?, lastEvent: Date?) -> ConnectionHealth {
        guard let lastEvent else { return .waiting }
        if let installedAt, lastEvent <= installedAt { return .waiting }
        return .live(lastEvent: lastEvent)
    }
}

enum ConnectionState: Equatable {
    case notInstalled
    case available
    case connecting
    case failed(String)
    case connected(ConnectionHealth)
}

extension AgentProvider {
    var connectionTitle: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        }
    }

    /// Claude Desktop chat has no hooks, so only Code sessions are promised.
    var connectionSubtitle: String? {
        switch self {
        case .claudeCode: return "Terminal and the Claude desktop app's Code tab"
        case .codex: return "ChatGPT desktop app and Codex CLI"
        case .cursor, .antigravity: return nil
        }
    }

    /// Order the rows are listed in.
    static let connectionOrder: [AgentProvider] = [.claudeCode, .codex, .cursor, .antigravity]
}

enum OnboardingCopy {
    /// "Claude Code", "Claude Code or Codex", "Claude Code, Codex or Cursor".
    static func agentList(_ providers: Set<AgentProvider>) -> String? {
        let names = AgentProvider.connectionOrder.filter(providers.contains).map(\.connectionTitle)
        switch names.count {
        case 0: return nil
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
        }
    }

    /// "just now", "4 min ago", "2 hr ago", "3 days ago".
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) hr ago"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}

// MARK: - Bridge helper

/// Runs the bundled `notchling-bridge` helper that edits provider configs.
struct BridgeHelper {
    struct Output {
        let status: Int32
        let standardError: String
    }

    let url: URL

    /// Contents/Helpers/notchling-bridge, built into the app by the Xcode
    /// "Build notchling-bridge helper" phase.
    static var bundled: BridgeHelper? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notchling-bridge"),
            Bundle.main.url(forAuxiliaryExecutable: "notchling-bridge")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }.map(BridgeHelper.init)
    }

    /// Runs off the main thread. The child inherits this app's environment on
    /// purpose, so a NOTCHLING_HOME_OVERRIDE used to launch the app sandboxes the helper too.
    func run(_ arguments: [String]) async throws -> Output {
        let executable = url
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                let errorPipe = Pipe()
                process.standardError = errorPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    standardError: String(decoding: errorData, as: UTF8.self)
                ))
            }
        }
    }

    /// One short inline line out of the helper's stderr, for example
    /// "Couldn't read ~/.claude/settings.json. Fix or remove it, then retry."
    static func summarize(standardError: String, home: URL, provider: AgentProvider) -> String {
        let prefix = "NotchLing bridge error: "
        var line = standardError
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first ?? ""
        if line.hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)) }
        guard !line.isEmpty else { return "Couldn't connect \(provider.connectionTitle). Try again." }
        line = line.replacingOccurrences(of: home.path, with: "~")

        if line.contains("Left untouched") {
            if let range = line.range(of: #"[~/][^\s:()]*\.(json|toml)"#, options: .regularExpression) {
                return "Couldn't read \(line[range]). Fix or remove it, then retry."
            }
            if line.contains("config.toml") {
                return "Couldn't read ~/.codex/config.toml. Fix or remove it, then retry."
            }
        }
        let limit = 110
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

// MARK: - Connections

/// Which tools are installed and connected, and the install/uninstall actions
/// shared by the onboarding flow and the Connections panel.
@MainActor
final class ConnectionsStore: ObservableObject {
    typealias Runner = ([String]) async throws -> BridgeHelper.Output

    @Published private(set) var installed: Set<AgentProvider> = []
    @Published private(set) var connected: Set<AgentProvider> = []
    @Published private(set) var busy: Set<AgentProvider> = []
    @Published private(set) var errors: [AgentProvider: String] = [:]
    /// When each provider was connected, persisted across launches.
    @Published private(set) var installedAt: [AgentProvider: Date] = [:]
    /// The onboarding toggles.
    @Published var selection: Set<AgentProvider> = []

    let home: URL
    private let includeSystemLocations: Bool
    private let runner: Runner?
    private let preferences: UserDefaults
    private static let installedAtKey = "installedAtByProvider"
    var onDisconnect: ((AgentProvider) -> Void)?
    /// Called after the connected set may have changed.
    var onChange: (() -> Void)?

    init(
        home: URL = IntegrationCatalog.homeDirectory,
        includeSystemLocations: Bool = true,
        preferences: UserDefaults = .standard,
        runner: Runner? = BridgeHelper.bundled.map { helper in { try await helper.run($0) } }
    ) {
        self.home = home
        self.includeSystemLocations = includeSystemLocations
        self.runner = runner
        self.preferences = preferences
        if let stored = preferences.object(forKey: Self.installedAtKey) as? [String: Double] {
            for (name, time) in stored {
                if let provider = AgentProvider(rawValue: name) {
                    installedAt[provider] = Date(timeIntervalSince1970: time)
                }
            }
        }
        refresh()
    }

    func refresh() {
        connected = IntegrationCatalog.connectedProviders(home: home)
        installed = Set(AgentProvider.allCases.filter {
            IntegrationCatalog.isInstalled($0, home: home, includeSystemLocations: includeSystemLocations)
        }).union(connected)
        onChange?()
    }

    /// Detected tools start switched on.
    func resetSelection() {
        selection = installed
        errors = [:]
    }

    func toggle(_ provider: AgentProvider, on: Bool) {
        guard installed.contains(provider) else { return }
        if on { selection.insert(provider) } else { selection.remove(provider) }
    }

    func state(for provider: AgentProvider, lastEvent: Date?) -> ConnectionState {
        if busy.contains(provider) { return .connecting }
        if let message = errors[provider] { return .failed(message) }
        if connected.contains(provider) {
            return .connected(.resolve(installedAt: installedAt[provider], lastEvent: lastEvent))
        }
        return installed.contains(provider) ? .available : .notInstalled
    }

    /// Connects the selected tools one at a time (they share the bridge copy
    /// in Application Support) and returns the ones that succeeded.
    @discardableResult
    func connectSelected(excluding done: Set<AgentProvider> = []) async -> Set<AgentProvider> {
        var succeeded: Set<AgentProvider> = []
        for provider in AgentProvider.connectionOrder where selection.contains(provider) && !done.contains(provider) {
            if await connect(provider) { succeeded.insert(provider) }
        }
        return succeeded
    }

    @discardableResult
    func connect(_ provider: AgentProvider) async -> Bool {
        guard await run(["install", provider.bridgeName], for: provider) else { return false }
        installedAt[provider] = Date()
        persistInstallTimes()
        refresh()
        connected.insert(provider)
        installed.insert(provider)
        return true
    }

    func disconnect(_ provider: AgentProvider) async {
        guard await run(["uninstall", provider.bridgeName], for: provider) else { return }
        installedAt[provider] = nil
        persistInstallTimes()
        onDisconnect?(provider)
        refresh()
        connected.remove(provider)
    }

    private func persistInstallTimes() {
        preferences.set(
            Dictionary(uniqueKeysWithValues: installedAt.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }),
            forKey: Self.installedAtKey
        )
    }

    private func run(_ arguments: [String], for provider: AgentProvider) async -> Bool {
        guard let runner else {
            errors[provider] = "NotchLing's helper is missing from the app. Reinstall NotchLing."
            return false
        }
        busy.insert(provider)
        errors[provider] = nil
        defer { busy.remove(provider) }
        do {
            let output = try await runner(arguments)
            guard output.status == 0 else {
                errors[provider] = BridgeHelper.summarize(standardError: output.standardError, home: home, provider: provider)
                return false
            }
            return true
        } catch {
            errors[provider] = "Couldn't run NotchLing's helper. Reinstall NotchLing."
            return false
        }
    }
}

// MARK: - Open at login

@MainActor
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    /// Registering a copy that runs from a DMG, Downloads or a build folder
    /// would point the login item at a place that goes away.
    static var isEligible: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else if status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Onboarding state

@MainActor
final class OnboardingFlow: ObservableObject {
    @Published private(set) var step: OnboardingStep = .welcome
    /// Tools already connected or connected in this flow (drives the Codex page and copy).
    @Published private(set) var connectedThisRun: Set<AgentProvider> = []
    @Published private(set) var isConnecting = false
    @Published private(set) var opensAtLogin = false
    @Published private(set) var loginNote: String?

    private var isReplay = false
    private var generation = 0
    private var isDismissed = true

    func begin(isReplay: Bool = false, resuming: Bool = false, connected: Set<AgentProvider> = []) {
        generation += 1
        isDismissed = false
        self.isReplay = isReplay
        step = resuming ? (connected.contains(.codex) ? .codexTrust : .connect) : .welcome
        connectedThisRun = connected
        isConnecting = false
        loginNote = nil
    }

    func dismiss() {
        generation += 1
        isDismissed = true
        isConnecting = false
    }

    func advance() {
        guard !isDismissed, let next = step.next(connected: connectedThisRun) else { return }
        step = next
        if next == .done { syncLoginToggle() }
    }

    func back() {
        if let previous = step.previous { step = previous }
    }

    /// Connect page: install the toggled tools, then move on. Tools that fail
    /// stay on the page with their error so the user can retry or skip.
    func connect(using store: ConnectionsStore) async {
        guard !isDismissed, !isConnecting else { return }
        let generation = self.generation
        isConnecting = true
        let succeeded = await store.connectSelected(excluding: connectedThisRun)
        guard !isDismissed, generation == self.generation else { return }
        connectedThisRun.formUnion(succeeded)
        isConnecting = false
        if store.selection.subtracting(connectedThisRun).isEmpty { advance() }
    }

    /// Reflects the real login-item state; a fresh install defaults to on.
    private func syncLoginToggle() {
        guard LaunchAtLogin.isEligible else {
            opensAtLogin = false
            loginNote = "Move NotchLing to Applications to open it at login."
            return
        }
        if LaunchAtLogin.status == .notRegistered && !isReplay { applyLogin(true) }
        refreshLoginState()
    }

    func setOpensAtLogin(_ enabled: Bool) {
        guard !isDismissed else { return }
        guard LaunchAtLogin.isEligible else {
            opensAtLogin = false
            loginNote = "Move NotchLing to Applications to open it at login."
            return
        }
        applyLogin(enabled)
        refreshLoginState()
    }

    private func applyLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            loginNote = nil
        } catch {
            loginNote = "Couldn't change the login item. Try Login Items in System Settings."
        }
    }

    private func refreshLoginState() {
        opensAtLogin = LaunchAtLogin.isEnabled
        if LaunchAtLogin.status == .requiresApproval {
            loginNote = "Approve NotchLing in System Settings > Login Items."
        }
    }
}
