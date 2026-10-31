import Foundation

typealias JSON = [String: Any]

private let fm = FileManager.default
private let home: URL = {
    if let override = ProcessInfo.processInfo.environment["NOTCHLING_HOME_OVERRIDE"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return fm.homeDirectoryForCurrentUser
}()
private let support = home.appendingPathComponent("Library/Application Support/NotchLing", isDirectory: true)
private let integrations = support.appendingPathComponent("integrations", isDirectory: true)
private let inbox = support.appendingPathComponent("inbox.jsonl")
private let installedBridge = integrations.appendingPathComponent("notchling-bridge")

private func string(_ value: Any?) -> String {
    if let value = value as? String { return value }
    if value is NSNull { return "" }
    if let value { return String(describing: value) }
    return ""
}

/// Python-style truthiness, so `error: null` / `""` / `false` / `0` / `[]` count as "no error".
private func truthy(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    if let value = value as? String { return !value.isEmpty }
    if let value = value as? NSNumber { return value.doubleValue != 0 }
    if let value = value as? [Any] { return !value.isEmpty }
    if let value = value as? [String: Any] { return !value.isEmpty }
    return true
}

private func projectName(_ path: String, fallback: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? fallback : name
}

private func compact(_ value: Any?, limit: Int = 28) -> String {
    let raw = string(value).trimmingCharacters(in: .whitespacesAndNewlines)
    let text = raw.isEmpty ? "tool" : raw
    guard text.count > limit else { return text }
    return String(text.prefix(limit - 1)) + "…"
}

private func readStdinJSON() -> JSON {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? JSON else { return [:] }
    return dictionary
}

private func printJSON(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else {
        print("{}")
        return
    }
    print(text)
}

private func secureLocalData() {
    try? fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.createDirectory(at: integrations, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: integrations.path)
    if fm.fileExists(atPath: inbox.path) { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inbox.path) }
}

private func appendEvent(provider: String, sessionID: String, project: String, state: String, message: String, cwd: String, returnHint: String, source: String? = nil) {
    secureLocalData()
    var event: JSON = ["provider": provider, "sessionID": sessionID, "project": project, "state": state, "message": message, "timestamp": Date().timeIntervalSince1970, "cwd": cwd, "returnHint": returnHint]
    if let source { event["source"] = source }
    guard var bytes = try? JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes]) else { return }
    bytes.append(0x0A)
    // O_APPEND + a single write(2) of the whole line keeps concurrent hook processes from clobbering each other.
    let fd = open(inbox.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    bytes.withUnsafeBytes { buffer in _ = write(fd, buffer.baseAddress, buffer.count) }
}

private func claudeReturnHint() -> String {
    let env = ProcessInfo.processInfo.environment
    let entry = (env["CLAUDE_CODE_ENTRYPOINT"] ?? "").lowercased()
    if entry.contains("desktop") && fm.fileExists(atPath: "/Applications/Claude.app") { return "/Applications/Claude.app" }
    let candidates = ["Apple_Terminal": "/System/Applications/Utilities/Terminal.app", "iTerm.app": "/Applications/iTerm.app", "iTerm2": "/Applications/iTerm.app", "WarpTerminal": "/Applications/Warp.app", "Warp": "/Applications/Warp.app", "vscode": "/Applications/Visual Studio Code.app", "cursor": "/Applications/Cursor.app"]
    if let path = candidates[env["TERM_PROGRAM"] ?? ""], fm.fileExists(atPath: path) { return path }
    return fm.fileExists(atPath: "/Applications/Claude.app") ? "/Applications/Claude.app" : ""
}

private func runCodexHook() {
    let payload = readStdinJSON()
    let event = string(payload["hook_event_name"])
    let session = string(payload["session_id"]).isEmpty ? "unknown" : string(payload["session_id"])
    let cwd = string(payload["cwd"])
    let stateAndMessage: [String: (String, String)] = ["UserPromptSubmit": ("working", "Codex is working"), "PermissionRequest": ("needsAttention", "Approval requested"), "Stop": ("completed", "Ready for review"), "Interrupt": ("idle", "Turn interrupted"), "SessionEnd": ("idle", "Session ended")]
    guard var pair = stateAndMessage[event] else { return }
    if event == "PermissionRequest", !string(payload["tool_name"]).isEmpty { pair.1 = "Approve \(compact(payload["tool_name"]))" }
    appendEvent(provider: "codex", sessionID: "codex:\(session)", project: projectName(cwd, fallback: "Codex"), state: pair.0, message: pair.1, cwd: cwd, returnHint: "/Applications/ChatGPT.app")
}

