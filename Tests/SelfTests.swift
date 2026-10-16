import Foundation
import AppKit
import IOKit.hid

func runSelfTests() {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        checks += 1
    }
    let global = Shortcut(keyCode: 8, modifiers: 1 << 20, label: "⌘C")
    let local = Shortcut(keyCode: 9, modifiers: 1 << 20, label: "⌘V")
    let router = Router()
    router.configuration.profiles = [Profile(id: "*", name: "All", bindings: ["mouse:3": global]), Profile(id: "test.app", name: "Test", bindings: ["mouse:3": local])]
    var emitted: [Shortcut] = []; router.emit = { emitted.append($0) }
    router.activeApp = "test.app"
    check(router.button("mouse:3", down: true), "app override consumes press")
    check(emitted == [local], "application shortcut selected")
    router.activeApp = "other.app"
    check(router.button("mouse:3", down: false), "release remains consumed after app switch")
    check(router.button("mouse:3", down: true), "global fallback")
    check(emitted.last == global, "global shortcut selected")
    router.configuration.enabled = false
    check(router.button("mouse:3", down: false), "pause does not orphan swallowed release")
    check(!router.button("mouse:3", down: true), "disabled passes through")
    router.configuration.enabled = true; router.activeApp = "test.app"
    router.configuration.profiles[1].defaults.insert("mouse:3")
    check(!router.button("mouse:3", down: true), "native override blocks inheritance")
    router.configuration.profiles[1].defaults.remove("mouse:3")
    check(!router.button("mouse:2", down: true), "unmapped press untouched")
    check(!router.button("mouse:2", down: false), "unmapped release untouched")
    router.suspended = true
    check(!router.button("mouse:3", down: true), "recorder suspends shortcuts")
    router.suspended = false
    _ = router.button("mouse:3", down: true); let count = emitted.count
    _ = router.button("mouse:3", down: true)
    check(emitted.count == count, "duplicate press only fires once")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("profiles.json")
    do {
        try Storage.save(router.configuration, to: temporary)
        let loaded = try Storage.load(from: temporary)
        check(loaded.shortcut("mouse:3", app: "test.app") == local, "profiles persist and reload")
        try Data("broken".utf8).write(to: temporary)
        do { _ = try Storage.load(from: temporary); check(false, "corruption must be reported") } catch { checks += 1 }
        try FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
    } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    let fixture: [String: Any] = [
        "applications": ["applications": [["applicationId":"global", "name":"APPLICATION_NAME_DESKTOP"], ["applicationId":"test", "name":"Test", "bundleId":"test.app"]]],
        "profile_keys": ["profile-global", "profile-test"],
        "profile-global": ["applicationId":"global", "assignments": [["slotId":"mx-master-3-6b023_c83", "card":["macro":["type":"KEYSTROKE", "keystroke":["code":25, "modifiers":[227], "displayCharacter":"V"]]]]]],
        "profile-test": ["applicationId":"test", "assignments": [["slotId":"mx-master-3-6b023_c83", "card":["macro":["type":"MOUSE", "mouse":["hidUsage":4]]]]]]
    ]
    do {
        let result = try LogiImport.convert(JSONSerialization.data(withJSONObject: fixture))
        check(result.configuration.profiles.count == 2, "import maps bundle IDs and global profile")
        check(result.configuration.shortcut("hid:83", app: "other")?.keyCode == 9, "USB V becomes macOS V")
        check(result.configuration.shortcut("hid:83", app: "other")?.modifiers == 1 << 20, "USB GUI modifier becomes Command")
        check(result.configuration.shortcut("hid:83", app: "test.app") == nil, "native import overrides global mapping")
        check((result.report["skipped"] as? [[String: String]])?.isEmpty == true, "recognized import has no skipped mappings")
    } catch { fputs("FAIL: importer \(error)\n", stderr); exit(1) }
    check(Logitech.pressedControls([0x11,255,8,0,0,83,0,195,0,0,0,0]) == [83,195], "HID++ simultaneous controls decoded")
    check(Logitech.pressedControls([0x11,255,8,0]) == [], "truncated HID++ report rejected")
    check(Logitech.gestureInput(195, x: 49, y: 0) == "hid:195", "small thumb movement stays click")
    check(Logitech.gestureInput(195, x: 60, y: 3) == "hid:195:right", "thumb gesture horizontal axis")
    check(Logitech.gestureInput(195, x: 10, y: -100) == "hid:195:up", "thumb gesture vertical axis")
    var health = StartupHealth(accessibility: true, inputMonitoring: true, keyboardPosting: true, eventTap: true, mouseReady: true, loginEnabled: true)
    check(health.ready, "startup ready requires all checks")
    health.accessibility = false
    check(!health.ready && health.message == "Accessibility permission needed", "missing Accessibility prevents ready")
    health.accessibility = true; health.inputMonitoring = false
    check(!health.ready && health.message == "Input Monitoring permission needed", "missing Input Monitoring prevents ready")
    health.inputMonitoring = true; health.mouseReady = false
    check(!health.ready && health.message == "Waiting for mouse setup", "mouse discovery alone cannot claim ready")
    health.mouseReady = true; health.keyboardPosting = false
    check(!health.ready && health.message == "Keyboard control permission needed", "keyboard posting access is checked")
    health.keyboardPosting = true; health.profilesValid = false
    check(!health.ready && health.message == "Profiles need attention", "invalid profiles prevent startup")
    health.profilesValid = true; health.enabled = false
    check(!health.ready && health.message == "Paused", "paused startup remains explicit")
    var wheel = TabWheelGate()
    check(wheel.allow(direction: 1, time: 0, application: "browser"), "first wheel event changes tab immediately")
    check(!wheel.allow(direction: 1, time: 0.04, application: "browser"), "high-resolution duplicate suppressed")
    check(!wheel.allow(direction: 1, time: 0.15, application: "browser"), "small turn cannot repeat after old 100ms cooldown")
    check(!wheel.allow(direction: 1, time: 0.32, application: "browser"), "quiet period measures from the last event")
    check(!wheel.allow(direction: 1, time: 0.6, application: "browser", momentum: true), "inertial scroll cannot move another tab")
    check(wheel.allow(direction: 1, time: 0.65, application: "browser"), "new turn works after 300ms quiet")
    check(wheel.allow(direction: -1, time: 0.67, application: "browser"), "direction reversal responds immediately")
    check(!wheel.allow(direction: -1, time: 0.7, application: "browser"), "reverse burst duplicates suppressed")
    check(wheel.allow(direction: -1, time: 0.72, application: "other-browser"), "new foreground app gets its own first action")
    var recovery = HIDRecoveryBudget()
    let retryDelays = (0..<5).compactMap { _ in recovery.nextDelay() }
    check(retryDelays == [0.5, 1, 2, 4, 8], "Bluetooth wake recovery uses bounded backoff")
    check(recovery.nextDelay() == nil, "wake recovery stops after five retries")
    recovery.reset()
    check(recovery.nextDelay() == 0.5, "new wake resets an exhausted recovery budget")
    router.reset(); router.configuration.profiles[1].defaults.remove("mouse:3")
    _ = router.button("mouse:3", down: true); let beforeReset = emitted.count
    router.reset(); _ = router.button("mouse:3", down: true)
    check(emitted.count == beforeReset + 1, "a pre-sleep held button cannot swallow the first post-wake press")
    printJSON(["passed": checks, "failed": 0])
}

