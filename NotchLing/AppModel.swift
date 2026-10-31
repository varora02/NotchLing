import AppKit
import Foundation
import SwiftUI

enum AgentProvider: String, Codable, CaseIterable, Identifiable {
    case claudeCode, cursor, codex, antigravity
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    var symbolName: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .cursor: return "cursorarrow.rays"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    /// Where the provider's desktop app normally lives; used for icons and as
    /// the return target when a session carries no (or a missing) host hint.
    var defaultAppPath: String {
        switch self {
        case .claudeCode: return "/Applications/Claude.app"
        case .cursor: return "/Applications/Cursor.app"
        case .codex: return "/Applications/ChatGPT.app"
        case .antigravity: return "/Applications/Antigravity.app"
        }
    }

    var defaultBundleIdentifier: String {
        switch self {
        case .claudeCode: return "com.anthropic.claudefordesktop"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .codex: return "com.openai.codex"
        case .antigravity: return "com.google.antigravity"
        }
    }

    /// The provider's desktop app: the default path if present, else a lookup
    /// by bundle id (installed outside /Applications, e.g. ~/Applications).
    var applicationURL: URL? {
        if FileManager.default.fileExists(atPath: defaultAppPath) {
            return URL(fileURLWithPath: defaultAppPath)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: defaultBundleIdentifier)
    }

    var accent: Color {
        switch self {
        case .claudeCode: return Color(red: 0.93, green: 0.54, blue: 0.35)
        case .cursor: return Color(red: 0.54, green: 0.67, blue: 1.00)
        case .codex: return Color(red: 0.35, green: 0.88, blue: 0.67)
        case .antigravity: return Color(red: 0.76, green: 0.58, blue: 1.00)
        }
    }
}

enum AgentRunState: String, Codable, CaseIterable {
    case idle, working, needsAttention, completed, error
}

enum PetMode: String, CaseIterable {
    case resting, working, needsYou, hidePeek

    var label: String {
        switch self {
        case .resting: return "Resting"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .hidePeek: return "Hide + peek"
        }
    }
}

enum PeekAnimationVariant: Int, CaseIterable {
    case one = 1
    case two = 2
}



enum AgentDisplayState: String {
    case resting
    case working
    case needsYou

    var label: String {
        switch self {
        case .resting: return "Resting"
        case .working: return "Working"
        case .needsYou: return "Needs you"
        }
    }
}

struct AgentEvent: Codable {
    let provider: AgentProvider
    let sessionID: String
    let project: String
    let state: AgentRunState
    let message: String
    let timestamp: Double
    let cwd: String?
    let returnHint: String?
    /// Missing source is the original hook event format.
    var source: String? = nil

    var isHookEvent: Bool { source == nil || source == "hook" }
}

struct AgentSession: Identifiable {
    let id: String
    var provider: AgentProvider
    var project: String
    var state: AgentRunState
    var message: String
    var lastUpdated: Date
    var cwd: String? = nil
    var returnHint: String? = nil
}

/// What the expanded notch panel is showing.
enum PanelRoute {
    case agents, moveToApplications, onboarding, connections

    var isSetup: Bool { self == .moveToApplications || self == .onboarding }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var isExpanded = false {
        didSet {
            if isExpanded {
                dismissConnectionsTip()
            } else if panelRoute == .connections {
                panelRoute = .agents
            }
        }
    }
    @Published private(set) var panelRoute: PanelRoute = .agents
    /// Newest real hook event per provider, used to show Connected / Waiting.
    @Published private(set) var lastEventAt: [AgentProvider: Date] = [:]
    @Published private(set) var isConnectionsTipVisible = false
    @Published var attentionPulse = 0
    @Published var devPeekNonce = 0
    @Published var devPeekVariant: PeekAnimationVariant = .two
    @Published var devAnimationNonce = 0
    @Published var isPeekActive = false
    @Published var isPeekBlinking = false
    @Published var isPeekWaving = false
    @Published private(set) var isAttentionPresenting = false
    @Published var connectedProviders: Set<AgentProvider> = []
    @Published var isQuickNoteEditor = false
    @Published var quickNote = ""
    @Published var quickNoteDraft = ""
    var onOpenAppearance: (() -> Void)?
    @Published var selectedNotchlingID: String {
        didSet {
            preferences.set(selectedNotchlingID, forKey: "selectedNotchlingID")
        }
    }

