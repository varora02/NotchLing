import Foundation
import os

final class LocalEventMonitor {
    static let directoryURL = NotchLingSupport.directoryURL
    static let inboxURL = directoryURL.appendingPathComponent("inbox.jsonl")
    /// Events before launch are skipped anyway, so a larger inbox is just
    /// accumulated history and is truncated on start.
    static let maxInboxBytes: UInt64 = 1_048_576

    private static let log = Logger(subsystem: "app.notchling.NotchLing", category: "events")

    private let inboxURL: URL
    private var timer: Timer?
    private var offset: UInt64 = 0
    private var fileID: UInt64?
    private var partialLine = Data()

    init(inboxURL: URL = LocalEventMonitor.inboxURL) {
        self.inboxURL = inboxURL
    }

    func start(handler: @escaping (AgentEvent) -> Void) {
        prepareInbox()
        if let handle = try? FileHandle(forWritingTo: inboxURL) {
            try? handle.truncate(atOffset: 0)
            try? handle.close()
        }
        offset = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: inboxURL.path) {
            fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
        partialLine = Data()

        // Common modes keep polling alive while a menu is tracking.
        let timer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
            self?.poll(handler: handler)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func prepareInbox() {
        let directory = inboxURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if !FileManager.default.fileExists(atPath: inboxURL.path) {
            FileManager.default.createFile(atPath: inboxURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inboxURL.path)
    }

    func poll(handler: @escaping (AgentEvent) -> Void) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: inboxURL.path),
              let handle = try? FileHandle(forReadingFrom: inboxURL) else { return }
        defer { try? handle.close() }

        // A truncated or replaced inbox restarts from the top; a stale offset
        // would otherwise skip every later event.
        var size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let id = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if size > Self.maxInboxBytes {
            if let writer = try? FileHandle(forWritingTo: inboxURL) {
                try? writer.truncate(atOffset: 0)
                try? writer.close()
                size = 0
            }
        }
        if size < offset || (fileID != nil && id != fileID) {
            offset = 0
            partialLine = Data()
        }
        fileID = id

        do {
            try handle.seek(toOffset: offset)
            guard let newData = try handle.readToEnd(), !newData.isEmpty else { return }
            offset += UInt64(newData.count)
            var data = partialLine
            data.append(newData)

            let parts = data.split(separator: Data([0x0A]), omittingEmptySubsequences: false)
            partialLine = parts.last.map { Data($0) } ?? Data()
            let decoder = JSONDecoder()

            for raw in parts.dropLast() where !raw.isEmpty {
                do {
                    handler(try decoder.decode(AgentEvent.self, from: Data(raw)))
                } catch {
                    // Log the length and decoding error, never the raw event payload.
                    Self.log.error("Dropped undecodable inbox line (\(raw.count) bytes): \(error.localizedDescription, privacy: .private)")
                }
            }
        } catch {
            Self.log.error("Inbox read failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