private func runClaudeHook(_ event: String) {
    let payload = readStdinJSON()
    let env = ProcessInfo.processInfo.environment
    let session = string(payload["session_id"]).isEmpty ? (env["CLAUDE_CODE_SESSION_ID"] ?? "unknown") : string(payload["session_id"])
    let cwd = string(payload["cwd"]).isEmpty ? (env["CLAUDE_PROJECT_DIR"] ?? fm.currentDirectoryPath) : string(payload["cwd"])
    var state: String?
    var message = ""
    switch event {
    case "UserPromptSubmit": state = "working"; message = "Claude is working"
    case "PermissionRequest": state = "needsAttention"; message = "Approve \(compact(payload["tool_name"]))"
    case "Stop": state = "completed"; message = "Ready for review"
    case "SessionEnd": state = "idle"; message = "Session ended"
    default: break
    }
    if let state { appendEvent(provider: "claudeCode", sessionID: "claude:\(session)", project: projectName(cwd, fallback: "Claude"), state: state, message: message, cwd: cwd, returnHint: claudeReturnHint()) }
    print("{}")
}

private func cursorRoot(_ payload: JSON) -> String {
    if let roots = payload["workspace_roots"] as? [String], let first = roots.first { return first }
    return string(payload["cwd"])
}

private func runCursorHook(_ event: String) {
    let payload = readStdinJSON()
    let cwd = cursorRoot(payload)
    let sessionCandidates = ["session_id", "conversation_id", "generation_id"]
    let session = sessionCandidates.lazy.map { string(payload[$0]) }.first { !$0.isEmpty } ?? "unknown"
    var state: String?
    var message = ""
    switch event {
    case "beforeSubmitPrompt": state = "working"; message = "Cursor is working"
    case "stop":
        let status = string(payload["status"])
        if status == "error" { state = "needsAttention"; message = "Cursor stopped with an error" }
        else if status == "aborted" { state = "idle"; message = "Turn aborted" }
        else { state = "completed"; message = "Ready for review" }
    case "sessionEnd": state = "idle"; message = "Session ended"
    default: break
    }
    if let state { appendEvent(provider: "cursor", sessionID: "cursor:\(session)", project: projectName(cwd, fallback: "Cursor"), state: state, message: message, cwd: cwd, returnHint: "/Applications/Cursor.app") }
    if event == "beforeSubmitPrompt" { printJSON(["continue": true]) } else { print("{}") }
}

private func transcriptRequestsAttention(_ rawPath: String) -> Bool {
    guard !rawPath.isEmpty else { return false }
    let path = NSString(string: rawPath).expandingTildeInPath
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > 24_000 ? size - 24_000 : 0)
    let data = (try? handle.readToEnd()) ?? Data()
    let tail = String(decoding: data, as: UTF8.self).lowercased()
    return tail.contains("ask_permission") || tail.contains("ask_question")
}

private func runAntigravityHook(_ event: String) {
    let payload = readStdinJSON()
    let paths = payload["workspacePaths"] as? [String] ?? []
    let cwd = paths.first ?? ""
    let session = string(payload["conversationId"]).isEmpty ? "unknown" : string(payload["conversationId"])
    var state = "working"
    var message = "Antigravity is working"
    switch event {
    case "PostInvocation": if transcriptRequestsAttention(string(payload["transcriptPath"])) { state = "needsAttention"; message = "Antigravity needs you" }
    case "Stop":
        if truthy(payload["error"]) { state = "needsAttention"; message = "Antigravity stopped with an error" }
        else if (payload["fullyIdle"] as? Bool) == true { state = "completed"; message = "Ready for review" }
        else { state = "working"; message = "Background work is still running" }
    default: break
    }
    if ["PreInvocation", "PostInvocation", "Stop"].contains(event) { appendEvent(provider: "antigravity", sessionID: "antigravity:\(session)", project: projectName(cwd, fallback: "Antigravity"), state: state, message: message, cwd: cwd, returnHint: "/Applications/Antigravity.app") }
    if event == "Stop" { printJSON(["decision": "stop"]) } else { print("{}") }
}


