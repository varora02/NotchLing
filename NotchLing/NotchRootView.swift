import AppKit
import SwiftUI

@MainActor
enum NotchLingPanelLayout {
    static let width: CGFloat = 360

    static func height(for model: AppModel) -> CGFloat {
        switch model.panelRoute {
        case .moveToApplications: return 306
        case .onboarding: return onboardingHeight(for: model)
        case .connections: return connectionsHeight(for: model)
        case .agents: break
        }

        if model.isQuickNoteEditor {
            return 218
        }

        let visibleCount = min(model.sessions.count, 3)
        let hasOverflow = model.sessions.count > 3
        let contentHeight =
            94 +
            CGFloat(visibleCount) * 44 +
            (hasOverflow ? 31 : 0) +
            (model.alertCount > 0 ? 28 : 0)

        return max(142, min(contentHeight, 290))
    }

    private static func onboardingHeight(for model: AppModel) -> CGFloat {
        let flow = model.onboarding
        switch flow.step {
        case .welcome: return 306
        case .companion: return 304
        case .connect:
            // A failed tool adds a line under its row.
            let errors = model.connections.errors.filter { flow.connectedThisRun.contains($0.key) == false }.count
            return 400 + CGFloat(errors) * 30
        case .codexTrust: return 300
        case .done: return 336 + (flow.loginNote == nil ? 0 : 14)
        }
    }

    private static func connectionsHeight(for model: AppModel) -> CGFloat {
        let connections = model.connections
        let errors = connections.errors.count
        let hint = connections.connected.contains(.codex)
            && model.lastEventAt[.codex] == nil ? 1 : 0
        return 322 + CGFloat(errors + hint) * 30
    }

    static func size(for model: AppModel) -> CGSize {
        CGSize(width: width, height: height(for: model))
    }
}

@MainActor
enum ProviderIconCache {
    private static var images: [AgentProvider: NSImage?] = [:]

    static func image(for provider: AgentProvider) -> NSImage? {
        if let cached = images[provider] { return cached }
        let image = provider.applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        images[provider] = .some(image)
        return image
    }
}

extension AgentProvider {
    @MainActor var iconImage: NSImage? { ProviderIconCache.image(for: self) }
}

private struct ProviderStateBadge: View {
    let state: AgentDisplayState

    var body: some View {
        ZStack {
            switch state {
            case .resting:
                ZStack {
                    Text("z")
                        .font(.system(size: 6.5, weight: .bold, design: .rounded))
                        .offset(x: -1.5, y: 1.5)
                    Text("z")
                        .font(.system(size: 5, weight: .bold, design: .rounded))
                        .offset(x: 2.5, y: -2)
                }
                .foregroundStyle(.white.opacity(0.66))

            case .working:
                Circle()
                    .fill(Color(red: 0.34, green: 0.72, blue: 1.00))
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle().stroke(Color.black.opacity(0.45), lineWidth: 1)
                    )

            case .needsYou:
                EmptyView()
            }
        }
        .frame(width: 13, height: 13)
    }
}

private struct ProviderLogoView: View {
    let provider: AgentProvider
    let state: AgentDisplayState
    var size: CGFloat = 28

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = provider.iconImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: provider.symbolName)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(provider.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(provider.accent.opacity(0.12))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .opacity(state == .resting ? 0.55 : 1)

            ProviderStateBadge(state: state)
                .offset(x: 3, y: 3)
        }
        .frame(width: size + 4, height: size + 4)
        .help("\(provider.displayName) · \(state.label)")
    }
}


struct PetBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NotchlingView(
            mode: model.petMode,
            notchling: model.notchling,
            attentionPulse: model.attentionPulse,
            animationNonce: model.devAnimationNonce,
            peekBlinking: model.isPeekBlinking,
            peekWaving: model.isPeekWaving
        )
        .frame(width: 50, height: 30)
        .frame(width: 52, height: 32)
        .help("Click for agents · Right-click for Quick Note")
        .accessibilityLabel("NotchLing")
        .accessibilityValue(model.alertCount == 0 ? model.headline : "\(model.headline). \(model.alertCount) alerts in panel")
    }
}

