import AppKit
import SwiftUI

@main
struct NotchLingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            NotchLingSettingsView(model: appDelegate.model)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Appearance…") { appDelegate.model.openAppearance() }
                    .keyboardShortcut(",")
            }
        }
    }
}

struct NotchLingSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Your Notchling") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(NotchlingCatalog.all) { pet in
                        Button {
                            model.selectedNotchlingID = pet.id
                        } label: {
                            VStack(spacing: 5) {
                                if let sprite = NotchlingSpriteLoader.image(for: pet, frame: .working) {
                                    Image(nsImage: sprite)
                                        .resizable()
                                        .interpolation(.high)
                                        .scaledToFit()
                                        .frame(width: 78, height: 48)
                                }
                                Text(pet.name).font(.system(size: 12, weight: .semibold))
                                Text(pet.species).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(pet.accent.opacity(model.selectedNotchlingID == pet.id ? 0.22 : 0.06), in: RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(model.selectedNotchlingID == pet.id ? pet.accent : .clear, lineWidth: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(pet.name), \(pet.species)")
                        .accessibilityAddTraits(model.selectedNotchlingID == pet.id ? .isSelected : [])
                    }
                }
            }

            Section {
                DisclosureGroup("Developer controls") {
                    DeveloperControlsView(model: model)
                        .environment(\.colorScheme, .dark)
                        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(minWidth: 390, minHeight: 300)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var notchController: NotchWindowController?
    private var appearanceWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.onOpenAppearance = { [weak self] in
            // Let the menu finish tracking before activating a normal window.
            DispatchQueue.main.async { self?.showAppearance() }
        }
        // Launching another installed or development copy replaces the old
        // companion instead of putting a second pet beside the same notch.
        let handoff = ApplicationMoveHandoff(arguments: ProcessInfo.processInfo.arguments)
        var moveSource: NSRunningApplication?
        if let bundleID = Bundle.main.bundleIdentifier {
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where other.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                if handoff?.matches(pid: other.processIdentifier, bundlePath: other.bundleURL?.path) == true {
                    moveSource = other
                } else {
                    other.terminate()
                }
            }
        }
        handoff?.ejectAfterTermination(of: moveSource)
        model.start()
        let controller = NotchWindowController(model: model)
        notchController = controller
        controller.show()

        // Let the pet settle beside the notch, then start first-run setup if it is needed.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.model.startLaunchFlow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func showAppearance() {
        if appearanceWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 390, height: 300),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.title = "NotchLing Appearance"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace]
            window.contentView = NSHostingView(rootView: NotchLingSettingsView(model: model))
            window.center()
            appearanceWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        appearanceWindow?.makeKeyAndOrderFront(nil)
    }
}
