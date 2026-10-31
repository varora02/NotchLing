import AppKit
import SwiftUI

private enum SetupColor {
    static let blue = Color(red: 0.34, green: 0.72, blue: 1.00)
    static let green = Color(red: 0.45, green: 0.86, blue: 0.52)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.12)
}

// MARK: - Shared pieces

private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(Color.white.opacity(configuration.isPressed ? 0.78 : 0.94), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 10.5 : 12, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.82))
            .padding(.horizontal, compact ? 10 : 0)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(height: compact ? 24 : 32)
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 0.9)
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color
    var spinning = false

    var body: some View {
        HStack(spacing: 5) {
            if spinning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 9, height: 9)
            }
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(color.opacity(0.14), in: Capsule())
    }
}

private struct PageDots: View {
    let pages: [OnboardingStep]
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 5) {
            ForEach(pages, id: \.self) { page in
                Circle()
                    .fill(Color.white.opacity(page == current ? 0.85 : 0.22))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The selected notchling waving, using its own peek-wave and peek-open art.
private struct WavingNotchling: View {
    let notchling: NotchlingDefinition

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.42)) { timeline in
            let waving = Int(timeline.date.timeIntervalSinceReferenceDate / 0.42) % 2 == 0
            ZStack {
                if let sprite = NotchlingSpriteLoader.image(for: notchling, frame: waving ? .peekWave : .peekOpen) {
                    Image(nsImage: sprite)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
            }
            .frame(width: 104, height: 64)
        }
        .accessibilityHidden(true)
    }
}

