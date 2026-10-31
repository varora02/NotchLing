import AppKit

final class MemoryPreferences: UserDefaults {
    var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@main
struct NotchlingContractChecks {
    @MainActor
    static func main() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }

        // Location policy uses synthetic paths, never the real Applications/home.
        let moveHome = URL(fileURLWithPath: "/tmp/move-test")
        func moveLocationPolicy(_ path: String, original: String? = nil, debug: Bool = false) -> ApplicationLocation {
            ApplicationLocation(bundleURL: URL(fileURLWithPath: path), originalURL: original.map { URL(fileURLWithPath: $0) }, home: moveHome, isDebug: debug)
        }
        let dmgLocation = moveLocationPolicy("/Volumes/NotchLing/NotchLing.app")
        let downloadsLocation = moveLocationPolicy("/tmp/move-test/Downloads/NotchLing.app")
        check(dmgLocation.shouldPrompt(skippedPaths: []), "DMG launch must offer to move")
        check(dmgLocation.destination(systemApplicationsWritable: true).path == "/Applications/NotchLing.app", "Prefer system Applications")
        check(dmgLocation.destination(systemApplicationsWritable: false).path == "/tmp/move-test/Applications/NotchLing.app", "Use user Applications when system folder is not writable")
        check(downloadsLocation.shouldPrompt(skippedPaths: []), "Downloads launch must offer to move")
        check(!moveLocationPolicy("/Applications/NotchLing.app").shouldPrompt(skippedPaths: []), "Installed app must not prompt")
        check(!moveLocationPolicy("/tmp/move-test/Applications/NotchLing.app").shouldPrompt(skippedPaths: []), "User installation must not prompt")
        check(moveLocationPolicy("/Applications-other/NotchLing.app").shouldPrompt(skippedPaths: []), "Applications prefix must have a path boundary")
        let translocated = moveLocationPolicy("/private/var/folders/test/AppTranslocation/UUID/d/NotchLing.app", original: downloadsLocation.bundleURL.path)
        check(translocated.shouldPrompt(skippedPaths: []), "Translocated copy must prompt")
        check(translocated.sourceURL == downloadsLocation.bundleURL, "Copy original bundle when available")
        check(moveLocationPolicy(translocated.bundleURL.path).sourceURL == translocated.bundleURL, "Missing translocation SPI falls back to running bundle")
        check(moveLocationPolicy(translocated.bundleURL.path, original: "/Applications/NotchLing.app").shouldPrompt(skippedPaths: []), "Translocation takes precedence over original Applications location")
        check(!moveLocationPolicy("/tmp/DerivedData/Build/Products/Release/NotchLing.app").shouldPrompt(skippedPaths: []), "Build products must not prompt")
        check(!moveLocationPolicy("/tmp/project/.build/NotchLing.app").shouldPrompt(skippedPaths: []), "Swift build folder must not prompt")
        check(!moveLocationPolicy(downloadsLocation.bundleURL.path, debug: true).shouldPrompt(skippedPaths: []), "DEBUG never prompts")
        let skippedPaths: Set<String> = [downloadsLocation.preferencePath]
        check(!downloadsLocation.shouldPrompt(skippedPaths: skippedPaths), "Not now is remembered for the same path")
        check(dmgLocation.shouldPrompt(skippedPaths: skippedPaths), "A different bundle path prompts again")
        check(!translocated.shouldPrompt(skippedPaths: skippedPaths), "Translocation uses stable original path for Not now")
        check(dmgLocation.diskImageVolume { $0.path == "/Volumes/NotchLing/NotchLing.app" }?.path == "/Volumes/NotchLing", "Find distribution volume")
        check(dmgLocation.diskImageVolume { _ in false } == nil, "Do not eject volumes without the distribution app")
        check(downloadsLocation.diskImageVolume { _ in true } == nil, "Downloads has no ejectable volume")
        let moveHandoffContract = ApplicationMoveHandoff(sourcePID: 123, sourcePath: dmgLocation.bundleURL.path, volume: URL(fileURLWithPath: "/Volumes/NotchLing"))
        let parsedHandoff = ApplicationMoveHandoff(arguments: ["NotchLing"] + moveHandoffContract.arguments)
        check(parsedHandoff?.matches(pid: 123, bundlePath: dmgLocation.bundleURL.path) == true, "Handoff preserves source process")
        check(parsedHandoff?.matches(pid: 456, bundlePath: dmgLocation.bundleURL.path) == false, "Handoff cannot exempt other instances")
        check(parsedHandoff?.matches(pid: 123, bundlePath: downloadsLocation.bundleURL.path) == false, "Handoff must match source path as well as PID")
        check(parsedHandoff?.volume == moveHandoffContract.volume, "Handoff preserves eject volume")
        check(ApplicationMoveHandoff(arguments: ["--notchling-move-source", "bad"]) == nil, "Ignore malformed handoff")