    var notchling: NotchlingDefinition {
        NotchlingCatalog.resolve(selectedNotchlingID)
    }

    let connections: ConnectionsStore
    let onboarding = OnboardingFlow()
    @Published private(set) var isMovingToApplications = false
    @Published private(set) var moveError: String?
    private var moveLocation: ApplicationLocation?
    private static let skippedMovePathsKey = "skippedMoveBundlePaths"

    private let preferences: UserDefaults
    private var persistedEventAt: [AgentProvider: Date] = [:]
    private var tipTask: Task<Void, Never>?
    private let eventMonitor = LocalEventMonitor()
    private var scheduledAttentionTestTask: Task<Void, Never>?
    private var attentionPresentationTask: Task<Void, Never>?
    private var expiryTimer: Timer?
    /// Working sessions silent this long are assumed dead (crashed agent or a
    /// missed Stop hook) and stop holding the pet in Working.
    // Agents report state changes, not every tool call, so a long task can be silent for hours.
    static let staleWorkingInterval: TimeInterval = 3 * 60 * 60
    private static let expiryCheckInterval: TimeInterval = 60

    /// What the user dismissed for a session. Replays at or before `through`
    /// are ignored, and so is a later repeat of the same alert (for example
    /// Claude's idle_prompt, which echoes the Stop alert about a minute later)
    /// until the session goes working again.
    private struct Acknowledgement {
        let through: Double
        let state: AgentRunState
        let message: String
    }
    private var acknowledgements: [String: Acknowledgement] = [:]
    /// Timestamp of the last idle/SessionEnd per session, so a delayed older
    /// event cannot resurrect a session that already ended.
    private var endedThrough: [String: Double] = [:]

    init(preferences: UserDefaults = .standard, connections: ConnectionsStore? = nil) {
        self.preferences = preferences
        self.connections = connections ?? ConnectionsStore(preferences: preferences)
        selectedNotchlingID = NotchlingCatalog.resolve(preferences.string(forKey: "selectedNotchlingID")).id

        quickNote = preferences.string(
            forKey: "rexQuickNote"
        ) ?? ""
        quickNoteDraft = quickNote

        if let stored = preferences.object(forKey: Self.lastEventKey) as? [String: Double] {
            for (name, time) in stored {
                if let provider = AgentProvider(rawValue: name) {
                    lastEventAt[provider] = Date(timeIntervalSince1970: time)
                }
            }
            persistedEventAt = lastEventAt
        }
        self.connections.onDisconnect = { [weak self] provider in self?.clearVerification(for: provider) }
        self.connections.onChange = { [weak self] in self?.refreshConnectedProviders() }
    }

    // Legacy event times included notify events and cannot prove hooks are trusted.
    private static let lastEventKey = "lastHookEventAtByProvider"
    private static let onboardingStartedKey = "hasStartedOnboarding"
    private static let onboardingKey = "hasCompletedOnboarding"
    private static let tipKey = "hasSeenConnectionsTip"

    var petMode: PetMode {
        if isAttentionPresenting && alertCount > 0 { return .needsYou }
        if isPeekActive { return .hidePeek }
        if sessions.contains(where: { $0.state == .working }) { return .working }
        return .resting
    }

    var alertCount: Int {
        sessions.filter { Self.isAlert($0.state) }.count
    }

    static func isAlert(_ state: AgentRunState) -> Bool {
        [.needsAttention, .completed, .error].contains(state)
    }

    var headline: String {
        // The panel must not claim rest while alerts are waiting for review.
        if alertCount > 0 {
            return alertCount == 1 ? "Something needs you" : "\(alertCount) things need you"
        }
        switch petMode {
        case .resting: return "\(notchling.name) is resting"
        case .working:
            let count = sessions.filter { $0.state == .working }.count
            return count == 1 ? "\(notchling.name) is keeping watch" : "\(notchling.name) is watching \(count) agents"
        case .needsYou:
            return alertCount == 1 ? "Something needs you" : "\(alertCount) things need you"
        case .hidePeek:
            return "\(notchling.name) is peeking"
        }
    }

