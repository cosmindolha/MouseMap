import AppKit
import ApplicationServices
import IOKit.hid

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var label: String
    var action: String? = nil
}

struct Profile: Codable, Identifiable {
    var id: String // application bundle ID; * is the global profile
    var name: String
    var bindings: [String: Shortcut] = [:]
    var defaults: Set<String> = [] // explicitly override an inherited binding with native behavior
}

struct Configuration: Codable {
    var version = 1
    var enabled = true
    var profiles = [Profile(id: "*", name: "All applications")]

    func shortcut(_ input: String, app: String) -> Shortcut? {
        if let profile = profiles.first(where: { $0.id == app }) {
            if profile.defaults.contains(input) { return nil }
            if let shortcut = profile.bindings[input] { return shortcut }
        }
        return profiles.first(where: { $0.id == "*" })?.bindings[input]
    }
}

enum Storage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MouseMap", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("profiles.json") }
    static func load(from url: URL = url) throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw NSError(domain: "MouseMap", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported profile version \(value.version)"]) }
        return value
    }
    static func save(_ value: Configuration, to url: URL = url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

enum Inputs {
    static let standard = [("mouse:2", "Wheel click"), ("mouse:3", "Back button"), ("mouse:4", "Forward button")]
    static func name(_ id: String) -> String {
        if id.hasPrefix("wheel:") { return "Thumb wheel " + id.dropFirst(6) }
        if id.split(separator: ":").count == 3 {
            let parts = id.split(separator: ":")
            return name("hid:" + parts[1]) + " · " + parts[2]
        }
        if let item = standard.first(where: { $0.0 == id }) { return item.1 }
        if id.hasPrefix("mouse:") { return "Mouse button \((Int(id.dropFirst(6)) ?? 0) + 1)" }
        let known: [Int: String] = [0x52: "Wheel click", 0x53: "Back button", 0x56: "Forward button", 0xc3: "Thumb button", 0xc4: "Wheel mode button", 0xd0: "Thumb button", 0xd7: "Gesture button"]
        let number = Int(id.dropFirst(4)) ?? 0
        return known[number] ?? String(format: "Logitech button 0x%04X", number)
    }
}

// Pure decisions shared by live event handling and command-line tests.
final class Router {
    var configuration = Configuration()
    var activeApp = ""
    var suspended = false
    var emit: (Shortcut) -> Void = { _ in }
    var observed: (String) -> Void = { _ in }
    private var swallowed = Set<String>()

    @discardableResult func button(_ input: String, down: Bool) -> Bool {
        if !down { return swallowed.remove(input) != nil }
        observed(input)
        guard configuration.enabled, !suspended,
              let shortcut = configuration.shortcut(input, app: activeApp) else { return false }
        guard !swallowed.contains(input) else { return true }
        swallowed.insert(input)
        emit(shortcut)
        return true
    }
    func reset() { swallowed.removeAll() }
}

// A physical thumb-wheel turn produces a stream of high-resolution events.
// Browser tab navigation should treat that stream as one deliberate action.
struct TabWheelGate {
    private var lastTime = -Double.infinity
    private var lastDirection = 0
    private var lastApplication = ""
    mutating func allow(direction: Int, time: TimeInterval, application: String, momentum: Bool = false) -> Bool {
        guard !momentum else { return false }
        let newBurst = time - lastTime >= 0.3 || direction != lastDirection || application != lastApplication
        lastTime = time; lastDirection = direction; lastApplication = application
        return newBurst
    }
}

final class EventEngine {
    let router: Router
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var wheelTime = Date.distantPast
    private var tabWheel = TabWheelGate()
    var error: (String) -> Void = { _ in }
    private let marker: Int64 = 0x4D4F5553454D4150
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init(router: Router) { self.router = router }
    func start() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let events: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                let engine = Unmanaged<EventEngine>.fromOpaque(context!).takeUnretainedValue()
                return engine.receive(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        // Keep down/up pairing until physical releases reach a restarted tap.
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == marker { return Unmanaged.passUnretained(event) }
        router.activeApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if type == .scrollWheel {
            let x = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2)
            let y = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
            guard x != 0, y == 0, router.configuration.enabled, !router.suspended else { return Unmanaged.passUnretained(event) }
            let input = x > 0 ? "wheel:left" : "wheel:right"
            guard let shortcut = router.configuration.shortcut(input, app: router.activeApp) else { return Unmanaged.passUnretained(event) }
            router.observed(input)
            if shortcut.keyCode == 48 && shortcut.modifiers & CGEventFlags.maskControl.rawValue != 0 {
                if tabWheel.allow(direction: x > 0 ? -1 : 1, time: ProcessInfo.processInfo.systemUptime,
                    application: router.activeApp, momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0) {
                    router.emit(shortcut)
                }
            } else if Date().timeIntervalSince(wheelTime) >= 0.1 {
                router.emit(shortcut); wheelTime = Date()
            }
            return nil
        }
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        guard number >= 2, type != .otherMouseDragged else { return Unmanaged.passUnretained(event) }
        // Cache the actual foreground app at the press, so profile selection never lags a workspace notification.
        router.activeApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let consumed = router.button("mouse:\(number)", down: type == .otherMouseDown)
        return consumed ? nil : Unmanaged.passUnretained(event)
    }
    func post(_ shortcut: Shortcut) {
        if let action = shortcut.action {
            guard let resolved = systemShortcut(action) else { error("Enable the macOS keyboard shortcut for \(shortcut.label) in System Settings."); return }
            post(resolved); return
        }
        let eventSource = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: shortcut.keyCode, keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: shortcut.modifiers)
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
        }
    }
}

