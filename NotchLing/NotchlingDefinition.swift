import AppKit
import SwiftUI

enum NotchLingSupport {
    /// The one Application Support location for the inbox, integrations and
    /// user-supplied sprites.
    static let directoryURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchLing", isDirectory: true)
}

/// The five animations every notchling speaks. Agent status has only three
/// meanings; the two peeks are personality beats, never additional statuses.
enum NotchlingAnimation: String, CaseIterable, Identifiable {
    case rest, working, needsYou, peekWave, peekBlink

    var id: String { rawValue }
    var label: String {
        switch self {
        case .rest: return "Rest"
        case .working: return "Working"
        case .needsYou: return "Needs You"
        case .peekWave: return "Peek 1 · Wave"
        case .peekBlink: return "Peek 2 · Blink"
        }
    }
    var symbol: String {
        switch self {
        case .rest: return "moon.zzz.fill"
        case .working: return "gearshape.2.fill"
        case .needsYou: return "exclamationmark.bubble.fill"
        case .peekWave: return "hand.wave.fill"
        case .peekBlink: return "eye.circle.fill"
        }
    }
}

enum NotchlingKeyframe: String, CaseIterable {
    case resting, working, attentionDown, attentionUp, attentionOut, attentionIn
    case peekOpen, peekWave, peekBlink

    static func resolve(
        mode: PetMode,
        attention: Self,
        blinking: Bool,
        waving: Bool
    ) -> Self {
        switch mode {
        case .resting: return .resting
        case .working: return .working
        case .needsYou: return attention
        case .hidePeek: return waving ? .peekWave : (blinking ? .peekBlink : .peekOpen)
        }
    }
}

/// Species-specific art and identity. Timing, status and notch geometry are shared.
struct NotchlingDefinition: Decodable, Identifiable {
    let id: String
    let name: String
    let species: String
    let assetDirectory: String
    let accentRGB: [Double]
    let frames: [String: String]

    var accent: Color {
        Color(red: accentRGB[0], green: accentRGB[1], blue: accentRGB[2])
    }

    func filename(for frame: NotchlingKeyframe) -> String {
        frames[frame.rawValue]!
    }

    var isValid: Bool {
        func isComponent(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
        }
        return isComponent(id) && isComponent(assetDirectory) && !name.isEmpty
            && accentRGB.count == 3 && accentRGB.allSatisfy { (0...1).contains($0) }
            && NotchlingKeyframe.allCases.allSatisfy {
                guard let file = frames[$0.rawValue] else { return false }
                return isComponent(file) && file.hasSuffix(".png")
            }
    }
}

enum NotchlingCatalog {
    static let all: [NotchlingDefinition] = {
        guard let url = Bundle.main.url(forResource: "notchlings", withExtension: "json", subdirectory: "Assets"),
              let definitions = try? read(from: url) else {
            // A broken resource bundle still provides a usable, named fallback.
            NSLog("NotchLing: unable to load notchling catalog; using Rex fallback")
            return [fallback]
        }
        return definitions
    }()

    static func read(from url: URL) throws -> [NotchlingDefinition] {
        let definitions = try JSONDecoder().decode([NotchlingDefinition].self, from: Data(contentsOf: url))
        guard !definitions.isEmpty, definitions.allSatisfy(\.isValid),
              Set(definitions.map(\.id)).count == definitions.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return definitions
    }

    static func resolve(_ id: String?) -> NotchlingDefinition {
        all.first { $0.id == id } ?? all.first { $0.id == "rex" } ?? all[0]
    }

    private static let fallback = NotchlingDefinition(
        id: "rex", name: "Rex", species: "T-Rex", assetDirectory: "Rex",
        accentRGB: [0.67, 0.95, 0.48],
        frames: [
            "resting": "resting@2x.png", "working": "working@2x.png",
            "attentionDown": "needs2-down@2x.png", "attentionUp": "needs2-up@2x.png",
            "attentionOut": "needs2-wave-out@2x.png", "attentionIn": "needs2-wave-in@2x.png",
            "peekOpen": "peek-open@2x.png", "peekWave": "peek-wave@2x.png", "peekBlink": "peek-blink@2x.png"
        ]
    )
}

@MainActor
enum NotchlingSpriteLoader {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(for pet: NotchlingDefinition, frame: NotchlingKeyframe) -> NSImage? {
        let filename = pet.filename(for: frame)
        let path = "Assets/\(pet.assetDirectory)/\(filename)"
        return load(path)
    }

    private static func load(_ path: String) -> NSImage? {
        if let image = cache[path] { return image }
        if missing.contains(path) { return nil }

        let bundled = Bundle.main.resourceURL?.appendingPathComponent(path)
        let local = NotchLingSupport.directoryURL.appendingPathComponent(path)
        for url in [bundled, local].compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                cache[path] = image
                return image
            }
        }
        NSLog("NotchLing: missing sprite %@", path)
        missing.insert(path)
        return nil
    }
}