        let installRoot = FileManager.default.temporaryDirectory.appendingPathComponent("notchling-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: installRoot) }
        let installSource = installRoot.appendingPathComponent("Downloads/NotchLing.app")
        let installDestination = installRoot.appendingPathComponent("Applications/NotchLing.app")
        try FileManager.default.createDirectory(at: installSource, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: installSource.appendingPathComponent("version"))
        let quarantine = "0083;00000000;NotchLing contract check;"
        for url in [installSource, installSource.appendingPathComponent("version")] {
            let status = quarantine.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
            check(status == 0, "Fixture quarantine must be set")
        }
        var recycled: [URL] = []
        let installer = ApplicationInstaller(recycle: { url in
            let trash = installRoot.appendingPathComponent("Trash-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: trash)
            recycled.append(trash)
            return trash
        })
        try installer.install(source: installSource, destination: installDestination)
        check(recycled.isEmpty, "Fresh install has nothing to recycle")
        for relative in ["", "version"] {
            let source = relative.isEmpty ? installSource : installSource.appendingPathComponent(relative)
            let destination = relative.isEmpty ? installDestination : installDestination.appendingPathComponent(relative)
            check(getxattr(source.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0, "Source quarantine stays intact")
            check(getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == -1 && errno == ENOATTR, "Installed copy must not retain translocation metadata")
        }
        check(FileManager.default.fileExists(atPath: installSource.path), "Copy leaves source intact")
        try Data("old".utf8).write(to: installDestination.appendingPathComponent("version"))
        try installer.install(source: installSource, destination: installDestination)
        let oldVersion = try String(contentsOf: recycled[0].appendingPathComponent("version"), encoding: .utf8)
        let newVersion = try String(contentsOf: installDestination.appendingPathComponent("version"), encoding: .utf8)
        check(oldVersion == "old" && newVersion == "new", "Replacement preserves old bundle in Trash")
        do {
            try installer.install(source: installRoot.appendingPathComponent("missing.app"), destination: installDestination)
            fatalError("Missing source must fail")
        } catch {}
        check(recycled.count == 1 && FileManager.default.fileExists(atPath: installDestination.path), "Copy failure leaves existing install intact")
        let blockedInstaller = ApplicationInstaller(recycle: { _ in throw CocoaError(.fileWriteNoPermission) })
        do {
            try blockedInstaller.install(source: installSource, destination: installDestination)
            fatalError("Trash failure must fail installation")
        } catch {}
        check(FileManager.default.fileExists(atPath: installDestination.path), "Trash failure preserves existing installation")

        let notchScreen = NSRect(x: 0, y: 0, width: 1470, height: 956)
        let nativeStatus = NSRect(x: 1100, y: 923, width: 17, height: 33)
        check(RexPresentationPolicy.nativeStatusVisibility(frame: nativeStatus, occluded: false, screenFrame: notchScreen, barHeight: 38) == true, "Desktop/revealed native menu bar must show the pet")
        check(RexPresentationPolicy.nativeStatusVisibility(frame: nativeStatus, occluded: true, screenFrame: notchScreen, barHeight: 38) == false, "Fullscreen hidden bar must hide pet even though its layout remains unchanged")
        let externalStatus = nativeStatus.offsetBy(dx: 1470, dy: 0)
        check(RexPresentationPolicy.nativeStatusVisibility(frame: externalStatus, occluded: false, screenFrame: notchScreen, barHeight: 38) == nil, "External display cannot control notch display visibility")

        // A hide started in fullscreen must not finish after returning to the
        // desktop or opening the pet's panel, even during another hide cycle.
        var visibility = PetVisibilityTransition()
        visibility.request(visible: true)
        let oldFade = visibility.request(visible: false)
        visibility.request(visible: true)
        check(!visibility.mayFinishHide(oldFade), "Stale fade hides a newly shown pet")
        let currentFade = visibility.request(visible: false)
        check(!visibility.mayFinishHide(oldFade), "Earlier fade takes over a newer hide")
        check(visibility.mayFinishHide(currentFade), "Current passive hide cannot finish")
        visibility.request(visible: true)
        check(!visibility.mayFinishHide(currentFade), "Opening panel must invalidate the fade")
        for suppressed in [false, true] {
            for expanded in [false, true] {
                for alert in [false, true] {
                    check(RexPresentationPolicy.shouldHidePassiveRex(statusAreaSuppressed: suppressed, panelExpanded: expanded, transientAlertActive: alert) == (suppressed && !expanded && !alert), "Panel and transient priority regression")
                }
            }
        }

        let resourceRoot = Bundle.main.resourceURL!.appendingPathComponent("Assets")
        let pets = try NotchlingCatalog.read(from: resourceRoot.appendingPathComponent("notchlings.json"))
        check(pets.count >= 2, "Both Rex and the elephant must ship")
        check(NotchlingAnimation.allCases.count == 5, "Exactly five animations")
        var checked = 0
        for pet in pets {
            for frame in NotchlingKeyframe.allCases {
                let url = resourceRoot.appendingPathComponent(pet.assetDirectory).appendingPathComponent(pet.filename(for: frame))
                let bytes = try Data(contentsOf: url)
                let bitmap = NSBitmapImageRep(data: bytes)!
                check(bitmap.pixelsWide == 104 && bitmap.pixelsHigh == 64, "Wrong canvas: \(url.path)")
                check(bitmap.hasAlpha, "Missing alpha: \(url.path)")
                var visible = 0, transparent = 0
                for y in 0..<64 {
                    for x in 0..<104 {
                        let alpha = bitmap.colorAt(x: x, y: y)!.alphaComponent
                        if alpha > 0.1 { visible += 1 }
                        if alpha == 0 { transparent += 1 }
                    }
                }
                check(visible > 100 && transparent > 100, "Empty sprite or baked background: \(url.path)")
                let first = NotchlingSpriteLoader.image(for: pet, frame: frame)
                check(first != nil, "Bundled loader failed: \(url.path)")
                check(first === NotchlingSpriteLoader.image(for: pet, frame: frame), "Sprite was not cached")
                checked += 1
            }
        }
        let rex = pets.first { $0.id == "rex" }!
        check(rex.filename(for: .attentionUp) == "needs2-up@2x.png", "Approved Needs You wave must be canonical")
        check(!rex.frames.values.contains("needs@2x.png"), "Legacy Needs You must not be selectable")

        // Canvas equality alone missed Ellie's first-pass undersizing. Protect
        // optical footprint and registration while allowing species anatomy.
        func metrics(_ pet: NotchlingDefinition, _ frame: NotchlingKeyframe) throws -> (area: Double, height: Int, bottom: Int) {
            let url = resourceRoot.appendingPathComponent(pet.assetDirectory).appendingPathComponent(pet.filename(for: frame))
            let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
            var area = 0.0, top = 64, bottom = 0
            for y in 0..<64 {
                for x in 0..<104 {
                    let alpha = bitmap.colorAt(x: x, y: y)!.alphaComponent
                    area += alpha
                    if alpha > 0.25 { top = min(top, y); bottom = max(bottom, y) }
                    if pet.id == "elephant" && (x == 0 || x == 103 || y == 0 || y == 63) {
                        check(alpha < 0.06, "Elephant frame clips the canvas: \(frame)")
                    }
                }
            }
            return (area, bottom - top + 1, bottom)
        }
        let elephant = pets.first { $0.id == "elephant" }!
        for frame in [NotchlingKeyframe.resting, .working, .attentionUp, .peekOpen] {
            let reference = try metrics(rex, frame)
            let actual = try metrics(elephant, frame)
            let ratio = actual.area / reference.area
            check((0.90...1.20).contains(ratio), "Optical footprint differs too much from Rex: \(frame), ratio \(ratio)")
            check(abs(actual.bottom - 60) <= 1, "Elephant baseline drift: \(frame)")
        }
        let workingMetrics = try metrics(elephant, .working)
        for frame in [NotchlingKeyframe.attentionDown, .attentionUp, .attentionOut, .attentionIn] {
            let actual = try metrics(elephant, frame)
            check(actual.height == workingMetrics.height && actual.bottom == workingMetrics.bottom, "Upright body scale changes during wave")
        }

        let preferences = MemoryPreferences()
        preferences.set("menuBarMono", forKey: "rexRenderStyle")
        preferences.set("Keep my note", forKey: "rexQuickNote")
        let model = AppModel(preferences: preferences)
        check(model.notchling.id == "rex", "Default must remain Rex")
        check(model.quickNote == "Keep my note", "Existing note must survive")
        model.preview(.working)
        let sessionIDs = model.sessions.map(\.id)
        let pulse = model.attentionPulse
        let nonce = model.devAnimationNonce
        model.selectedNotchlingID = "elephant"
        check(model.sessions.map(\.id) == sessionIDs && model.petMode == .working, "Pet selection changed agent state")
        check(model.attentionPulse == pulse && model.devAnimationNonce == nonce, "Pet selection replayed the animation")
        check(model.headline.hasPrefix("Ellie"), "Headline must follow the pet")
        let restored = AppModel(preferences: preferences)
        check(restored.notchling.id == "elephant", "Selection did not persist")
        preferences.set("removed-pet", forKey: "selectedNotchlingID")
        check(AppModel(preferences: preferences).notchling.id == "rex", "Unknown saved pet needs deterministic fallback")

        for animation in NotchlingAnimation.allCases {
            model.preview(animation)
            switch animation {
            case .rest: check(model.petMode == .resting, "Rest preview")
            case .working: check(model.petMode == .working, "Working preview")
            case .needsYou: check(model.petMode == .needsYou, "Needs You preview")
            case .peekWave: check(model.devPeekVariant == .one, "Wave preview")
            case .peekBlink: check(model.devPeekVariant == .two, "Blink preview")
            }
        }
        for state in [AgentRunState.needsAttention, .completed, .error] {
            model.preview(.rest)
            model.beginPeek()
            let before = model.attentionPulse
            model.ingest(AgentEvent(provider: .codex, sessionID: "real-check", project: "Check", state: state, message: "Attention", timestamp: Date().timeIntervalSince1970, cwd: nil, returnHint: nil))
            check(model.petMode == .needsYou && model.attentionPulse == before + 1, "Live event must interrupt peek and pulse once")
            model.ingest(AgentEvent(provider: .codex, sessionID: "real-check", project: "Check", state: state, message: "Attention", timestamp: Date().timeIntervalSince1970, cwd: nil, returnHint: nil))
            check(model.attentionPulse == before + 1, "Duplicate event replayed attention")
            model.finishPeek()
            model.finishAttentionPresentation()
            check(model.petMode == .resting && model.alertCount == 1, "Alert must remain in the panel after the brief attention beat")
            check(model.notchling.id == "elephant", "Live event reset selected pet")
        }
        model.preview(.rest)
        model.beginPeek()
        model.ingest(AgentEvent(provider: .codex, sessionID: "working-check", project: "Check", state: .working, message: "Working", timestamp: Date().timeIntervalSince1970, cwd: nil, returnHint: nil))
        check(model.petMode == .hidePeek, "Ambient peek must remain available while agents work")
        model.finishPeek()
        check(model.petMode == .working, "Working must resume after a peek")
        model.preview(.rest)
        check(!model.isPeekActive, "Rest replay must cancel active peek")

        let alertTime = Date().timeIntervalSince1970
        let alert = AgentEvent(provider: .codex, sessionID: "clear-check", project: "Check", state: .completed, message: "Review", timestamp: alertTime, cwd: nil, returnHint: nil)
        let active = AgentEvent(provider: .cursor, sessionID: "active-check", project: "Check", state: .working, message: "Working", timestamp: alertTime, cwd: nil, returnHint: nil)
        model.ingest(alert)
        model.ingest(active)
        check(model.alertCount == 1, "Only attention states count as alerts")
        model.finishAttentionPresentation()
        check(model.petMode == .working && model.alertCount == 1, "Active work must resume without discarding an alert")
        model.clearAlerts()
        check(model.alertCount == 0 && model.sessions.map(\.id) == ["active-check"], "Clear alerts must preserve active work")
        model.ingest(alert)
        check(model.alertCount == 0, "Acknowledged event must not reappear on replay")
        model.ingest(AgentEvent(provider: .codex, sessionID: "clear-check", project: "Check", state: .completed, message: "New review", timestamp: alertTime + 1, cwd: nil, returnHint: nil))
        check(model.alertCount == 1, "A later alert must remain visible")
        model.acknowledge("clear-check")
        check(model.alertCount == 0 && model.sessions.map(\.id) == ["active-check"], "Single alert dismissal must preserve active work")

        // Delayed hook processes can deliver events out of order; the model
        // keeps the newest facts about a session.
        let order = AppModel(preferences: MemoryPreferences())
        let base = Date().timeIntervalSince1970
        func event(_ id: String, _ state: AgentRunState, _ message: String, at time: Double) -> AgentEvent {
            AgentEvent(provider: .claudeCode, sessionID: id, project: "Check", state: state, message: message, timestamp: time, cwd: nil, returnHint: nil)
        }
        order.ingest(event("order", .working, "Working", at: base + 10))
        order.ingest(event("order", .completed, "Late alert", at: base))
        check(order.alertCount == 0 && order.sessions.first?.state == .working, "Older event must not overwrite a newer session state")
        order.ingest(event("order", .idle, "", at: base + 5))
        check(order.sessions.count == 1, "Older idle must not end a session that reported later")
        order.ingest(event("order", .idle, "", at: base + 20))
        check(order.sessions.isEmpty, "Newer idle must end the session")
        order.ingest(event("order", .working, "Late working", at: base + 15))
        check(order.sessions.isEmpty, "Older event must not resurrect an ended session")
        order.ingest(event("order", .working, "Resumed", at: base + 25))
        check(order.sessions.count == 1, "A newer event must restart an ended session")

        // Dismissing an alert also dismisses its immediate repeat (Claude's
        // idle_prompt echoes the Stop alert), until the session works again.
        let repeats = AppModel(preferences: MemoryPreferences())
        repeats.ingest(event("repeat", .completed, "Ready for review", at: base))
        repeats.acknowledge("repeat")
        repeats.ingest(event("repeat", .completed, "Ready for review", at: base + 60))
        check(repeats.alertCount == 0, "Same alert after acknowledgment must stay dismissed")
        repeats.ingest(event("repeat", .completed, "Different", at: base + 61))
        check(repeats.alertCount == 1, "A different message must still alert")
        repeats.acknowledge("repeat")
        repeats.ingest(event("repeat", .working, "Working", at: base + 70))
        repeats.ingest(event("repeat", .completed, "Different", at: base + 80))
        check(repeats.alertCount == 1, "Alert after new work must show again")
        repeats.finishAttentionPresentation()
        check(repeats.petMode == .resting && repeats.headline == "Something needs you", "Headline must not claim rest while alerts wait")

        // Silent working sessions expire; alerts wait for the user.
        let expiry = AppModel(preferences: MemoryPreferences())
        let now = Date()
        let stale = now.timeIntervalSince1970 - AppModel.staleWorkingInterval - 60
        expiry.ingest(event("stale-work", .working, "Working", at: stale))
        expiry.ingest(event("stale-alert", .completed, "Review", at: stale))
        expiry.ingest(event("fresh-work", .working, "Working", at: now.timeIntervalSince1970))
        expiry.expireStaleSessions(now: now)
        check(Set(expiry.sessions.map(\.id)) == ["stale-alert", "fresh-work"], "Only stale working sessions expire")
        expiry.ingest(event("fresh-alert", .completed, "Review", at: now.timeIntervalSince1970))
        expiry.acknowledge("fresh-alert")
        expiry.expireStaleSessions(now: now)
        expiry.ingest(event("fresh-alert", .completed, "Review", at: now.timeIntervalSince1970 + 1))
        check(expiry.alertCount == 1, "Acknowledgment must hold before it ages out")
        expiry.expireStaleSessions(now: now.addingTimeInterval(AppModel.staleWorkingInterval + 120))
        expiry.ingest(event("fresh-alert", .completed, "Review", at: now.timeIntervalSince1970 + 1000))
        check(expiry.alertCount == 2, "Old acknowledgments must be pruned")

        // The inbox may be truncated or replaced while the app runs.
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: inbox) }
        func line(_ id: String, _ time: Double) -> String {
            "{\"provider\":\"codex\",\"sessionID\":\"\(id)\",\"project\":\"Check\",\"state\":\"working\",\"message\":\"Working\",\"timestamp\":\(time)}\n"
        }
        try (line("first-session-name", 1) + line("second-session-name", 2) + "{\"partial\":").write(to: inbox, atomically: false, encoding: .utf8)
        let monitor = LocalEventMonitor(inboxURL: inbox)
        var received: [String] = []
        monitor.poll { received.append($0.sessionID) }
        check(received == ["first-session-name", "second-session-name"], "Inbox lines must be delivered once")
        try (line("a", 3)).write(to: inbox, atomically: false, encoding: .utf8)
        monitor.poll { received.append($0.sessionID) }
        check(received.last == "a" && received.count == 3, "Truncated inbox must restart from the top and drop the partial line")
        // An atomic write swaps in a new file (new inode) like a log rotation.
        try (line("replaced-session-with-a-long-name", 4)).write(to: inbox, atomically: true, encoding: .utf8)
        monitor.poll { received.append($0.sessionID) }
        check(received.last == "replaced-session-with-a-long-name" && received.count == 4, "Replaced inbox must be read from the top")
        let handle = try FileHandle(forWritingTo: inbox)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.write(contentsOf: Data(line("after-garbage", 5).utf8))
        try handle.close()
        monitor.poll { received.append($0.sessionID) }
        check(received.last == "after-garbage" && received.count == 5, "A malformed line must not block later events")
        try Data(count: Int(LocalEventMonitor.maxInboxBytes) + 1).write(to: inbox)
        monitor.start { _ in }
        monitor.stop()
        let truncatedSize = try FileManager.default.attributesOfItem(atPath: inbox.path)[.size] as? NSNumber
        check(truncatedSize?.intValue == 0, "Oversized inbox must be truncated on start")

        // Old events (project names, paths) are not kept between launches, and the data is owner-only.
        let privateDir = FileManager.default.temporaryDirectory.appendingPathComponent("notchling-owner-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: privateDir) }
        try FileManager.default.createDirectory(at: privateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let privateInbox = privateDir.appendingPathComponent("inbox.jsonl")
        try Data("{\"old\":\"event\"}\n".utf8).write(to: privateInbox)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: privateInbox.path)
        let privateMonitor = LocalEventMonitor(inboxURL: privateInbox)
        privateMonitor.start { _ in }
        privateMonitor.stop()
        func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
        check((try? Data(contentsOf: privateInbox).count) == 0, "Launch clears events left from an earlier run")
        check(mode(privateDir) == 0o700 && mode(privateInbox) == 0o600, "Support folder is owner-only (0700) and the event file is 0600, even if it was looser before")

        for frame in [NotchlingKeyframe.attentionDown, .attentionUp, .attentionOut, .attentionIn] {
            check(NotchlingKeyframe.resolve(mode: .needsYou, attention: frame, blinking: true, waving: true) == frame, "Peek flags must not override attention")
        }
        check(NotchlingKeyframe.resolve(mode: .hidePeek, attention: .attentionUp, blinking: true, waving: false) == .peekBlink, "Blink keyframe routing")
        check(NotchlingKeyframe.resolve(mode: .hidePeek, attention: .attentionUp, blinking: false, waving: true) == .peekWave, "Wave keyframe routing")

        // A catalog missing a keyframe must fail before an unsafe lookup.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temp) }
        var malformed = try JSONSerialization.jsonObject(with: Data(contentsOf: resourceRoot.appendingPathComponent("notchlings.json"))) as! [[String: Any]]
        malformed[0]["frames"] = ["resting": "resting@2x.png"]
        try JSONSerialization.data(withJSONObject: malformed).write(to: temp)
        do {
            _ = try NotchlingCatalog.read(from: temp)
            fatalError("Incomplete pack was accepted")
        } catch { }

        // MARK: Onboarding

        // Step sequencing: the Codex trust page exists only when Codex was connected.
        let noCodex: Set<AgentProvider> = [.claudeCode, .cursor]
        let withCodex: Set<AgentProvider> = [.claudeCode, .codex]
        check(OnboardingStep.welcome.next(connected: []) == .companion, "Welcome leads to the companion page")
        check(OnboardingStep.companion.next(connected: []) == .connect, "Companion leads to connect")
        check(OnboardingStep.connect.next(connected: noCodex) == .done, "No Codex means no trust page")
        check(OnboardingStep.connect.next(connected: []) == .done, "Skipping connect goes straight to done")
        check(OnboardingStep.connect.next(connected: withCodex) == .codexTrust, "Codex connected shows the trust page")
        check(OnboardingStep.codexTrust.next(connected: withCodex) == .done, "Trust page leads to done")
        check(OnboardingStep.done.next(connected: withCodex) == nil, "Done is last")
        check(OnboardingStep.pages(connected: noCodex) == [.welcome, .companion, .connect, .done], "Page dots without Codex")
        check(OnboardingStep.pages(connected: withCodex).count == 5, "Page dots with Codex")
        check(OnboardingStep.connect.previous == .companion && OnboardingStep.welcome.previous == nil, "Back navigation")
        check(OnboardingCopy.agentList([]) == nil, "No agents, no list")
        check(OnboardingCopy.agentList([.codex]) == "Codex", "One agent")
        check(OnboardingCopy.agentList([.codex, .claudeCode]) == "Claude Code or Codex", "Two agents")
        check(OnboardingCopy.agentList([.codex, .claudeCode, .cursor]) == "Claude Code, Codex or Cursor", "Three agents")
        check(OnboardingCopy.age(of: Date().addingTimeInterval(-300), now: Date()) == "5 min ago", "Relative minutes")
        check(OnboardingCopy.age(of: Date(), now: Date()) == "just now", "Relative now")

        // Detection under an overridden home never reads the real one.
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("notchling-onboarding-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        func makeHome(_ name: String) throws -> URL {
            let url = sandbox.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func touch(_ path: String, in home: URL, contents: String = "") throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let emptyHome = try makeHome("empty")
        for provider in AgentProvider.allCases {
            check(!IntegrationCatalog.isInstalled(provider, home: emptyHome, includeSystemLocations: false), "Nothing is installed in an empty home: \(provider)")
        }
        let toolHome = try makeHome("tools")
        try FileManager.default.createDirectory(at: toolHome.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolHome.appendingPathComponent("Applications/Claude.app"), withIntermediateDirectories: true)
        try touch(".local/bin/cursor", in: toolHome)
        check(IntegrationCatalog.isInstalled(.codex, home: toolHome, includeSystemLocations: false), "~/.codex means Codex")
        check(IntegrationCatalog.isInstalled(.claudeCode, home: toolHome, includeSystemLocations: false), "~/Applications/Claude.app means Claude")
        check(IntegrationCatalog.isInstalled(.cursor, home: toolHome, includeSystemLocations: false), "A cursor CLI means Cursor")
        check(!IntegrationCatalog.isInstalled(.antigravity, home: toolHome, includeSystemLocations: false), "Antigravity stays not installed")
        try FileManager.default.createDirectory(at: toolHome.appendingPathComponent(".gemini/antigravity"), withIntermediateDirectories: true)
        check(IntegrationCatalog.isInstalled(.antigravity, home: toolHome, includeSystemLocations: false), "~/.gemini/antigravity means Antigravity")
        check(AgentProvider.claudeCode.bridgeName == "claude" && AgentProvider.codex.bridgeName == "codex", "Bridge provider names")
        // Codex Computer Use wraps notify and forwards to NotchLing; that alone is not a connection.
        let chainedHome = try makeHome("chained")
        try touch(".codex/config.toml", in: chainedHome, contents: "notify = [\"/opt/Other/client\", \"turn-ended\", \"--previous-notify\", \"[\\\"/usr/bin/python3\\\",\\\"/x/codex-notify-wrapper.py\\\"]\"]\n")
        check(!IntegrationCatalog.connectedProviders(home: chainedHome).contains(.codex), "A chained notify alone does not mark Codex connected")
        try touch(".codex/hooks.json", in: chainedHome, contents: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"/x/notchling-bridge\" hook codex"}]}]}}"#)
        check(IntegrationCatalog.connectedProviders(home: chainedHome).contains(.codex), "NotchLing's Codex hooks mark Codex connected")

        // The helper's stderr becomes one short inline line.
        let fakeHome = URL(fileURLWithPath: "/tmp/tester")
        check(
            BridgeHelper.summarize(standardError: "NotchLing bridge error: /tmp/tester/.claude/settings.json is not valid JSON (Unexpected character). Left untouched; fix or remove it and retry.\n", home: fakeHome, provider: .claudeCode)
                == "Couldn't read ~/.claude/settings.json. Fix or remove it, then retry.",
            "Malformed JSON message"
        )
        check(
            BridgeHelper.summarize(standardError: "NotchLing bridge error: config.toml could not be parsed (unterminated string). Left untouched; fix it and retry.", home: fakeHome, provider: .codex)
                == "Couldn't read ~/.codex/config.toml. Fix or remove it, then retry.",
            "Malformed TOML message"
        )
        check(BridgeHelper.summarize(standardError: "", home: fakeHome, provider: .cursor) == "Couldn't connect Cursor. Try again.", "Silent failure message")
        check(BridgeHelper.summarize(standardError: String(repeating: "x", count: 400), home: fakeHome, provider: .cursor).count <= 110, "Long messages are capped")

        // Connect, retry and disconnect through a fake helper.
        let connectHome = try makeHome("connect")
        try FileManager.default.createDirectory(at: connectHome.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: connectHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: connectHome.appendingPathComponent(".gemini/antigravity"), withIntermediateDirectories: true)
        var helperCalls: [[String]] = []
        var failingProviders: Set<String> = ["claude"]
        let fakeRunner: ConnectionsStore.Runner = { arguments in
            helperCalls.append(arguments)
            if failingProviders.contains(arguments[1]) {
                return BridgeHelper.Output(status: 1, standardError: "NotchLing bridge error: \(connectHome.path)/.claude/settings.json is not valid JSON (x). Left untouched; fix or remove it and retry.")
            }
            if arguments[0] == "install", arguments[1] == "codex" {
                try touch(".codex/hooks.json", in: connectHome, contents: "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"\\\"/x/notchling-bridge\\\" hook codex\"}]}]}}")
            }
            if arguments[0] == "uninstall", arguments[1] == "codex" {
                try? FileManager.default.removeItem(at: connectHome.appendingPathComponent(".codex/hooks.json"))
            }
            return BridgeHelper.Output(status: 0, standardError: "")
        }
        let connectionPreferences = MemoryPreferences()
        let store = ConnectionsStore(home: connectHome, includeSystemLocations: false, preferences: connectionPreferences, runner: fakeRunner)
        check(store.installed == [.codex, .claudeCode, .antigravity], "Detected tools")
        check(store.state(for: .cursor, lastEvent: nil) == .notInstalled, "Missing tool is not installed")
        check(store.state(for: .codex, lastEvent: nil) == .available, "Detected tool is available")
        store.resetSelection()
        check(store.selection == store.installed, "Detected tools start toggled on")
        store.toggle(.cursor, on: true)
        check(!store.selection.contains(.cursor), "A tool that is not installed cannot be toggled on")

        let preferencesForFlow = MemoryPreferences()
        let flowModel = AppModel(preferences: preferencesForFlow, connections: store)
        flowModel.startOnboardingIfNeeded()
        check(flowModel.panelRoute == .onboarding && flowModel.isExpanded && flowModel.onboarding.step == .welcome, "First launch opens onboarding")
        check(preferencesForFlow.object(forKey: "hasStartedOnboarding") as? Bool == true, "First setup persists its started flag")
        flowModel.openQuickNote()
        check(!flowModel.isQuickNoteEditor && flowModel.panelRoute == .onboarding, "Quick Note is ignored during setup")
        let resumedEmpty = AppModel(preferences: preferencesForFlow, connections: ConnectionsStore(home: connectHome, includeSystemLocations: false, preferences: connectionPreferences, runner: fakeRunner))
        resumedEmpty.startOnboardingIfNeeded()
        check(resumedEmpty.onboarding.step == .connect && !resumedEmpty.hasCompletedOnboarding, "Interrupted setup resumes at connect before any tool succeeds")
        flowModel.toggleExpanded()
        check(flowModel.isExpanded && flowModel.panelRoute == .onboarding, "Pet click must not dismiss setup")
        flowModel.onboarding.advance()
        flowModel.onboarding.advance()
        check(flowModel.onboarding.step == .connect, "Reached the connect page")
        store.toggle(.antigravity, on: false)
        let beforeConnect = Date()
        await flowModel.onboarding.connect(using: store)
        check(helperCalls == [["install", "claude"], ["install", "codex"]], "Installs in list order, only toggled tools: \(helperCalls)")
        check(flowModel.onboarding.step == .connect, "A failed tool keeps the user on the connect page")
        check(store.state(for: .claudeCode, lastEvent: nil) == .failed("Couldn't read ~/.claude/settings.json. Fix or remove it, then retry."), "Failure is shown inline")
        check(flowModel.onboarding.connectedThisRun == [.codex], "Codex connected despite Claude failing")
        failingProviders = []
        helperCalls = []
        await flowModel.onboarding.connect(using: store)
        check(helperCalls == [["install", "claude"]], "Retry only reinstalls what failed: \(helperCalls)")
        check(store.errors.isEmpty, "Retry clears the error")
        check(flowModel.onboarding.step == .codexTrust, "Codex connected leads to the trust page")
        check(store.connected.contains(.codex), "Connected set reflects the hooks file")

        let resumedConnected = AppModel(preferences: preferencesForFlow, connections: ConnectionsStore(home: connectHome, includeSystemLocations: false, preferences: connectionPreferences, runner: fakeRunner))
        resumedConnected.startOnboardingIfNeeded()
        check(resumedConnected.panelRoute == .onboarding && resumedConnected.onboarding.step == .codexTrust && !resumedConnected.hasCompletedOnboarding, "Quitting after connecting Codex resumes trust instead of upgrade-skipping")
        check(resumedConnected.onboarding.connectedThisRun.contains(.codex), "Resumed setup retains connected tools")

        // Waiting until a real event arrives after the install.
        let codexInstall = store.installedAt[.codex]!
        check(codexInstall >= beforeConnect, "Install time recorded")
        check(ConnectionHealth.resolve(installedAt: codexInstall, lastEvent: codexInstall) == .waiting, "An event exactly at install time does not count")
        check(ConnectionHealth.resolve(installedAt: codexInstall, lastEvent: nil) == .waiting, "No event yet is waiting")
        check(ConnectionHealth.resolve(installedAt: codexInstall, lastEvent: codexInstall.addingTimeInterval(-60)) == .waiting, "An event from before the install does not count")
        check(ConnectionHealth.resolve(installedAt: codexInstall, lastEvent: codexInstall.addingTimeInterval(5)) == .live(lastEvent: codexInstall.addingTimeInterval(5)), "A later event is live")
        check(ConnectionHealth.resolve(installedAt: nil, lastEvent: Date(timeIntervalSince1970: 1)) != .waiting, "Without an install time any event is live")
        check(flowModel.lastEventAt[.codex] == nil, "No Codex event seen yet")
        flowModel.ingest(AgentEvent(provider: .claudeCode, sessionID: "claude:track", project: "Check", state: .working, message: "Working", timestamp: Date().timeIntervalSince1970, cwd: nil, returnHint: nil))
        check(flowModel.lastEventAt[.claudeCode] != nil && flowModel.lastEventAt[.codex] == nil, "Events are tracked per provider")
        flowModel.ingest(AgentEvent(provider: .codex, sessionID: "demo-codex-track", project: "Demo", state: .working, message: "Working", timestamp: Date().timeIntervalSince1970, cwd: nil, returnHint: nil))
        check(flowModel.lastEventAt[.codex] == nil, "Demo sessions never count as a real event")
        var notifyEvent = AgentEvent(provider: .codex, sessionID: "codex:notify", project: "Check", state: .working, message: "Working", timestamp: Date().timeIntervalSince1970, cwd: nil, returnHint: nil, source: "notify")
        notifyEvent = try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(notifyEvent))
        flowModel.ingest(notifyEvent)
        check(flowModel.sessions.contains { $0.id == "codex:notify" }, "Notify events still display normally")
        check(flowModel.lastEventAt[.codex] == nil && store.state(for: .codex, lastEvent: flowModel.lastEventAt[.codex]) == .connected(.waiting), "Notify cannot verify a connection or Codex trust")
        let legacyEvent = try JSONDecoder().decode(AgentEvent.self, from: Data(#"{"provider":"codex","sessionID":"codex:legacy","project":"Check","state":"working","message":"Working","timestamp":1}"#.utf8))
        check(legacyEvent.source == nil && legacyEvent.isHookEvent, "Events without source decode as hooks")
        let legacyPreferences = MemoryPreferences()
        legacyPreferences.set(["codex": Date().timeIntervalSince1970], forKey: "lastEventAtByProvider")
        check(AppModel(preferences: legacyPreferences).lastEventAt[.codex] == nil, "Old mixed-origin verification timestamps are not trusted")
        flowModel.ingest(AgentEvent(provider: .codex, sessionID: "codex:track", project: "Check", state: .working, message: "Working", timestamp: Date().timeIntervalSince1970, cwd: nil, returnHint: nil))
        check(ConnectionHealth.resolve(installedAt: store.installedAt[.codex], lastEvent: flowModel.lastEventAt[.codex]) != .waiting, "Codex turns Connected after its first event")
        check(store.state(for: .codex, lastEvent: flowModel.lastEventAt[.codex]) == .connected(.live(lastEvent: flowModel.lastEventAt[.codex]!)), "Connection state follows the event")
        check(AppModel(preferences: preferencesForFlow).lastEventAt[.codex] != nil, "Last event times persist")

        flowModel.onboarding.advance()
        check(flowModel.onboarding.step == .done, "Trust page leads to done")
        check(!LaunchAtLogin.isEligible, "Contract harness must not register a real login item")
        flowModel.onboarding.setOpensAtLogin(true)
        check(!flowModel.onboarding.opensAtLogin && flowModel.onboarding.loginNote == "Move NotchLing to Applications to open it at login.", "Ineligible login setter preserves the move-to-Applications note")
        flowModel.showOnboardingDemoAlert()
        check(flowModel.panelRoute == .agents && !flowModel.isExpanded && flowModel.hasCompletedOnboarding, "Show me an alert ends setup and sets the flag")
        await Task.yield()
        try await Task.sleep(nanoseconds: 700_000_000)
        check(flowModel.alertCount == 1 && flowModel.petMode == .needsYou, "The demo alert plays the real Needs You beat")
        flowModel.clearAlerts()
        check(flowModel.alertCount == 0, "The demo alert can be cleared like a real one")

        let oldCodexEvent = flowModel.lastEventAt[.codex]!
        await store.disconnect(.codex)
        check(helperCalls.last == ["uninstall", "codex"] && !store.connected.contains(.codex), "Disconnect runs the helper and updates the list")

        check(flowModel.lastEventAt[.codex] == nil && AppModel(preferences: preferencesForFlow).lastEventAt[.codex] == nil, "Disconnect clears verification in memory and preferences")
        check(ConnectionsStore(home: connectHome, includeSystemLocations: false, preferences: connectionPreferences, runner: fakeRunner).installedAt[.codex] == nil, "Disconnect clears persisted install time")
        let reconnected = await store.connect(.codex)
        check(reconnected, "Reconnect succeeds")
        let restartedStore = ConnectionsStore(home: connectHome, includeSystemLocations: false, preferences: connectionPreferences, runner: fakeRunner)
        // Date epoch conversion can round sub-microsecond precision; compare the stored representation.
        check(restartedStore.installedAt[.codex]?.timeIntervalSince1970 == store.installedAt[.codex]?.timeIntervalSince1970, "Install time survives restart")
        check(restartedStore.state(for: .codex, lastEvent: oldCodexEvent) == .connected(.waiting), "After reconnect and restart, the old event cannot verify hooks")

        // A suspended install cannot advance a dismissed or replacement flow.
        for replay in [false, true] {
            var pending: CheckedContinuation<BridgeHelper.Output, Never>?
            let delayedStore = ConnectionsStore(home: emptyHome, includeSystemLocations: false, preferences: MemoryPreferences(), runner: { _ in
                await withCheckedContinuation { pending = $0 }
            })
            let delayedModel = AppModel(preferences: MemoryPreferences(), connections: delayedStore)
            delayedModel.startOnboardingIfNeeded()
            delayedModel.onboarding.advance()
            delayedModel.onboarding.advance()
            delayedStore.selection = [.cursor]
            let install = Task { await delayedModel.onboarding.connect(using: delayedStore) }
            while pending == nil { await Task.yield() }
            delayedModel.finishOnboarding()
            if replay { delayedModel.replayOnboarding() }
            let stepAfterDismissal = delayedModel.onboarding.step
            pending!.resume(returning: BridgeHelper.Output(status: 0, standardError: ""))
            await install.value
            check(delayedModel.onboarding.step == stepAfterDismissal && delayedModel.onboarding.connectedThisRun.isEmpty, "Late install cannot mutate dismissed or replayed setup")
            check(!delayedModel.onboarding.isConnecting && delayedModel.onboarding.loginNote == nil && !delayedModel.onboarding.opensAtLogin, "Late install cannot sync or register login")
        }

        // Hook config alone means connected, even with no app/CLI in known locations.
        let hooksOnlyHome = try makeHome("hooks-only")
        for path in [".claude/settings.json", ".cursor/hooks.json", ".codex/hooks.json", ".gemini/config/hooks.json"] {
            try touch(path, in: hooksOnlyHome, contents: #"{"hooks":{"Stop":[{"command":"/x/notchling-bridge hook"}]}}"#)
        }
        let hooksOnly = ConnectionsStore(home: hooksOnlyHome, includeSystemLocations: false, preferences: MemoryPreferences(), runner: fakeRunner)
        check(hooksOnly.connected == Set(AgentProvider.allCases) && hooksOnly.installed == hooksOnly.connected, "Every connected provider displays as installed regardless of app location")
        hooksOnly.refresh()
        check(hooksOnly.state(for: .cursor, lastEvent: nil) == .connected(.waiting) && hooksOnly.state(for: .claudeCode, lastEvent: nil) == .connected(.waiting), "Refresh preserves hook-only connections")

        // First-run skip: an upgrade with a connected tool never sees setup.
        check(AppModel.needsOnboarding(completed: false, connected: []), "Fresh install needs setup")
        check(!AppModel.needsOnboarding(completed: false, connected: [.codex]), "Already connected skips setup")
        check(AppModel.needsOnboarding(completed: false, started: true, connected: [.codex]), "Started setup never upgrade-skips")
        check(!AppModel.needsOnboarding(completed: true, connected: []), "Completed setup never repeats")
        let upgradeHome = try makeHome("upgrade")
        try touch(".cursor/hooks.json", in: upgradeHome, contents: "{\"hooks\":{\"stop\":[{\"command\":\"\\\"/x/notchling-bridge\\\" hook cursor stop\"}]}}")
        try FileManager.default.createDirectory(at: upgradeHome.appendingPathComponent("Applications/Cursor.app"), withIntermediateDirectories: true)
        let upgradePreferences = MemoryPreferences()
        let upgraded = AppModel(preferences: upgradePreferences, connections: ConnectionsStore(home: upgradeHome, includeSystemLocations: false, preferences: MemoryPreferences(), runner: fakeRunner))
        upgraded.startOnboardingIfNeeded()
        check(upgraded.panelRoute == .agents && !upgraded.isExpanded && upgraded.hasCompletedOnboarding, "Upgrade skips onboarding and records it")
        let movePreferences = MemoryPreferences()
        let moveModel = AppModel(preferences: movePreferences, connections: ConnectionsStore(home: emptyHome, includeSystemLocations: false, preferences: MemoryPreferences(), runner: fakeRunner))
        moveModel.startLaunchFlow(location: downloadsLocation)
        check(moveModel.panelRoute == .moveToApplications && moveModel.isExpanded, "Move panel precedes first-run setup")
        check(movePreferences.object(forKey: "hasStartedOnboarding") == nil, "Move prompt must not start or complete onboarding")
        moveModel.skipMoveToApplications()
        check(moveModel.panelRoute == .onboarding && !moveModel.hasCompletedOnboarding, "Not now proceeds to onboarding")
        moveModel.finishOnboarding()
        moveModel.startLaunchFlow(location: downloadsLocation)
        check(moveModel.panelRoute == .agents, "Same path respects persisted Not now")
        moveModel.startLaunchFlow(location: dmgLocation)
        check(moveModel.panelRoute == .moveToApplications, "New path prompts even after onboarding completed")
        moveModel.skipMoveToApplications()
        check(moveModel.panelRoute == .agents, "Completed onboarding is not replayed after Not now")
        let finished = AppModel(preferences: upgradePreferences, connections: ConnectionsStore(home: emptyHome, includeSystemLocations: false, preferences: MemoryPreferences(), runner: fakeRunner))
        finished.startOnboardingIfNeeded()
        check(finished.panelRoute == .agents, "A recorded completion stays skipped")
        finished.replayOnboarding()
        check(finished.panelRoute == .onboarding && finished.isExpanded && !finished.hasCompletedOnboarding, "Replay reopens setup")
        check(upgradePreferences.object(forKey: "hasStartedOnboarding") == nil, "Replay does not persist a first-run started flag")
        finished.finishOnboarding()
        check(finished.panelRoute == .agents && finished.hasCompletedOnboarding, "Done sets the flag")
        finished.openConnections()
        check(finished.panelRoute == .connections && finished.isExpanded, "Connections opens the panel")
        finished.openQuickNote()
        check(finished.panelRoute == .agents && finished.isQuickNoteEditor && finished.isExpanded, "Quick Note replaces the Connections panel")
        finished.openConnections()
        finished.isExpanded = false
        check(finished.panelRoute == .agents, "Closing the panel leaves Connections")
        print("PASS: \(pets.count) packs, \(checked) bundled transparent sprites, optical sizing/registration, five previews, selection persistence, move location/replacement/handoff, onboarding sequencing/detection/connection health, cache, brief live alerts, working peeks, stale-fade rejection and presentation priority")
    }
}