struct AgentPanelRootView: View {
    @ObservedObject var model: AppModel
    // Observed here too: the panel's height follows the onboarding step and the connection errors.
    @ObservedObject private var onboarding: OnboardingFlow
    @ObservedObject private var connections: ConnectionsStore

    init(model: AppModel) {
        self.model = model
        onboarding = model.onboarding
        connections = model.connections
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(.ultraThinMaterial)

            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(
                    Color(
                        red: 0.085,
                        green: 0.098,
                        blue: 0.092
                    )
                    .opacity(0.72)
                )

            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(Color.white.opacity(0.085), lineWidth: 0.8)

            Group {
                switch model.panelRoute {
                case .moveToApplications:
                    MoveToApplicationsPage(model: model)
                case .onboarding:
                    OnboardingView(model: model, flow: model.onboarding, connections: model.connections)
                case .connections:
                    ConnectionsView(model: model, connections: model.connections)
                case .agents:
                    if model.isQuickNoteEditor {
                        QuickNoteView(model: model)
                    } else {
                        AgentPanelView(model: model)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .frame(
            width: NotchLingPanelLayout.width,
            height: NotchLingPanelLayout.height(for: model)
        )
    }
}

private struct QuickNoteView: View {
    @ObservedObject var model: AppModel
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick note")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("\(model.notchling.name) only remembers one thing at a time.")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.40))
                }

                Spacer()

                Button("Cancel") {
                    model.cancelQuickNote()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
            }

            TextEditor(text: $model.quickNoteDraft)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.92))
                .scrollContentBackground(.hidden)
                .padding(7)
                .background(
                    Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .focused($noteFocused)

            HStack {
                Text("\(model.quickNoteDraft.count) characters")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.24))

                Spacer()

                Button("Save") {
                    model.saveQuickNote()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                noteFocused = true
            }
        }
    }
}

struct AgentPanelView: View {
    @ObservedObject var model: AppModel

    private var sortedSessions: [AgentSession] {
        model.sessions.sorted { lhs, rhs in
            let lp = priority(lhs.state)
            let rp = priority(rhs.state)
            if lp != rp { return lp < rp }
            return lhs.lastUpdated > rhs.lastUpdated
        }
    }

    private var visibleSessions: [AgentSession] {
        Array(sortedSessions.prefix(3))
    }

    private var hiddenSessions: [AgentSession] {
        Array(sortedSessions.dropFirst(visibleSessions.count))
    }