// MARK: - Codex notify (turn-complete) forwarding

private let notifySidecar = integrations.appendingPathComponent("codex-notify-original.json")

/// `notchling-bridge notify <json>`: Codex appends the event payload as the last argument.
/// Records turn completion, then forwards to the user's original notify command (saved at install time).
private func runCodexNotify(_ raw: String) {
    if let data = raw.data(using: .utf8),
       let payload = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
       string(payload["type"]) == "agent-turn-complete" {
        let threadID = payload["thread-id"] == nil ? "unknown" : string(payload["thread-id"])
        let cwd = string(payload["cwd"])
        appendEvent(provider: "codex", sessionID: "codex:\(threadID)", project: projectName(cwd, fallback: "Codex"), state: "completed", message: "Ready for review", cwd: cwd, returnHint: "/Applications/ChatGPT.app", source: "notify")
    }
    guard let sidecarData = try? Data(contentsOf: notifySidecar),
          let sidecar = (try? JSONSerialization.jsonObject(with: sidecarData)) as? JSON,
          let original = sidecar["original"] as? [String], let executable = original.first else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(original.dropFirst()) + [raw]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    // Fire and forget, like Codex would; fall back to PATH lookup for bare command names.
    if !executable.contains("/") {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = original + [raw]
    }
    try? process.run()
}

// MARK: - Config editing helpers

private struct BridgeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// The Python-era names stay so older installs (including another tool's notify chain that still
// forwards to codex-notify-wrapper.py) are recognized as NotchLing's rather than treated as foreign.
private let ownMarkers = ["notchling-bridge", "-notchling-hook.py", "codex-notify-wrapper"]
private let codexDescription = "User-level Codex lifecycle hooks, including NotchLing."

private func isOurs(_ command: Any?) -> Bool {
    guard let command = command as? String else { return false }
    return ownMarkers.contains { command.contains($0) }
}

/// Removes NotchLing handlers from every event, so reinstalling also clears events an older version added.
/// Events that only held NotchLing handlers are dropped; anything that isn't a list is left alone.
private func removingOurs(from hooks: JSON) -> JSON {
    var result = hooks
    for (event, value) in hooks {
        guard let list = value as? [Any] else { continue }
        let kept = stripOurs(list).kept
        if kept.count == list.count { continue }
        if kept.isEmpty { result.removeValue(forKey: event) } else { result[event] = kept }
    }
    return result
}

/// Removes NotchLing handlers from hook entries (flat `{command}` or grouped `{hooks:[...]}`),
/// dropping groups that held only NotchLing handlers.
private func stripOurs(_ entries: [Any]) -> (kept: [Any], removed: Int) {
    var kept: [Any] = []
    var removed = 0
    for item in entries {
        guard var entry = item as? JSON else { kept.append(item); continue }
        if isOurs(entry["command"]) { removed += 1; continue }
        if let inner = entry["hooks"] as? [Any] {
            let remaining = inner.filter { !isOurs(($0 as? JSON)?["command"]) }
            if remaining.count != inner.count {
                removed += inner.count - remaining.count
                if remaining.isEmpty { continue }
                entry["hooks"] = remaining
            }
        }
        kept.append(entry)
    }
    return (kept, removed)
}

private func uninstallEventMap(_ hooks: inout JSON) -> Int {
    var total = 0
    for event in Array(hooks.keys) {
        guard let entries = hooks[event] as? [Any] else { continue }
        let result = stripOurs(entries)
        guard result.removed > 0 else { continue }
        total += result.removed
        if result.kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = result.kept }
    }
    return total
}

/// Missing file -> ([:], existed: false). Unreadable or unparsable file -> throws, so callers never overwrite user data.
private func loadJSON(_ url: URL) throws -> (data: JSON, existed: Bool) {
    guard fm.fileExists(atPath: url.path) else { return ([:], false) }
    let raw: Data
    do { raw = try Data(contentsOf: url) } catch { throw BridgeError("Cannot read \(url.path): \(error.localizedDescription). Left untouched.") }
    if raw.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) { return ([:], true) }
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: raw) } catch { throw BridgeError("\(url.path) is not valid JSON (\(error.localizedDescription)). Left untouched; fix or remove it and retry.") }
    guard let dict = object as? JSON else { throw BridgeError("\(url.path) does not contain a JSON object. Left untouched.") }
    return (dict, true)
}