    func start() {
        refreshConnectedProviders()

        eventMonitor.start { [weak self] event in
            Task { @MainActor in self?.ingest(event) }
        }

        let timer = Timer(timeInterval: Self.expiryCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireStaleSessions() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    func stop() {
        eventMonitor.stop()
        expiryTimer?.invalidate()
        expiryTimer = nil
        scheduledAttentionTestTask?.cancel()
        scheduledAttentionTestTask = nil
        tipTask?.cancel()
        tipTask = nil
        attentionPresentationTask?.cancel()
        attentionPresentationTask = nil
    }

    func ingest(_ event: AgentEvent) {
        if event.isHookEvent && !event.sessionID.hasPrefix("demo-") { recordEvent(event) }

        if let acknowledged = acknowledgements[event.sessionID] {
            if event.timestamp <= acknowledged.through { return }
            if Self.isAlert(event.state),
               event.state == acknowledged.state,
               event.message == acknowledged.message {
                return
            }
        }

        // Hooks run as separate processes, so a delayed event can land after
        // a newer one. Stale events are dropped for every state: an older
        // idle must not end a session that has since reported again, and an
        // older working must not resurrect one that already ended.
        if let ended = endedThrough[event.sessionID], event.timestamp < ended { return }
        let index = sessions.firstIndex { $0.id == event.sessionID }
        if let index, event.timestamp < sessions[index].lastUpdated.timeIntervalSince1970 { return }

        let previous = index.map { sessions[$0] }
        let shouldPresentAttention = Self.isAlert(event.state) &&
            (previous == nil || previous?.state != event.state || previous?.message != event.message)

        if !event.sessionID.hasPrefix("demo-") {
            connectedProviders.insert(event.provider)
        }

        if event.state == .idle {
            sessions.removeAll { $0.id == event.sessionID }
            acknowledgements.removeValue(forKey: event.sessionID)
            endedThrough[event.sessionID] = event.timestamp
            if alertCount == 0 { finishAttentionPresentation() }
            return
        }

        endedThrough.removeValue(forKey: event.sessionID)
        if event.state == .working {
            acknowledgements.removeValue(forKey: event.sessionID)
        }

        if let index {
            // Mutate a copy and assign once: each field write would otherwise
            // publish a separate sessions change.
            var session = sessions[index]
            session.provider = event.provider
            session.project = event.project
            session.state = event.state
            session.message = event.message
            session.lastUpdated = Date(timeIntervalSince1970: event.timestamp)
            if let cwd = event.cwd, !cwd.isEmpty {
                session.cwd = cwd
            }
            if let returnHint = event.returnHint, !returnHint.isEmpty {
                session.returnHint = returnHint
            }
            sessions[index] = session
        } else {
            sessions.insert(
                AgentSession(
                    id: event.sessionID,
                    provider: event.provider,
                    project: event.project,
                    state: event.state,
                    message: event.message,
                    lastUpdated: Date(timeIntervalSince1970: event.timestamp),
                    cwd: event.cwd,
                    returnHint: event.returnHint
                ),
                at: 0
            )
        }
        if shouldPresentAttention {
            presentAttention()
        } else if alertCount == 0 {
            finishAttentionPresentation()
        }
    }

    /// Remembers when each provider last reported, before ingest deduplicates
    /// events: a replayed or stale event still proves the hook runs.
    private func recordEvent(_ event: AgentEvent) {
        let time = min(Date(timeIntervalSince1970: event.timestamp), Date())
        guard time > (lastEventAt[event.provider] ?? .distantPast) else { return }
        lastEventAt[event.provider] = time

        // Events can be frequent; only write when the stored value is stale.
        if time.timeIntervalSince(persistedEventAt[event.provider] ?? .distantPast) >= 30 {
            persistedEventAt[event.provider] = time
            preferences.set(
                Dictionary(uniqueKeysWithValues: persistedEventAt.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }),
                forKey: Self.lastEventKey
            )
        }
    }

    private func clearVerification(for provider: AgentProvider) {
        lastEventAt[provider] = nil
        persistedEventAt[provider] = nil
        preferences.set(
            Dictionary(uniqueKeysWithValues: persistedEventAt.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }),
            forKey: Self.lastEventKey
        )
    }