struct StartupHealth {
    var accessibility: Bool
    var inputMonitoring: Bool
    var keyboardPosting: Bool
    var eventTap: Bool
    var mouseReady: Bool
    var loginEnabled: Bool
    var profilesValid = true
    var enabled = true
    var recording = false
    var sleeping = false
    var ready: Bool { accessibility && inputMonitoring && keyboardPosting && eventTap && mouseReady && loginEnabled && profilesValid && enabled && !recording && !sleeping }
    var message: String {
        if !profilesValid { return "Profiles need attention" }
        if !enabled { return "Paused" }
        if sleeping { return "Mac is sleeping" }
        if !accessibility { return "Accessibility permission needed" }
        if !inputMonitoring { return "Input Monitoring permission needed" }
        if !keyboardPosting { return "Keyboard control permission needed" }
        if !eventTap { return "Input capture is not running" }
        if recording { return "Editing shortcut · remapping paused" }
        if !mouseReady { return "Waiting for mouse setup" }
        if !loginEnabled { return "Ready · login startup is off" }
        return "Ready · permissions, mouse and login startup checked"
    }
}

func systemShortcut(_ action: String) -> Shortcut? {
    let ids = ["mission-control": "32", "app-expose": "33", "desktop-left": "79", "desktop-right": "81"]
    guard let id = ids[action] else { return nil }
    let prefs = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
    if let entry = prefs?[id] as? [String: Any] {
        guard (entry["enabled"] as? Bool) != false else { return nil }
        if let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 {
            return Shortcut(keyCode: parameters[1].uint16Value, modifiers: parameters[2].uint64Value, label: action)
        }
    }
    let defaults: [String: UInt16] = ["32": 126, "33": 125, "79": 123, "81": 124]
    return Shortcut(keyCode: defaults[id]!, modifiers: 1 << 18, label: action)
}

func deviceInventory() -> [[String: String]] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 1133] as CFDictionary)
    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    return devices.map { device in
        var result: [String: String] = [:]
        for key in [kIOHIDProductKey, kIOHIDVendorIDKey, kIOHIDProductIDKey, kIOHIDTransportKey] {
            if let value = IOHIDDeviceGetProperty(device, key as CFString) { result[key] = String(describing: value) }
        }
        return result
    }
}