// Live diagnostic: exercise the actual sleep/wake handlers and HID device while
// injecting one unavailable Bluetooth write. This does not put the Mac to sleep.
func runLiveWakeRecoveryTest() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let lock = NSLock()
    var failuresRemaining = 0
    var failuresInjected = 0
    let connection = Logitech(writeReport: { device, report in
        lock.lock()
        if failuresRemaining > 0, report.count >= 4, report[2] == 0 {
            failuresRemaining -= 1; failuresInjected += 1; lock.unlock()
            return kIOReturnNotResponding
        }
        lock.unlock()
        return report.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, $0.baseAddress!, $0.count) }
    })
    let state = AppState(logitech: connection, writesHealthReport: false)
    let profileData = try? Data(contentsOf: Storage.url)
    func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 12) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
    func require(_ condition: Bool, _ message: String) {
        guard condition else {
            printJSON(["passed": false, "phase": message, "mouseStatus": connection.status, "status": state.status]); exit(1)
        }
    }
    state.start()
    require(waitUntil { state.ready }, "initial live configuration")
    state.prepareForSleep()
    require(!state.engine.isRunning, "sleep stops the event tap")
    // Resume immediately, while restoration may still be in flight, matching
    // a sleep interruption where the old connection never finished closing.
    lock.lock(); failuresRemaining = 1; lock.unlock()
    state.resumeAfterSleep()
    require(waitUntil { state.ready }, "automatic wake retry and button readback")
    lock.lock(); let injected = failuresInjected; lock.unlock()
    require(injected == 1 && connection.reconnectCount >= 2, "one failed wake handshake retried automatically")
    state.prepareForSleep(); state.resumeAfterSleep()
    require(waitUntil { state.ready }, "second wake cycle")
    require((try? Data(contentsOf: Storage.url)) == profileData, "profiles unchanged")
    var stopped = false
    state.shutdown { stopped = true }
    require(waitUntil({ stopped }, seconds: 4), "shutdown after recovery")
    printJSON(["passed": true, "wakeCycles": 2, "transientFailuresInjected": injected, "hidReconnects": connection.reconnectCount, "profilesUnchanged": true])
}