private func backupOnce(_ url: URL) {
    let source = url.resolvingSymlinksInPath()
    guard fm.fileExists(atPath: source.path) else { return }
    let backup = URL(fileURLWithPath: url.path + ".notchling-backup")
    if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: source, to: backup) }
}

private func hasBackup(_ url: URL) -> Bool { fm.fileExists(atPath: url.path + ".notchling-backup") }

/// Temp file in the same directory + rename(2), so readers never see a half-written file. Follows symlinks (dotfile managers).
private func atomicWrite(_ data: Data, to url: URL) throws {
    let target = url.resolvingSymlinksInPath()
    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).notchling-\(getpid()).tmp")
    try data.write(to: temp)
    if let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path) }
    if rename(temp.path, target.path) != 0 {
        let code = errno
        try? fm.removeItem(at: temp)
        throw BridgeError("Could not write \(target.path): \(String(cString: strerror(code)))")
    }
}

private func saveJSON(_ object: JSON, to url: URL) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    try atomicWrite(data, to: url)
}

private func readText(_ url: URL) throws -> String? {
    guard fm.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { throw BridgeError("Cannot read \(url.path) as UTF-8. Left untouched.") }
    return text
}

private func hooksMap(_ data: JSON, _ url: URL) throws -> JSON {
    guard let value = data["hooks"], !(value is NSNull) else { return [:] }
    guard let hooks = value as? JSON else { throw BridgeError("\(url.path): \"hooks\" is not an object. Left untouched.") }
    return hooks
}

private func entryList(_ hooks: JSON, _ event: String, _ url: URL) throws -> [Any] {
    guard let value = hooks[event], !(value is NSNull) else { return [] }
    guard let list = value as? [Any] else { throw BridgeError("\(url.path): hooks.\(event) is not a list. Left untouched.") }
    return list
}

// MARK: - Minimal TOML scanning (top-level `notify` only)

private let quoteByte = UInt8(ascii: "\""), aposByte = UInt8(ascii: "'"), backslashByte = UInt8(ascii: "\\"), newlineByte = UInt8(ascii: "\n")

private func skipString(_ b: [UInt8], _ i: Int) throws -> Int {
    let quote = b[i]
    let n = b.count
    if i + 2 < n, b[i + 1] == quote, b[i + 2] == quote {
        var end = i + 3
        while end < n {
            if quote == quoteByte, b[end] == backslashByte { end += 2; continue }
            if end + 2 < n, b[end] == quote, b[end + 1] == quote, b[end + 2] == quote {
                end += 3
                while end < n, b[end] == quote { end += 1 }
                return end
            }
            end += 1
        }
        throw BridgeError("config.toml could not be parsed (unterminated multi-line string). Left untouched; fix it and retry.")
    }
    var end = i + 1
    while end < n, b[end] != newlineByte {
        if quote == quoteByte, b[end] == backslashByte { end += 2; continue }
        if b[end] == quote { return end + 1 }
        end += 1
    }
    throw BridgeError("config.toml could not be parsed (unterminated string). Left untouched; fix it and retry.")
}

private func skipValue(_ b: [UInt8], _ start: Int) throws -> Int {
    var i = start
    var depth = 0
    while i < b.count {
        let c = b[i]
        if c == UInt8(ascii: "#") { while i < b.count, b[i] != newlineByte { i += 1 }; continue }
        if c == quoteByte || c == aposByte { i = try skipString(b, i); continue }
        if c == UInt8(ascii: "[") || c == UInt8(ascii: "{") { depth += 1 }
        else if c == UInt8(ascii: "]") || c == UInt8(ascii: "}") { depth -= 1 }
        else if c == newlineByte, depth <= 0 { return i + 1 }
        i += 1
    }
    return b.count
}