private struct ProviderIconTile: View {
    let provider: AgentProvider
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image = provider.iconImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Text(String(provider.connectionTitle.prefix(1)))
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(provider.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(provider.accent.opacity(0.14))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Move to Applications

struct MoveToApplicationsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            WavingNotchling(notchling: model.notchling)
            Text("Move NotchLing to Applications?")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 8)
            Text("NotchLing works best from your Applications folder, so it can open at login and stay up to date.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 10)
            if let error = model.moveError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SetupColor.amber)
                    .lineLimit(1)
                    .help(error)
                    .padding(.top, 8)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Not now") { model.skipMoveToApplications() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Move and relaunch") { Task { await model.moveToApplications() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(model.isMovingToApplications)
            if model.isMovingToApplications {
                StatusPill(text: "Moving…", color: SetupColor.blue, spinning: true)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow
    @ObservedObject var connections: ConnectionsStore

    var body: some View {
        VStack(spacing: 0) {
            switch flow.step {
            case .welcome: WelcomePage(model: model, flow: flow)
            case .companion: CompanionPage(model: model, flow: flow)
            case .connect: ConnectPage(model: model, flow: flow, connections: connections)
            case .codexTrust: CodexTrustPage(model: model, flow: flow, connections: connections)
            case .done: DonePage(model: model, flow: flow)
            }

            PageDots(pages: OnboardingStep.pages(connected: flow.connectedThisRun), current: flow.step)
                .padding(.top, 10)
        }
        .padding(.horizontal, 6)
        .animation(.easeInOut(duration: 0.18), value: flow.step)
    }
}

private struct WelcomePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            WavingNotchling(notchling: model.notchling)
            Text("Hi, I'm \(Text(model.notchling.name).foregroundStyle(model.notchling.accent))")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 8)
            Text("I live next to your notch and keep an eye on your AI coding agents. When one finishes or needs you, I'll let you know.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 10)
            Text("Setup takes about a minute.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .padding(.top, 8)
            Spacer(minLength: 12)
            Button("Get started") { flow.advance() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct CompanionPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            Text("Who's keeping you company?")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("You can switch anytime.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.43))
                .padding(.top, 3)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(NotchlingCatalog.all) { pet in
                    card(pet)
                }
            }
            .padding(.top, 18)

            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Back") { flow.back() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Continue") { flow.advance() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func card(_ pet: NotchlingDefinition) -> some View {
        let selected = model.selectedNotchlingID == pet.id
        return Button {
            model.selectedNotchlingID = pet.id
        } label: {
            VStack(spacing: 8) {
                if let sprite = NotchlingSpriteLoader.image(for: pet, frame: .resting) {
                    Image(nsImage: sprite)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 96, height: 59)
                } else {
                    Color.clear.frame(width: 96, height: 59)
                }
                Text(pet.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(pet.accent.opacity(selected ? 0.18 : 0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? pet.accent : Color.white.opacity(0.08), lineWidth: selected ? 1.6 : 0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pet.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ConnectPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow
    @ObservedObject var connections: ConnectionsStore

    private var pending: Set<AgentProvider> {
        connections.selection.subtracting(flow.connectedThisRun)
    }

    private var hasFailures: Bool {
        pending.contains { connections.errors[$0] != nil }
    }

    private var primaryTitle: String {
        if hasFailures { return "Retry" }
        let count = connections.selection.count
        if count == 0 { return "Continue" }
        return count == 1 ? "Connect 1 agent" : "Connect \(count) agents"
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Which agents should \(Text(model.notchling.name).foregroundStyle(model.notchling.accent)) watch?")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                ForEach(AgentProvider.connectionOrder) { provider in
                    ConnectionToggleRow(
                        provider: provider,
                        connections: connections,
                        lastEvent: model.lastEventAt[provider]
                    )
                }
            }
            .padding(.top, 14)

            Text("Adds a small hook to each tool's settings. No API keys, no extra permissions, and you can disconnect anytime.")
                .font(.system(size: 9.8, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .padding(.horizontal, 8)

            Spacer(minLength: 10)
            HStack(spacing: 8) {
                Button("Skip") { flow.advance() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(flow.isConnecting)
                Button {
                    if connections.selection.isEmpty {
                        flow.advance()
                    } else {
                        Task { await flow.connect(using: connections) }
                    }
                } label: {
                    if flow.isConnecting {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Text(primaryTitle)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(flow.isConnecting)
            }
        }
    }
}

private struct ConnectionToggleRow: View {
    let provider: AgentProvider
    @ObservedObject var connections: ConnectionsStore
    let lastEvent: Date?

    private var state: ConnectionState { connections.state(for: provider, lastEvent: lastEvent) }
    private var isInstalled: Bool { state != .notInstalled }

    var body: some View {
        HStack(spacing: 10) {
            ProviderIconTile(provider: provider)
                .opacity(isInstalled ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.connectionTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                if !isInstalled {
                    detail("Not installed")
                } else if let subtitle = provider.connectionSubtitle {
                    detail(subtitle)
                }
                if case .failed(let message) = state {
                    Text(message)
                        .font(.system(size: 9.8, weight: .medium))
                        .foregroundStyle(SetupColor.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(isInstalled ? 1 : 0.5)

            Spacer(minLength: 6)

            Toggle("", isOn: Binding(
                get: { isInstalled && connections.selection.contains(provider) },
                set: { connections.toggle(provider, on: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(SetupColor.blue)
            .labelsHidden()
            .disabled(!isInstalled || state == .connecting)
            .opacity(isInstalled ? 1 : 0.45)
            .accessibilityLabel("Connect \(provider.connectionTitle)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.033), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.44))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CodexTrustPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow
    @ObservedObject var connections: ConnectionsStore

    private func health(_ provider: AgentProvider) -> ConnectionHealth {
        .resolve(installedAt: connections.installedAt[provider], lastEvent: model.lastEventAt[provider])
    }

    private var codexIsLive: Bool {
        if case .live = health(.codex) { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("One more click for Codex")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Codex ignores new hooks until you trust them.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.43))
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open Codex → Settings → Hooks")
                step(2, "Trust the hooks, then send a message")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.033), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.top, 14)

            VStack(spacing: 6) {
                ForEach(AgentProvider.connectionOrder.filter { flow.connectedThisRun.contains($0) }) { provider in
                    statusRow(provider)
                }
            }
            .padding(.top, 10)

            Spacer(minLength: 10)
            HStack(spacing: 8) {
                if codexIsLive {
                    Button("Continue") { flow.advance() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Do it later") { flow.advance() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Open Codex") { openCodex() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        // Once Codex reports, hold the green state for a beat and move on.
        .task(id: codexIsLive) {
            guard codexIsLive else { return }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, flow.step == .codexTrust else { return }
            flow.advance()
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 9) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.10), in: Circle())
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
        }
    }

    private func statusRow(_ provider: AgentProvider) -> some View {
        HStack(spacing: 10) {
            ProviderIconTile(provider: provider, size: 24)
            Text(provider.connectionTitle)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 6)
            switch health(provider) {
            case .live:
                StatusPill(text: "Connected", color: SetupColor.green)
            case .waiting:
                if provider == .codex {
                    StatusPill(text: "Waiting for Codex", color: SetupColor.amber, spinning: true)
                } else {
                    StatusPill(text: "Waiting", color: SetupColor.amber)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.033), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func openCodex() {
        Task { @MainActor in
            let workspace = NSWorkspace.shared
            let url = workspace.urlForApplication(withBundleIdentifier: AgentProvider.codex.defaultBundleIdentifier)
                ?? URL(fileURLWithPath: AgentProvider.codex.defaultAppPath)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await workspace.openApplication(at: url, configuration: configuration)
        }
    }
}

private struct DonePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flow: OnboardingFlow

    private var bodyText: String {
        let ending = "When it finishes or needs approval, I'll wave from here. Click me to see every agent."
        guard let list = OnboardingCopy.agentList(flow.connectedThisRun) else {
            return "Connect a tool anytime from ••• → Connections. \(ending)"
        }
        return "Start a task in \(list). \(ending)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            WavingNotchling(notchling: model.notchling)
            Text("You're all set")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 8)
            Text(bodyText)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Open NotchLing at login")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { flow.opensAtLogin },
                        set: { flow.setOpensAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(SetupColor.blue)
                    .labelsHidden()
                    .accessibilityLabel("Open NotchLing at login")
                    .disabled(!LaunchAtLogin.isEligible)
                }
                if let note = flow.loginNote {
                    Text(note)
                        .font(.system(size: 9.8, weight: .medium))
                        .foregroundStyle(SetupColor.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.033), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.top, 14)

            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Show me an alert") { model.showOnboardingDemoAlert() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Done") { model.finishOnboarding() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Connections panel

struct ConnectionsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var connections: ConnectionsStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Connections")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Tools \(model.notchling.name) watches for you.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.43))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Relative times refresh without needing a new event.
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                VStack(spacing: 6) {
                    ForEach(AgentProvider.connectionOrder) { provider in
                        ConnectionManageRow(
                            provider: provider,
                            connections: connections,
                            lastEvent: model.lastEventAt[provider],
                            now: timeline.date
                        )
                    }
                }
            }
            .padding(.top, 12)

            Spacer(minLength: 10)
            Button("Done") { model.closeConnections() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 2)
    }
}

private struct ConnectionManageRow: View {
    let provider: AgentProvider
    @ObservedObject var connections: ConnectionsStore
    let lastEvent: Date?
    let now: Date

    private var state: ConnectionState { connections.state(for: provider, lastEvent: lastEvent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                ProviderIconTile(provider: provider, size: 28)
                    .opacity(state == .notInstalled ? 0.45 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.connectionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(statusLine)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.44))
                        .lineLimit(1)
                }
                .opacity(state == .notInstalled ? 0.5 : 1)

                Spacer(minLength: 6)
                trailing
            }

            if case .failed(let message) = state {
                note(message, color: SetupColor.amber)
            }
            if provider == .codex, case .connected(.waiting) = state {
                note("Trust the NotchLing hooks in Codex → Settings → Hooks, then send Codex a message.", color: SetupColor.amber)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.033), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var statusLine: String {
        switch state {
        case .notInstalled: return "Not installed"
        case .available, .failed: return "Not connected"
        case .connecting: return "Working…"
        case .connected(.waiting): return "Connected, no events yet"
        case .connected(.live(let date)): return "Last event \(OnboardingCopy.age(of: date, now: now))"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .notInstalled:
            EmptyView()
        case .connecting:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .available, .failed:
            Button("Connect") { Task { await connections.connect(provider) } }
                .buttonStyle(SecondaryButtonStyle(compact: true))
        case .connected:
            Button("Disconnect") { Task { await connections.disconnect(provider) } }
                .buttonStyle(SecondaryButtonStyle(compact: true))
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.8, weight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tip

struct ConnectionsTipView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Manage agents anytime")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
            Text("••• → Connections to add, remove, or re-check a tool.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: ConnectionsTipView.size.width, height: ConnectionsTipView.size.height, alignment: .leading)
        .background(Color(red: 0.085, green: 0.098, blue: 0.092).opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.8))
    }

    static let size = CGSize(width: 232, height: 52)
}
