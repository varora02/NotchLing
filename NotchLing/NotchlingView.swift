import AppKit
import SwiftUI

private struct NotchlingAttentionBurst: View {
    let scale: CGFloat
    let opacity: Double

    private var signalColor: Color {
        Color(red: 1.00, green: 0.72, blue: 0.12)
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(signalColor)
                .frame(width: 2.8, height: 8.5)
                .rotationEffect(.degrees(18))
                .offset(x: -4, y: 1)

            Capsule()
                .fill(signalColor)
                .frame(width: 2.8, height: 8.5)
                .rotationEffect(.degrees(45))
                .offset(x: 1.5, y: 4)

            Capsule()
                .fill(signalColor)
                .frame(width: 2.5, height: 6.5)
                .rotationEffect(.degrees(72))
                .offset(x: 5.5, y: 8)
        }
        .scaleEffect(scale, anchor: .bottomLeading)
        .opacity(opacity)
    }
}

private struct EllieSleepZs: View {
    var body: some View {
        ZStack {
            sleepZ(size: 6).offset(x: 13, y: -5)
            sleepZ(size: 5).offset(x: 17, y: -9)
            sleepZ(size: 4).offset(x: 20, y: -12)
        }
        .frame(width: 52, height: 30)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func sleepZ(size: CGFloat) -> some View {
        Text("z")
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.85), radius: 0.7)
    }
}

struct NotchlingView: View {
    let mode: PetMode
    let notchling: NotchlingDefinition
    let attentionPulse: Int
    let animationNonce: Int
    let peekBlinking: Bool
    let peekWaving: Bool

    @State private var workingOffset: CGFloat = 0
    @State private var workingScale: CGFloat = 1
    @State private var burstScale: CGFloat = 1
    @State private var burstOpacity: Double = 0
    @State private var attentionFrame: NotchlingKeyframe = .attentionDown
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        // Time only drives the resting breath, so the timeline sleeps otherwise.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: mode != .resting)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let restingBreath = mode == .resting ? sin(t * 1.25) * 0.22 : 0

            ZStack {
                if let sprite = NotchlingSpriteLoader.image(
                    for: notchling,
                    frame: .resolve(mode: mode, attention: attentionFrame, blinking: peekBlinking, waving: peekWaving)
                ) {
                    petSprite(sprite, restingBreath: restingBreath)
                } else {
                    fallback
                }

                if mode == .needsYou {
                    NotchlingAttentionBurst(
                        scale: burstScale,
                        opacity: burstOpacity
                    )
                    .offset(x: 20)
                }
            }
            .frame(width: 52, height: 30)
        }
        .onAppear {
            enter(mode)
        }
        .onChange(of: mode) { _, newMode in
            enter(newMode)
        }
        .onChange(of: attentionPulse) { _, _ in
            if mode == .needsYou {
                runNeedsYouAttention()
            }
        }
        .onChange(of: animationNonce) { _, _ in
            enter(mode)
        }
        .onDisappear {
            animationTask?.cancel()
        }
    }

    @ViewBuilder
    private func petSprite(
        _ sprite: NSImage,
        restingBreath: Double
    ) -> some View {
        Group {
            Image(nsImage: sprite)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .overlay {
                    if mode == .resting && notchling.id == "elephant" {
                        EllieSleepZs()
                    }
                }
        }
        .scaleEffect(
            x: workingScale,
            y: workingScale + (mode == .resting ? restingBreath * 0.006 : 0),
            anchor: .bottom
        )
        .offset(
            y: workingOffset + (mode == .resting ? restingBreath : 0)
        )
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(notchling.accent)
            .frame(width: 28, height: 20)
            .overlay(
                Text(String(notchling.name.prefix(1)))
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(.black.opacity(0.75))
            )
    }
    private func enter(_ newMode: PetMode) {
        animationTask?.cancel()

        workingOffset = 0
        workingScale = 1
        burstScale = 1
        burstOpacity = 0
        attentionFrame = .attentionDown

        switch newMode {
        case .resting:
            workingOffset = 1.8
            workingScale = 0.97
            withAnimation(.spring(response: 0.38, dampingFraction: 0.74)) {
                workingOffset = 0
                workingScale = 1
            }

        case .working:
            workingOffset = 2.5
            workingScale = 0.96
            withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) {
                workingOffset = 0
                workingScale = 1
            }

        case .needsYou:
            runNeedsYouAttention()

        case .hidePeek:
            break
        }
    }

    private func runNeedsYouAttention() {
        animationTask?.cancel()

        // Each pack supplies the gesture (Rex's arms, Ellie's trunk).
        // The approved Needs You timing keeps the body still for every pet.
        workingOffset = 0
        workingScale = 1
        attentionFrame = .attentionDown
        burstScale = 1
        burstOpacity = 1

        animationTask = Task { @MainActor in
            // Establish the neutral attention pose first.
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }

            // Raise the attention gesture.
            attentionFrame = .attentionUp
            withAnimation(.easeOut(duration: 0.16)) {
                burstScale = 1.12
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }

            // Two quick wave beats, shared by every species.
            for _ in 0..<2 {
                attentionFrame = .attentionOut
                withAnimation(.easeInOut(duration: 0.12)) {
                    burstOpacity = 1
                    burstScale = 1.14
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }

                attentionFrame = .attentionIn
                withAnimation(.easeInOut(duration: 0.12)) {
                    burstOpacity = 0.42
                    burstScale = 0.98
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
            }

            // Hold the raised gesture after the short wave.
            attentionFrame = .attentionUp
            burstOpacity = 1
            burstScale = 1.08
            try? await Task.sleep(nanoseconds: 240_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: 0.22)) {
                burstScale = 1
                burstOpacity = 0
            }
        }
    }

}
