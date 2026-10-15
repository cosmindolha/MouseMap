import Foundation

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
    printJSON(["passed": checks, "failed": 0])
}
