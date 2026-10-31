import AppKit
import Darwin
import Foundation

/// Filesystem-independent launch policy. The running path still decides whether
/// to prompt when Gatekeeper supplies an original path inside Applications.
struct ApplicationLocation {
    let bundleURL: URL
    let originalURL: URL?
    let home: URL
    var isDebug = false

    var isTranslocated: Bool { bundleURL.path.contains("/AppTranslocation/") }
    var sourceURL: URL { originalURL ?? bundleURL }
    var preferencePath: String { sourceURL.standardizedFileURL.path }

    func shouldPrompt(skippedPaths: Set<String>) -> Bool {
        let paths = [bundleURL.path, sourceURL.path]
        guard !isDebug, !paths.contains(where: {
            $0.contains("/Build/Products/") || $0.split(separator: "/").contains(".build")
        }), !skippedPaths.contains(preferencePath) else { return false }
        let path = bundleURL.standardizedFileURL.path
        let userApplications = home.appendingPathComponent("Applications").standardizedFileURL.path
        return isTranslocated || !(path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/"))
    }

    func destination(systemApplicationsWritable: Bool) -> URL {
        let folder = systemApplicationsWritable
            ? URL(fileURLWithPath: "/Applications") : home.appendingPathComponent("Applications")
        return folder.appendingPathComponent("NotchLing.app")
    }

    /// Only the distribution's volume layout is eligible for best-effort eject.
    func diskImageVolume(containsApp: (URL) -> Bool) -> URL? {
        let components = sourceURL.standardizedFileURL.pathComponents
        guard components.count >= 4, components[1] == "Volumes" else { return nil }
        let volume = URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2])
        return containsApp(volume.appendingPathComponent("NotchLing.app")) ? volume : nil
    }

    static func current() -> ApplicationLocation {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return ApplicationLocation(
            bundleURL: bundle,
            originalURL: originalPath(for: bundle),
            home: FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath(),
            isDebug: isDebug
        )
    }

    /// This optional Security SPI is absent from the public SDK. Keep its lookup
    /// dynamic and fall back to copying the readable translocated bundle.
    private static func originalPath(for bundle: URL) -> URL? {
        guard bundle.path.contains("/AppTranslocation/"),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let function = unsafeBitCast(symbol, to: OriginalPath.self)
        return function(bundle as CFURL, nil)?.takeRetainedValue() as URL?
    }
}

/// Copy completely before recycling an existing installation. The recycler is
/// injectable so contract checks never use the user's Trash or Applications.
struct ApplicationInstaller {
    var recycle: (URL) throws -> URL = { url in
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let trashed else { throw CocoaError(.fileWriteUnknown) }
        return trashed as URL
    }

    func install(source: URL, destination: URL) throws {
        let files = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent(".NotchLing-\(UUID().uuidString).app")
        // Never hard-delete an app, including an incomplete staged copy.
        defer {
            if files.fileExists(atPath: staged.path) { _ = try? recycle(staged) }
        }
        try files.copyItem(at: source, to: staged)
        try clearCopiedQuarantine(at: staged)
        var previous: URL?
        if files.fileExists(atPath: destination.path) { previous = try recycle(destination) }
        do {
            try files.moveItem(at: staged, to: destination)
        } catch {
            if let previous { try? files.moveItem(at: previous, to: destination) }
            throw error
        }
    }

    /// The user has already launched and approved moving this app. Copied
    /// quarantine metadata can otherwise translocate the installed copy again.
    /// Never follow bundle symlinks or change the downloaded source.
    private func clearCopiedQuarantine(at root: URL) throws {
        var enumerationError: Error?
        guard let contents = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        func clear(_ url: URL) throws {
            if removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        try clear(root)
        for case let url as URL in contents { try clear(url) }
        if let enumerationError { throw enumerationError }
    }
}

/// The new copy leaves exactly the source process alive until openApplication
/// reports success. The source then terminates itself; no shell helper is needed.
struct ApplicationMoveHandoff {
    let sourcePID: Int32
    let sourcePath: String
    let volume: URL?

    var arguments: [String] {
        ["--notchling-move-source", String(sourcePID), sourcePath, volume?.path ?? ""]
    }

    init(sourcePID: Int32, sourcePath: String, volume: URL?) {
        self.sourcePID = sourcePID
        self.sourcePath = sourcePath
        self.volume = volume
    }

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--notchling-move-source"),
              arguments.count > index + 3, let pid = Int32(arguments[index + 1]), pid > 0 else { return nil }
        sourcePID = pid
        sourcePath = arguments[index + 2]
        let path = arguments[index + 3]
        let url = URL(fileURLWithPath: path)
        volume = url.pathComponents.count == 3 && url.pathComponents[1] == "Volumes" ? url : nil
    }

    func matches(pid: Int32, bundlePath: String?) -> Bool {
        pid == sourcePID && bundlePath == sourcePath
    }

    @MainActor
    func ejectAfterTermination(of source: NSRunningApplication?) {
        guard let volume,
              FileManager.default.fileExists(atPath: volume.appendingPathComponent("NotchLing.app").path) else { return }
        Task { @MainActor in
            // A busy source (or another process using the DMG) must not block setup.
            for _ in 0..<100 {
                if source?.isTerminated != false { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard source?.isTerminated != false else { return }
            DispatchQueue.global(qos: .utility).async {
                try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            }
        }
    }
}