/// Byte range and value source of `key = value` before the first [table] header.
private func findTopLevelKey(_ b: [UInt8], _ key: String) throws -> (start: Int, end: Int, source: String)? {
    let n = b.count
    var i = 0
    while i < n {
        let lineStart = i
        while i < n, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
        if i >= n { return nil }
        let c = b[i]
        if c == newlineByte || c == 0x0D { i += 1; continue }
        if c == UInt8(ascii: "#") { while i < n, b[i] != newlineByte { i += 1 }; continue }
        if c == UInt8(ascii: "[") { return nil }
        var name: String
        if c == quoteByte || c == aposByte {
            let keyEnd = try skipString(b, i)
            name = String(decoding: b[(i + 1)..<(keyEnd - 1)], as: UTF8.self)
            i = keyEnd
        } else {
            var keyEnd = i
            while keyEnd < n, b[keyEnd] != UInt8(ascii: "="), b[keyEnd] != newlineByte { keyEnd += 1 }
            name = String(decoding: b[i..<keyEnd], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            i = keyEnd
        }
        while i < n, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
        guard i < n, b[i] == UInt8(ascii: "=") else { throw BridgeError("config.toml could not be parsed (unexpected syntax). Left untouched; fix it and retry.") }
        let valueStart = i + 1
        let end = try skipValue(b, valueStart)
        if name == key { return (lineStart, end, String(decoding: b[valueStart..<end], as: UTF8.self)) }
        i = end
    }
    return nil
}

/// A TOML array of simple strings -> [String]; anything else -> nil.
private func parseStringArray(_ source: String) -> [String]? {
    let s = Array(source.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    guard s.first == UInt8(ascii: "[") else { return nil }
    var i = 1
    var out: [String] = []
    let escapes: [UInt8: UInt8] = [UInt8(ascii: "n"): 0x0A, UInt8(ascii: "t"): 0x09, UInt8(ascii: "r"): 0x0D, UInt8(ascii: "b"): 0x08, UInt8(ascii: "f"): 0x0C, quoteByte: quoteByte, backslashByte: backslashByte]
    while i < s.count {
        let c = s[i]
        if c == 0x20 || c == 0x09 || c == 0x0D || c == newlineByte || c == UInt8(ascii: ",") { i += 1 }
        else if c == UInt8(ascii: "#") { while i < s.count, s[i] != newlineByte { i += 1 } }
        else if c == UInt8(ascii: "]") { return out }
        else if c == quoteByte, !(i + 2 < s.count && s[i + 1] == quoteByte && s[i + 2] == quoteByte) {
            var j = i + 1
            var buffer: [UInt8] = []
            while j < s.count, s[j] != quoteByte {
                if s[j] == backslashByte, j + 1 < s.count {
                    let esc = s[j + 1]
                    if let mapped = escapes[esc] { buffer.append(mapped); j += 2 }
                    else if esc == UInt8(ascii: "u") || esc == UInt8(ascii: "U") {
                        let width = esc == UInt8(ascii: "u") ? 4 : 8
                        guard j + 2 + width <= s.count, let code = UInt32(String(decoding: s[(j + 2)..<(j + 2 + width)], as: UTF8.self), radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
                        buffer.append(contentsOf: Array(String(Character(scalar)).utf8)); j += 2 + width
                    } else { return nil }
                } else { buffer.append(s[j]); j += 1 }
            }
            if j >= s.count { return nil }
            out.append(String(decoding: buffer, as: UTF8.self)); i = j + 1
        }
        else if c == aposByte, !(i + 2 < s.count && s[i + 1] == aposByte && s[i + 2] == aposByte) {
            guard let close = s[(i + 1)...].firstIndex(of: aposByte) else { return nil }
            out.append(String(decoding: s[(i + 1)..<close], as: UTF8.self)); i = close + 1
        }
        else { return nil }
    }
    return nil
}

private func tomlArray(_ items: [String]) -> String {
    let encoded = items.map { item -> String in
        let data = (try? JSONSerialization.data(withJSONObject: [item], options: [.withoutEscapingSlashes])) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }
    return "[" + encoded.joined(separator: ", ") + "]"
}

private func writeNotifySidecar(original: [String]?, source: String?) throws {
    let payload: JSON = ["original": original as Any? ?? NSNull(), "originalSource": source as Any? ?? NSNull()]
    var data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    try atomicWrite(data, to: notifySidecar)
}

private enum NotifyOwnership { case ours, chained, foreign }

/// `.ours` when NotchLing is the notify command itself, `.chained` when another tool's
/// notify forwards to NotchLing (e.g. via --previous-notify), else `.foreign`.
private func notifyOwnership(_ value: [String]?, source: String) -> NotifyOwnership {
    if let value, let first = value.first {
        let pythonLaunched = URL(fileURLWithPath: first).lastPathComponent.hasPrefix("python") && value.count > 1 && isOurs(value[1])
        if isOurs(first) || pythonLaunched { return .ours }
    }
    return isOurs(source) ? .chained : .foreign
}

// MARK: - Install / uninstall

private func quotedCommand(_ bridge: URL, _ args: String) -> String { "\"\(bridge.path)\" \(args)" }

private func resolvedExecutablePath() -> URL {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buffer, &size) == 0 {
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().standardizedFileURL
    }
    if let path = Bundle.main.executablePath { return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL }
    return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
}

private func ensureInstalledBridge() throws -> URL {
    try fm.createDirectory(at: integrations, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: integrations.path)
    let selfURL = resolvedExecutablePath()
    if selfURL.path != installedBridge.resolvingSymlinksInPath().path {
        // Copy beside the destination, then rename over it: a hook running mid-install never finds a missing/partial binary.
        let temp = integrations.appendingPathComponent(".notchling-bridge.\(getpid()).tmp")
        try? fm.removeItem(at: temp)
        try fm.copyItem(at: selfURL, to: temp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path)
        if rename(temp.path, installedBridge.path) != 0 {
            let code = errno
            try? fm.removeItem(at: temp)
            throw BridgeError("Could not install bridge: \(String(cString: strerror(code)))")
        }
    }
    return installedBridge
}

private func finishInstall(_ data: JSON, existed: Bool, to url: URL, label: String) throws {
    if existed { backupOnce(url) }
    try saveJSON(data, to: url)
    print("Connected \(label) via \(url.path)")
}

// Hooks are installed only for state changes (working, needs you, ready, ended), never per tool call.
private let codexEvents = ["UserPromptSubmit", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]

private func installCodex(_ bridge: URL) throws {
    let url = home.appendingPathComponent(".codex/hooks.json")
    let configURL = home.appendingPathComponent(".codex/config.toml")
    var (data, existed) = try loadJSON(url)
    let configText = try readText(configURL)
    let bytes = Array((configText ?? "").utf8)
    let found = try findTopLevelKey(bytes, "notify")

    if data["description"] == nil || data["description"] is NSNull { data["description"] = codexDescription }
    var hooks = removingOurs(from: try hooksMap(data, url))
    let command = quotedCommand(bridge, "hook codex")
    for event in codexEvents {
        var groups = try entryList(hooks, event, url)
        var handler: [String: Any] = ["type": "command", "command": command, "timeout": event == "Interrupt" || event == "SessionEnd" ? 1 : 3]
        if event != "SessionEnd" { handler["async"] = true }
        groups.append(["hooks": [handler]])
        hooks[event] = groups
    }
    data["hooks"] = hooks

    let newLine = "notify = \(tomlArray([bridge.path, "notify"]))\n"
    var newBytes = Array(newLine.utf8)
    var original: [String]?
    var ownership = NotifyOwnership.foreign
    if let found {
        original = parseStringArray(found.source)
        ownership = notifyOwnership(original, source: found.source)
        newBytes = Array(bytes[..<found.start]) + newBytes + Array(bytes[found.end...])
    } else {
        newBytes += bytes
    }

    if existed { backupOnce(url) }
    try saveJSON(data, to: url)
    print("Installed Codex hooks via \(url.path)")
    if ownership == .chained {
        // Another tool's notify already forwards to NotchLing; leave its chain alone.
        try writeNotifySidecar(original: nil, source: nil)
        print("Codex notify is managed by another tool that already forwards to NotchLing; left untouched.")
        print("Review and trust the NotchLing hooks in Codex Settings > Hooks (or /hooks in Codex CLI), then start a new turn for live Working status.")
        return
    }
    // Preserve the user's own notify (never our own wrapper) so it keeps firing and uninstall can restore it.
    if let found, ownership == .foreign { try writeNotifySidecar(original: original, source: String(decoding: bytes[found.start..<found.end], as: UTF8.self)) }
    else if found == nil { try writeNotifySidecar(original: nil, source: nil) }
    if configText != nil { backupOnce(configURL) }
    try atomicWrite(Data(newBytes), to: configURL)
    print("Installed Codex turn-complete notify via \(configURL.path)")
    print("Review and trust the NotchLing hooks in Codex Settings > Hooks (or /hooks in Codex CLI), then start a new turn for live Working status.")
}

private let claudeEvents = ["UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd"]

private func installClaude(_ bridge: URL) throws {
    let url = home.appendingPathComponent(".claude/settings.json")
    var (data, existed) = try loadJSON(url)
    var hooks = removingOurs(from: try hooksMap(data, url))
    for event in claudeEvents {
        var groups = try entryList(hooks, event, url)
        let handler: [String: Any] = ["type": "command", "command": quotedCommand(bridge, "hook claude \(event)"), "timeout": 3]
        groups.append(["hooks": [handler]])
        hooks[event] = groups
    }
    data["hooks"] = hooks
    try finishInstall(data, existed: existed, to: url, label: "Claude")
}

private func installAntigravity(_ bridge: URL) throws {
    let url = home.appendingPathComponent(".gemini/config/hooks.json")
    var (data, existed) = try loadJSON(url)
    func command(_ event: String) -> String { quotedCommand(bridge, "hook antigravity \(event)") }
    data["notchling-status"] = ["enabled": true, "PreInvocation": [["type": "command", "command": command("PreInvocation"), "timeout": 3]], "PostInvocation": [["type": "command", "command": command("PostInvocation"), "timeout": 3]], "Stop": [["type": "command", "command": command("Stop"), "timeout": 3]]]
    try finishInstall(data, existed: existed, to: url, label: "Antigravity")
}

private let cursorEvents = ["beforeSubmitPrompt", "stop", "sessionEnd"]

private func installCursor(_ bridge: URL) throws {
    let url = home.appendingPathComponent(".cursor/hooks.json")
    var (data, existed) = try loadJSON(url)
    if !existed || data.isEmpty { data = ["version": 1, "hooks": JSON()] }
    data["version"] = max((data["version"] as? Int) ?? 1, 1)
    var hooks = removingOurs(from: try hooksMap(data, url))
    for event in cursorEvents {
        var entries = try entryList(hooks, event, url)
        entries.append(["command": quotedCommand(bridge, "hook cursor \(event)"), "timeout": 3])
        hooks[event] = entries
    }
    data["hooks"] = hooks
    try finishInstall(data, existed: existed, to: url, label: "Cursor")
}

/// Writes the result of an uninstall, deleting files that NotchLing itself created and that are now empty.
private func finishUninstall(_ data: JSON, to url: URL, removed: Int, label: String) throws {
    guard removed > 0 else { print("\(label): no NotchLing hooks found"); return }
    let createdByUs = !hasBackup(url)
    if createdByUs, data.isEmpty || (data.count == 1 && (data["version"] as? Int) == 1) {
        try? fm.removeItem(at: url.resolvingSymlinksInPath())
        print("\(label): removed \(removed) NotchLing hook(s); deleted now-empty \(url.path)")
        return
    }
    let backup = URL(fileURLWithPath: url.path + ".notchling-backup")
    if hasBackup(url),
       let original = try? Data(contentsOf: backup),
       let originalObject = try? JSONSerialization.jsonObject(with: original) as? JSON,
       NSDictionary(dictionary: data).isEqual(to: originalObject) {
        try atomicWrite(original, to: url)
    } else {
        try saveJSON(data, to: url)
    }
    print("\(label): removed \(removed) NotchLing hook(s) from \(url.path)")
}

private func uninstallHooksFile(_ url: URL, label: String, descriptionToDrop: String? = nil) throws {
    var (data, _) = try loadJSON(url)
    var removed = 0
    if var hooks = data["hooks"] as? JSON {
        removed = uninstallEventMap(&hooks)
        if removed > 0 { if hooks.isEmpty { data.removeValue(forKey: "hooks") } else { data["hooks"] = hooks } }
    }
    if let descriptionToDrop, (data["description"] as? String) == descriptionToDrop { data.removeValue(forKey: "description"); removed += 1 }
    try finishUninstall(data, to: url, removed: removed, label: label)
}

private func uninstallCodex() throws {
    try uninstallHooksFile(home.appendingPathComponent(".codex/hooks.json"), label: "Codex hooks", descriptionToDrop: codexDescription)
    let configURL = home.appendingPathComponent(".codex/config.toml")
    if let text = try readText(configURL) {
        let bytes = Array(text.utf8)
        let found = try findTopLevelKey(bytes, "notify")
        let ownership = found.map { notifyOwnership(parseStringArray($0.source), source: $0.source) } ?? .foreign
        if ownership == .chained {
            print("Codex notify is managed by another tool that forwards to NotchLing; left untouched.")
        } else if let found, ownership == .ours {
            let sidecar = (try? JSONSerialization.jsonObject(with: Data(contentsOf: notifySidecar))) as? JSON ?? [:]
            var replacement = ""
            if let source = sidecar["originalSource"] as? String { replacement = source }
            else if let original = sidecar["original"] as? [String], !original.isEmpty { replacement = "notify = \(tomlArray(original))\n" }
            let result = Array(bytes[..<found.start]) + Array(replacement.utf8) + Array(bytes[found.end...])
            if String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasBackup(configURL) {
                try? fm.removeItem(at: configURL.resolvingSymlinksInPath())  // we created it; nothing else was in it
            } else {
                try atomicWrite(Data(result), to: configURL)
            }
            print(replacement.isEmpty ? "Codex notify: removed NotchLing notify" : "Codex notify: restored your previous notify")
        } else {
            print("Codex notify: no NotchLing notify found")
        }
    }
    try? fm.removeItem(at: notifySidecar)
}

private func uninstallClaude() throws { try uninstallHooksFile(home.appendingPathComponent(".claude/settings.json"), label: "Claude") }
private func uninstallCursor() throws { try uninstallHooksFile(home.appendingPathComponent(".cursor/hooks.json"), label: "Cursor") }

private func uninstallAntigravity() throws {
    let url = home.appendingPathComponent(".gemini/config/hooks.json")
    var (data, _) = try loadJSON(url)
    let removed = data.removeValue(forKey: "notchling-status") == nil ? 0 : 1
    try finishUninstall(data, to: url, removed: removed, label: "Antigravity")
}

private let providerNames = ["codex", "claude", "antigravity", "cursor"]

private func installProvider(_ provider: String) throws {
    guard providerNames.contains(provider) else { throw BridgeError("Unknown provider: \(provider)") }
    let bridge = try ensureInstalledBridge()
    switch provider { case "codex": try installCodex(bridge); case "claude": try installClaude(bridge); case "antigravity": try installAntigravity(bridge); default: try installCursor(bridge) }
}

/// Removes only NotchLing handlers. Keeps going across providers; returns false if any failed.
private func uninstallProviders(_ names: [String]) -> Bool {
    let targets = names.contains("all") ? providerNames : names
    var ok = true
    for name in targets {
        do {
            switch name {
            case "codex": try uninstallCodex()
            case "claude": try uninstallClaude()
            case "antigravity": try uninstallAntigravity()
            case "cursor": try uninstallCursor()
            default: throw BridgeError("Unknown provider: \(name)")
            }
        } catch { fputs("NotchLing bridge error: \(error)\n", stderr); ok = false }
    }
    return ok
}

private func main() -> Int32 {
    secureLocalData()
    let args = CommandLine.arguments
    guard args.count >= 3 else { fputs("Usage: notchling-bridge hook <provider> [event] | install <provider> | uninstall <provider|all> | notify <json>\n", stderr); return 2 }
    do {
        switch args[1] {
        case "hook":
            switch args[2] { case "codex": runCodexHook(); case "claude": runClaudeHook(args.count > 3 ? args[3] : ""); case "cursor": runCursorHook(args.count > 3 ? args[3] : ""); case "antigravity": runAntigravityHook(args.count > 3 ? args[3] : ""); default: break }
        case "notify": runCodexNotify(args[args.count - 1])
        case "install": try installProvider(args[2])
        case "uninstall": return uninstallProviders(Array(args.dropFirst(2))) ? 0 : 1
        default: return 2
        }
        return 0
    } catch { fputs("NotchLing bridge error: \(error)\n", stderr); return 1 }
}

exit(main())