    var body: some View {
        VStack(spacing: 11) {
            header

            if !visibleSessions.isEmpty {
                VStack(spacing: 7) {
                    ForEach(visibleSessions) { session in
                        sessionRow(session)
                    }

                    if !hiddenSessions.isEmpty {
                        overflowRow
                    }

                    if model.alertCount > 0 {
                        HStack {
                            Spacer()
                            Button("Clear alerts") {
                                model.clearAlerts()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                            .help("Dismiss all alerts; working sessions stay visible")
                        }
                        .frame(height: 20)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                headlineView
                    .font(.system(size: 15, weight: .semibold, design: .rounded))

                HStack(spacing: 7) {
                    Text(subheadline)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.43))
                        .lineLimit(1)

                    if !connectedProviderList.isEmpty {
                        ForEach(connectedProviderList) { provider in
                            ProviderLogoView(
                                provider: provider,
                                state: model.displayState(for: provider),
                                size: 17
                            )
                        }
                    }
                }
            }

            Spacer()

            Button {
                model.openQuickNote()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Quick Note")
            .accessibilityLabel("Quick Note")

            Menu {
                Button("Clear alerts") { model.clearAlerts() }
                    .disabled(model.alertCount == 0)

                Divider()

                Button("Connections…") { model.openConnections() }

                Button("Appearance…") { model.openAppearance() }

                Divider()

                Button("Quit NotchLing") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 18, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    @ViewBuilder
    private var headlineView: some View {
        let headline = model.headline

        if headline.hasPrefix(model.notchling.name) {
            let suffix = String(headline.dropFirst(model.notchling.name.count))
            let name = Text(model.notchling.name).foregroundStyle(model.notchling.accent)
            let rest = Text(suffix).foregroundStyle(.white)
            Text("\(name)\(rest)")
        } else {
            Text(headline)
                .foregroundStyle(.white)
        }
    }

    private var connectedProviderList: [AgentProvider] {
        AgentProvider.allCases.filter { model.connectedProviders.contains($0) }
    }

    private var subheadline: String {
        if model.alertCount > 0 && model.petMode != .needsYou {
            return model.alertCount == 1 ? "1 alert to review." : "\(model.alertCount) alerts to review."
        }

        switch model.petMode {
        case .resting:
            return "Quiet means clear."
        case .working:
            return "Watching the work."
        case .needsYou:
            return "An agent needs you."
        case .hidePeek:
            return "Just checking in."
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let displayState = model.displayState(for: session.state)

        return HStack(spacing: 8) {
            Button {
                model.returnTo(session)
            } label: {
                HStack(spacing: 10) {
                    ProviderLogoView(
                        provider: session.provider,
                        state: displayState,
                        size: 24
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.provider.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.91))
                            .lineLimit(1)

                        Text(
                            cappedStatusMessage(
                                session.message.isEmpty
                                    ? defaultMessage(for: displayState)
                                    : session.message
                            )
                        )
                        .font(.system(size: 9.8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.44))
                        .lineLimit(1)
                    }

                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Return to \(session.provider.displayName)")

            if AppModel.isAlert(session.state) {
                Button {
                    model.acknowledge(session.id)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.70))
                .background(Color.white.opacity(0.07), in: Circle())
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Color.white.opacity(0.033),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
    }

    private var overflowRow: some View {
        let providers = Set(hiddenSessions.map(\.provider))
        let label: String

        if providers.count == 1, let provider = providers.first {
            label = "+\(hiddenSessions.count) more \(provider.displayName) chats"
        } else {
            label = "+\(hiddenSessions.count) more sessions"
        }

        return HStack(spacing: 7) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))

            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
        .background(
            Color.white.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private func priority(_ state: AgentRunState) -> Int {
        switch state {
        case .error: return 0
        case .needsAttention: return 1
        case .completed: return 2
        case .working: return 3
        case .idle: return 4
        }
    }

    private func cappedStatusMessage(_ message: String) -> String {
        let limit = 44
        guard message.count > limit else { return message }
        return String(message.prefix(limit - 1)) + "…"
    }

    private func defaultMessage(for state: AgentDisplayState) -> String {
        switch state {
        case .resting:
            return "Sleeping"
        case .working:
            return "Working"
        case .needsYou:
            return "Needs you"
        }
    }
}


struct DeveloperControlsView: View {
    @ObservedObject var model: AppModel

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Developer Controls", systemImage: "hammer.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))

                Spacer()

                Text(model.petMode.label.uppercased())
                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.38))
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(NotchlingAnimation.allCases) { animation in
                    devButton(animation.label, symbol: animation.symbol) {
                        model.preview(animation)
                    }
                }

            }

            HStack(spacing: 7) {
                scenarioButton("Mixed Agents", symbol: "square.stack.3d.up.fill") {
                    model.demoMixedAgents()
                }

                scenarioButton("Antigravity ×5", symbol: "5.circle.fill") {
                    model.demoAntigravityFive()
                }
            }

            HStack(spacing: 7) {
                scenarioButton("Alert in 10s", symbol: "timer") {
                    model.scheduleAttentionTest()
                }

                scenarioButton("Replay onboarding", symbol: "arrow.counterclockwise") {
                    model.replayOnboarding()
                }
            }

            Text("These controls only inject local demo state. They do not call any agent provider.")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.31))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(
            Color.white.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    private func scenarioButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.72))
        .background(
            Color.white.opacity(0.040),
            in: RoundedRectangle(cornerRadius: 9)
        )
    }

    private func devButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.80))
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }
}