    /// Drops working sessions that went silent and forgets old bookkeeping
    /// for sessions that no longer exist. Alerts are never expired: they wait
    /// for the user.
    func expireStaleSessions(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.staleWorkingInterval)
        if sessions.contains(where: { $0.state == .working && $0.lastUpdated < cutoff }) {
            sessions.removeAll { $0.state == .working && $0.lastUpdated < cutoff }
            if alertCount == 0 { finishAttentionPresentation() }
        }

        let live = Set(sessions.map(\.id))
        let cutoffStamp = cutoff.timeIntervalSince1970
        acknowledgements = acknowledgements.filter { live.contains($0.key) || $0.value.through >= cutoffStamp }
        endedThrough = endedThrough.filter { live.contains($0.key) || $0.value >= cutoffStamp }
    }

    private func presentAttention() {
        attentionPresentationTask?.cancel()
        isAttentionPresenting = true
        attentionPulse += 1
        attentionPresentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_700_000_000)
            guard let self, !Task.isCancelled else { return }
            self.finishAttentionPresentation()
        }
    }

    func finishAttentionPresentation() {
        attentionPresentationTask?.cancel()
        attentionPresentationTask = nil
        isAttentionPresenting = false
    }

    func refreshConnectedProviders() {
        let detected = IntegrationCatalog.connectedProviders()
        let liveProviders = Set(
            sessions
                .filter { !$0.id.hasPrefix("demo-") }
                .map(\.provider)
        )
        connectedProviders = detected.union(liveProviders)
    }

    func toggleExpanded() {
        // Setup is not dismissed by the pet; clicking it brings the flow back.
        if panelRoute.isSetup {
            isExpanded = true
            return
        }
        refreshConnectedProviders()
        isQuickNoteEditor = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            isExpanded.toggle()
        }
    }

    func openQuickNote() {
        guard !panelRoute.isSetup else { return }
        panelRoute = .agents
        refreshConnectedProviders()
        // The draft survives an accidental dismissal; saveQuickNote and
        // cancelQuickNote are the only places that reset it.
        isQuickNoteEditor = true
        isExpanded = true
    }

    /// Closes the editor without touching the draft (outside click, app or
    /// Space change), so reopening restores what the user was typing.
    func dismissQuickNotePreservingDraft() {
        isQuickNoteEditor = false
        isExpanded = false
    }

    func saveQuickNote() {
        quickNote = quickNoteDraft
        preferences.set(quickNote, forKey: "rexQuickNote")
        isQuickNoteEditor = false
        isExpanded = false
    }

    func cancelQuickNote() {
        quickNoteDraft = quickNote
        isQuickNoteEditor = false
        isExpanded = false
    }

    func acknowledge(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }),
              Self.isAlert(session.state) else { return }
        recordAcknowledgement(session)
        sessions.removeAll { $0.id == id }
        if alertCount == 0 { finishAttentionPresentation() }
    }

    private func recordAcknowledgement(_ session: AgentSession) {
        acknowledgements[session.id] = Acknowledgement(
            through: session.lastUpdated.timeIntervalSince1970,
            state: session.state,
            message: session.message
        )
    }

    func clearAlerts() {
        for session in sessions where Self.isAlert(session.state) {
            recordAcknowledgement(session)
        }
        sessions.removeAll { Self.isAlert($0.state) }
        finishAttentionPresentation()
    }

    func displayState(for provider: AgentProvider) -> AgentDisplayState {
        let providerSessions = sessions.filter { $0.provider == provider }

        if providerSessions.contains(where: { Self.isAlert($0.state) }) {
            return .needsYou
        }

        if providerSessions.contains(where: { $0.state == .working }) {
            return .working
        }

        return .resting
    }

    func displayState(for runState: AgentRunState) -> AgentDisplayState {
        switch runState {
        case .working:
            return .working
        case .needsAttention, .completed, .error:
            return .needsYou
        case .idle:
            return .resting
        }
    }

    func triggerDevPeek(_ variant: PeekAnimationVariant = .two) {
        // Clear sessions for a standalone preview that returns to Resting.
        // Peek 2 (blink) is the default preview; Peek 1 is the wave variant.
        sessions.removeAll()
        finishAttentionPresentation()
        isPeekBlinking = false
        isPeekWaving = false
        isPeekActive = false
        devPeekVariant = variant
        devPeekNonce += 1
    }

    func beginPeek() {
        isPeekBlinking = false
        isPeekWaving = false
        isPeekActive = true
    }

    func setPeekBlinking(_ blinking: Bool) {
        isPeekBlinking = blinking
        if blinking { isPeekWaving = false }
    }

    func setPeekWaving(_ waving: Bool) {
        isPeekWaving = waving
        if waving { isPeekBlinking = false }
    }

    func finishPeek() {
        isPeekBlinking = false
        isPeekWaving = false
        isPeekActive = false
    }

    func returnTo(_ session: AgentSession) {
        isExpanded = false

        // Acknowledge only once the target really opened, so a failed return
        // leaves the alert in place.
        Task { @MainActor [weak self] in
            guard let self, await self.openReturnTarget(for: session) else { return }
            self.acknowledge(session.id)
        }
    }

    private func openReturnTarget(for session: AgentSession) async -> Bool {
        var hostHint = session.returnHint
        var documentPath: String?

        switch session.provider {
        case .codex:
            hostHint = nil
            let prefix = "codex:"
            let threadID = session.id.hasPrefix(prefix)
                ? String(session.id.dropFirst(prefix.count))
                : session.id

            if !threadID.isEmpty,
               let encoded = threadID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let deepLink = URL(string: "codex://threads/\(encoded)"),
               (try? await NSWorkspace.shared.open(deepLink, configuration: Self.activationConfiguration())) != nil {
                return true
            }

        case .antigravity:
            // Antigravity exposes a conversation ID to hooks but no documented
            // stable desktop deep-link. Bring the hosting app forward.
            break

        case .claudeCode:
            // Claude Code may be hosted by Terminal, iTerm, Warp, VS Code,
            // Cursor, or Claude Desktop. The hook records the host so returning
            // does not require Accessibility/Automation permission.
            break

        case .cursor:
            // Cursor has a stable workspace root in hook payloads. Bring Cursor
            // forward and reopen that workspace without touching agent state.
            documentPath = session.cwd
        }

        // Prefer the recorded host; if it is missing or fails to open, fall
        // back to the provider's own app.
        var targets: [URL] = []
        if let hostHint, FileManager.default.fileExists(atPath: hostHint) {
            targets.append(URL(fileURLWithPath: hostHint))
        }
        if let fallback = session.provider.applicationURL, !targets.contains(fallback) {
            targets.append(fallback)
        }

        for target in targets {
            if await activateApplication(at: target, opening: documentPath) { return true }
        }
        return false
    }

    private static func activationConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return configuration
    }

    private func activateApplication(at appURL: URL, opening documentPath: String?) async -> Bool {
        let configuration = Self.activationConfiguration()

        do {
            if let documentPath, !documentPath.isEmpty,
               FileManager.default.fileExists(atPath: documentPath) {
                try await NSWorkspace.shared.open(
                    [URL(fileURLWithPath: documentPath)],
                    withApplicationAt: appURL,
                    configuration: configuration
                )
            } else {
                try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            }
            return true
        } catch {
            return false
        }
    }

    func scheduleAttentionTest(delaySeconds: Double = 10) {
        scheduledAttentionTestTask?.cancel()

        // Begin from a lower-priority state so the delayed event exercises the
        // real Working -> Needs You aggregate transition.
        demo(.working)
        isQuickNoteEditor = false
        isExpanded = false

        scheduledAttentionTestTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, delaySeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)

            guard let self, !Task.isCancelled else { return }

            self.ingest(
                AgentEvent(
                    provider: .claudeCode,
                    sessionID: "demo-fullscreen-alert",
                    project: "Fullscreen alert test",
                    state: .needsAttention,
                    message: "Test approval needed",
                    timestamp: Date().timeIntervalSince1970,
                    cwd: nil,
                    returnHint: nil
                )
            )
            self.scheduledAttentionTestTask = nil
        }
    }

    func demoMixedAgents() {
        let now = Date()
        sessions = [
            AgentSession(
                id: "demo-codex-mixed",
                provider: .codex,
                project: "Codex",
                state: .needsAttention,
                message: "Approve shell command",
                lastUpdated: now
            ),
            AgentSession(
                id: "demo-antigravity-mixed",
                provider: .antigravity,
                project: "Antigravity",
                state: .completed,
                message: "Ready for review",
                lastUpdated: now.addingTimeInterval(-45)
            ),
            AgentSession(
                id: "demo-claude-mixed",
                provider: .claudeCode,
                project: "Claude",
                state: .working,
                message: "Claude is working",
                lastUpdated: now.addingTimeInterval(-92)
            )
        ]
        presentAttention()
        devAnimationNonce += 1
    }

    func demoAntigravityFive() {
        let now = Date()
        sessions = [
            AgentSession(
                id: "demo-ag-1",
                provider: .antigravity,
                project: "Antigravity",
                state: .needsAttention,
                message: "Antigravity needs you",
                lastUpdated: now
            ),
            AgentSession(
                id: "demo-ag-2",
                provider: .antigravity,
                project: "Antigravity",
                state: .completed,
                message: "Ready for review",
                lastUpdated: now.addingTimeInterval(-25)
            ),
            AgentSession(
                id: "demo-ag-3",
                provider: .antigravity,
                project: "Antigravity",
                state: .working,
                message: "Antigravity is working",
                lastUpdated: now.addingTimeInterval(-58)
            ),
            AgentSession(
                id: "demo-ag-4",
                provider: .antigravity,
                project: "Antigravity",
                state: .working,
                message: "Background work is still running",
                lastUpdated: now.addingTimeInterval(-83)
            ),
            AgentSession(
                id: "demo-ag-5",
                provider: .antigravity,
                project: "Antigravity",
                state: .needsAttention,
                message: "A tool needs review",
                lastUpdated: now.addingTimeInterval(-116)
            )
        ]
        presentAttention()
        devAnimationNonce += 1
    }

    // MARK: - Onboarding and connections

    var hasCompletedOnboarding: Bool {
        preferences.object(forKey: Self.onboardingKey) as? Bool ?? false
    }

    /// Resume unfinished setup; skip it for upgrades with a connected tool
    /// only when setup has never started.
    static func needsOnboarding(completed: Bool, started: Bool = false, connected: Set<AgentProvider>) -> Bool {
        !completed && (started || connected.isEmpty)
    }

    func startLaunchFlow(location: ApplicationLocation = .current()) {
        let skipped = Set(preferences.object(forKey: Self.skippedMovePathsKey) as? [String] ?? [])
        guard location.shouldPrompt(skippedPaths: skipped) else {
            startOnboardingIfNeeded()
            return
        }
        moveLocation = location
        moveError = nil
        dismissConnectionsTip()
        isQuickNoteEditor = false
        panelRoute = .moveToApplications
        isExpanded = true
    }

    func skipMoveToApplications() {
        guard panelRoute == .moveToApplications, !isMovingToApplications, let moveLocation else { return }
        var skipped = Set(preferences.object(forKey: Self.skippedMovePathsKey) as? [String] ?? [])
        skipped.insert(moveLocation.preferencePath)
        preferences.set(skipped.sorted(), forKey: Self.skippedMovePathsKey)
        panelRoute = .agents
        isExpanded = false
        startOnboardingIfNeeded()
    }

    func moveToApplications() async {
        guard panelRoute == .moveToApplications, !isMovingToApplications, let location = moveLocation else { return }
        isMovingToApplications = true
        moveError = nil
        defer { isMovingToApplications = false }
        let files = FileManager.default
        let destination = location.destination(systemApplicationsWritable: files.isWritableFile(atPath: "/Applications"))
        do {
            try await Task.detached(priority: .userInitiated) {
                try ApplicationInstaller().install(source: location.sourceURL, destination: destination)
            }.value
            let handoff = ApplicationMoveHandoff(
                sourcePID: ProcessInfo.processInfo.processIdentifier,
                sourcePath: Bundle.main.bundleURL.path,
                volume: location.diskImageVolume { files.fileExists(atPath: $0.path) }
            )
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = handoff.arguments
            _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
            NSApp.terminate(nil)
        } catch {
            moveError = error.localizedDescription.components(separatedBy: .newlines).joined(separator: " ")
        }
    }

    func startOnboardingIfNeeded() {
        guard !hasCompletedOnboarding else { return }
        let connected = IntegrationCatalog.connectedProviders(home: connections.home)
        let started = preferences.object(forKey: Self.onboardingStartedKey) as? Bool ?? false
        guard Self.needsOnboarding(completed: false, started: started, connected: connected) else {
            preferences.set(true, forKey: Self.onboardingKey)
            return
        }
        beginOnboarding(isReplay: false, resuming: started)
    }

    func replayOnboarding() {
        guard panelRoute != .moveToApplications else { return }
        preferences.set(false, forKey: Self.onboardingKey)
        preferences.set(false, forKey: Self.tipKey)
        beginOnboarding(isReplay: true)
    }

    private func beginOnboarding(isReplay: Bool, resuming: Bool = false) {
        if !isReplay { preferences.set(true, forKey: Self.onboardingStartedKey) }
        connections.refresh()
        connections.resetSelection()
        onboarding.begin(isReplay: isReplay, resuming: resuming, connected: connections.connected)
        dismissConnectionsTip()
        isQuickNoteEditor = false
        panelRoute = .onboarding
        isExpanded = true
    }

    /// Done, Escape and the demo alert all end setup the same way.
    func finishOnboarding(tipDelay: Double = 0.9) {
        guard panelRoute == .onboarding else { return }
        onboarding.dismiss()
        preferences.set(true, forKey: Self.onboardingKey)
        panelRoute = .agents
        isExpanded = false
        showConnectionsTipOnce(after: tipDelay)
    }

    /// Plays the real Needs You alert once, so the user sees what to expect.
    func showOnboardingDemoAlert() {
        let provider = AgentProvider.connectionOrder.first { connections.connected.contains($0) } ?? .claudeCode
        finishOnboarding(tipDelay: 3.6)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            self?.ingest(AgentEvent(
                provider: provider,
                sessionID: "demo-onboarding-alert",
                project: "Demo",
                state: .needsAttention,
                message: "Needs your approval",
                timestamp: Date().timeIntervalSince1970,
                cwd: nil,
                returnHint: nil
            ))
        }
    }

    func openConnections() {
        guard panelRoute != .moveToApplications else { return }
        if panelRoute == .onboarding { onboarding.dismiss() }
        connections.refresh()
        isQuickNoteEditor = false
        panelRoute = .connections
        isExpanded = true
    }

    func closeConnections() {
        guard panelRoute == .connections else { return }
        panelRoute = .agents
        isExpanded = false
    }

    private func showConnectionsTipOnce(after delay: Double) {
        guard !(preferences.object(forKey: Self.tipKey) as? Bool ?? false) else { return }
        tipTask?.cancel()
        tipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isExpanded else { return }
            self.preferences.set(true, forKey: Self.tipKey)
            self.isConnectionsTipVisible = true
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            self.isConnectionsTipVisible = false
        }
    }

    func dismissConnectionsTip() {
        tipTask?.cancel()
        tipTask = nil
        if isConnectionsTipVisible { isConnectionsTipVisible = false }
    }

    func openAppearance() {
        isExpanded = false
        onOpenAppearance?()
    }

    func preview(_ animation: NotchlingAnimation) {
        switch animation {
        case .rest: demo(.resting)
        case .working: demo(.working)
        case .needsYou: demo(.needsYou)
        case .peekWave: triggerDevPeek(.one)
        case .peekBlink: triggerDevPeek(.two)
        }
    }

    func demo(_ mode: PetMode) {
        finishPeek()
        finishAttentionPresentation()
        let now = Date()
        switch mode {
        case .resting:
            sessions = []
            devAnimationNonce += 1

        case .working:
            sessions = [
                AgentSession(id: "demo-claude", provider: .claudeCode, project: "Claude", state: .working, message: "Claude is working", lastUpdated: now),
                AgentSession(id: "demo-cursor", provider: .cursor, project: "Cursor", state: .working, message: "Cursor is working", lastUpdated: now.addingTimeInterval(-94))
            ]
            devAnimationNonce += 1

        case .needsYou:
            sessions = [
                AgentSession(id: "demo-claude", provider: .claudeCode, project: "Claude", state: .needsAttention, message: "Claude needs permission", lastUpdated: now),
                AgentSession(id: "demo-codex", provider: .codex, project: "Codex", state: .working, message: "Codex is working", lastUpdated: now.addingTimeInterval(-211))
            ]
            presentAttention()
            devAnimationNonce += 1

        case .hidePeek:
            triggerDevPeek()
        }
    }
}
