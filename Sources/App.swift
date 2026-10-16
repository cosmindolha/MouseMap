import AppKit
import SwiftUI
import Combine
import ServiceManagement
import CoreServices

final class AppState: ObservableObject {
    @Published var configuration = Configuration()
    @Published var selected = "*"
    @Published var status = "Enable permissions to start remapping"
    @Published var hidStatus = ""
    @Published var currentApp = ""
    @Published var lastInput = ""
    @Published var error = ""
    @Published var importSummary = ""
    @Published var recording: String?
    @Published var shortcutEditor: ShortcutEditorTarget?
    @Published var controls: [LogitechControl] = []
    @Published var accessibility = AXIsProcessTrusted()
    @Published var monitoring = CGPreflightListenEventAccess()
    @Published var ready = false
    let router = Router()
    lazy var engine = EventEngine(router: router)
    let logitech: Logitech
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var startupError = false
    private var takingOver = false
    private var tookOver = false
    private var sleeping = false
    private var quitting = false
    private var setupPermissions = false
    private var askedAccessibility = false
    private var askedMonitoring = false
    private var lastHealthData: Data?
    private let writesHealthReport: Bool
    private var sleepCount = 0
    private var wakeCount = 0
    private var lastWakeAt = ""

    init(logitech: Logitech = Logitech(), writesHealthReport: Bool = true) {
        self.logitech = logitech; self.writesHealthReport = writesHealthReport
        do { configuration = try Storage.load() } catch { self.error = "Could not load profiles: \(error.localizedDescription)"; startupError = true }
        router.configuration = configuration
        router.emit = { [weak self] shortcut in self?.engine.post(shortcut) }
        router.observed = { [weak self] input in DispatchQueue.main.async { self?.lastInput = Inputs.name(input) } }
        engine.error = { [weak self] in self?.error = $0 }
        logitech.changed = { [weak self] in
            guard let self else { return }
            self.controls = self.logitech.controls; self.hidStatus = self.logitech.status; self.syncHID()
        }
        logitech.button = { [weak self] input, down in
            guard let self else { return }
            self.router.activeApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            _ = self.router.button(input, down: down)
        }
        logitech.gesture = { [weak self] input in
            guard let self else { return }
            self.router.activeApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            _ = self.router.button(input, down: true); _ = self.router.button(input, down: false)
        }
        logitech.resetInputState = { [weak self] in self?.router.reset() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.activeChanged() })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.prepareForSleep()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resumeAfterSleep()
        })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        activeChanged()
    }

    var profile: Profile { configuration.profiles.first { $0.id == selected } ?? configuration.profiles[0] }
    var inputs: [String] {
        let base = ["hid:82", "hid:83", "hid:86", "hid:196", "hid:195", "hid:195:up", "hid:195:down", "hid:195:left", "hid:195:right", "wheel:left", "wheel:right"]
        let extras = Set(configuration.profiles.flatMap { Array($0.bindings.keys) }).union(controls.map { "hid:\($0.id)" }).subtracting(base)
        return base + extras.sorted()
    }
    func start(requestPermissions: Bool = false) {
        setupPermissions = requestPermissions
        refreshPermissions(force: true)
        advancePermissionSetup()
    }
    func prepareForSleep() {
        sleepCount += 1
        sleeping = true; cancelRecording(); router.suspended = true; router.reset()
        logitech.stop {}; engine.stop()
    }
    func resumeAfterSleep() {
        guard !quitting else { return }
        wakeCount += 1; lastWakeAt = ISO8601DateFormatter().string(from: Date())
        // Invalidate the pre-sleep manager even if its asynchronous stop never
        // completed while Bluetooth was suspended.
        logitech.resetForWake(); router.reset(); sleeping = false
        refreshPermissions(force: true)
    }
    func reconnectMouse() {
        guard !sleeping && !quitting else { return }
        logitech.resetForWake(); refreshPermissions(force: true)
    }
    func refreshPermissions(force: Bool = false) {
        defer { updateHealth(); advancePermissionSetup() }
        let ax = AXIsProcessTrusted(); let input = CGPreflightListenEventAccess()
        let changed = ax != accessibility || input != monitoring
        accessibility = ax; monitoring = input
        guard !sleeping && !quitting else { return }
        if !ax {
            engine.stop(); router.suspended = true
            if changed { logitech.stop {} }
            status = "Accessibility permission needed"; return
        }
        router.suspended = shortcutEditor != nil
        if !input && changed { logitech.stop {} }
        guard !startupError else { status = "Profiles need attention"; return }
        if !engine.isRunning && (force || changed) {
            status = engine.start() ? "Remapping active" : "Cannot start input capture; check Accessibility"
        }
        if configuration.enabled && engine.isRunning && input && (force || changed) { takeOver() }
        else if !input { hidStatus = "Input Monitoring permission needed for Logitech buttons" }
        if !configuration.enabled { status = "Paused" }
    }
    private func takeOver() {
        guard !takingOver else { return }
        if tookOver { logitech.start(); syncHID(); return }
        takingOver = true
        // Stop only the user's Options+ agent, reversibly, for this login session.
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/com.logi.cp-dev-mgr"]) { [weak self] code, output in
            guard let self else { return }; self.takingOver = false; self.tookOver = true
            if code != 0 && FileManager.default.fileExists(atPath: "/Library/LaunchAgents/com.logi.optionsplus.plist") && !output.contains("No such process") {
                self.tookOver = false; self.error = "Could not stop Options+: \(output)"; return
            }
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.logi.optionsplus" { app.terminate() }
            self.logitech.start(); self.syncHID()
        }
    }
    func activeChanged() {
        let app = NSWorkspace.shared.frontmostApplication
        currentApp = app?.localizedName ?? ""
        router.activeApp = app?.bundleIdentifier ?? ""
        syncHID()
    }
    func syncHID() {
        router.configuration = configuration
        logitech.configure(configuration, app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", suspended: shortcutEditor != nil || sleeping || quitting || !accessibility)
    }
    func save() {
        guard !startupError else { return }
        do { try Storage.save(configuration); syncHID() }
        catch { self.error = "Could not save profiles: \(error.localizedDescription)" }
    }
    func toggleEnabled() {
        configuration.enabled.toggle(); save()
        status = configuration.enabled ? (engine.isRunning ? "Remapping active" : "Accessibility permission needed") : "Paused"
        if configuration.enabled { refreshPermissions(force: true) }
    }
    func permissions(_ input: Bool) {
        if input { _ = CGRequestListenEventAccess() }
        else { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(input ? "Privacy_ListenEvent" : "Privacy_Accessibility")")!)
    }
    private func advancePermissionSetup() {
        guard setupPermissions else { return }
        if !accessibility {
            guard !askedAccessibility else { return }
            askedAccessibility = true; permissions(false)
        } else if !monitoring {
            guard !askedMonitoring else { return }
            askedMonitoring = true; permissions(true)
        } else { setupPermissions = false }
    }
    private func updateHealth() {
        let posting = CGPreflightPostEventAccess()
        let login = SMAppService.mainApp.status == .enabled
        let health = StartupHealth(accessibility: accessibility, inputMonitoring: monitoring, keyboardPosting: posting,
            eventTap: engine.isRunning, mouseReady: logitech.isReady, loginEnabled: login,
            profilesValid: !startupError, enabled: configuration.enabled, recording: shortcutEditor != nil, sleeping: sleeping)
        ready = health.ready
        status = health.message
        let report: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "bundlePath": Bundle.main.bundlePath,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "tabWheelPolicy": "one-per-burst-300ms",
            "hidReconnects": logitech.reconnectCount, "hidRecoveryAttempt": logitech.recoveryAttempt,
            "sleeping": sleeping, "sleepCount": sleepCount, "wakeCount": wakeCount, "lastWakeAt": lastWakeAt,
            "activationPolicy": NSApp.activationPolicy() == .accessory ? "accessory" : "regular",
            "settingsVisible": NSApp.windows.contains { $0.isVisible && $0.title == "MouseMap" },
            "shortcutEditorOpen": shortcutEditor != nil,
            "accessibility": accessibility, "inputMonitoring": monitoring, "keyboardPosting": posting,
            "eventTap": engine.isRunning, "mouseReady": logitech.isReady, "loginEnabled": login,
            "profilesValid": !startupError, "profileCount": configuration.profiles.count, "enabled": configuration.enabled,
            "ready": ready, "status": status, "mouseStatus": logitech.status]
        guard writesHealthReport else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if data != lastHealthData {
                try FileManager.default.createDirectory(at: Storage.directory, withIntermediateDirectories: true)
                try data.write(to: Storage.directory.appendingPathComponent("runtime-health.json"), options: .atomic)
                lastHealthData = data
            }
        } catch { self.error = "Could not save startup check: \(error.localizedDescription)" }
    }
    func beginEditing(_ input: String) {
        cancelEditing()
        shortcutEditor = ShortcutEditorTarget(input: input, profileID: selected, profileName: profile.name,
            shortcut: configuration.shortcut(input, app: selected))
        router.suspended = true; syncHID()
    }
    func setListening(_ listening: Bool, target: UUID) {
        guard let editor = shortcutEditor, editor.id == target else { return }
        recording = listening ? editor.input : nil
    }
    func commitEditing(_ shortcut: Shortcut, target: ShortcutEditorTarget) {
        guard shortcutEditor?.id == target.id,
              let index = configuration.profiles.firstIndex(where: { $0.id == target.profileID }) else { return }
        var updated = configuration
        updated.profiles[index].bindings[target.input] = shortcut
        updated.profiles[index].defaults.remove(target.input)
        do {
            try Storage.save(updated); configuration = updated; cancelEditing()
        } catch { self.error = "Could not save shortcut: \(error.localizedDescription)" }
    }
    func cancelEditing() {
        recording = nil; shortcutEditor = nil
        router.suspended = sleeping || quitting || !accessibility; syncHID()
    }
    func cancelRecording() {
        cancelEditing()
    }
    func shutdown(completion: @escaping () -> Void) {
        quitting = true; timer?.invalidate(); timer = nil
        cancelRecording(); router.suspended = true
        logitech.stop(completion: completion)
    }
    func set(_ input: String, shortcut: Shortcut?) {
        guard let index = configuration.profiles.firstIndex(where: { $0.id == selected }) else { return }
        configuration.profiles[index].bindings[input] = shortcut
        configuration.profiles[index].defaults.remove(input)
        save()
    }
    func native(_ input: String) {
        set(input, shortcut: nil)
        if let index = configuration.profiles.firstIndex(where: { $0.id == selected }) { configuration.profiles[index].defaults.insert(input); save() }
    }
    func addApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        if !configuration.profiles.contains(where: { $0.id == id }) {
            configuration.profiles.append(Profile(id: id, name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent)); save()
        }
        selected = id
    }
    func importLogi() {
        do {
            let result = try LogiImport.run()
            if FileManager.default.fileExists(atPath: Storage.url.path) {
                let backup = Storage.directory.appendingPathComponent("profiles-before-import-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: Storage.url, to: backup)
            }
            configuration = result.configuration; startupError = false; selected = "*"; save()
            let count = result.report["profiles"] as? Int ?? 0
            let skipped = (result.report["skipped"] as? [[String: String]])?.count ?? 0
            importSummary = "Imported \(count) profiles" + (skipped == 0 ? " · backup saved" : " · \(skipped) entries need review")
        } catch { self.error = "Import failed: \(error.localizedDescription)" }
    }
    func launchAtLogin(_ value: Bool) {
        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; objectWillChange.send() }
        catch { self.error = error.localizedDescription }
    }
    func restoreOptions() {
        configuration.enabled = false; save()
        logitech.stop { [weak self] in
            self?.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", "/Library/LaunchAgents/com.logi.optionsplus.plist"]) { _, _ in
                self?.tookOver = false; self?.status = "Paused · Options+ restored"
            }
        }
    }
    func run(_ executable: String, _ arguments: [String], completion: @escaping (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); DispatchQueue.main.async { completion(process.terminationStatus, String(data: data, encoding: .utf8) ?? "") } }
            catch { DispatchQueue.main.async { completion(-1, error.localizedDescription) } }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("MouseMap").font(.system(size: 24, weight: .semibold))
                Text("MX MASTER 3").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).tracking(2)
                Divider()
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(state.configuration.profiles) { profile in
                            Button { state.cancelRecording(); state.selected = profile.id } label: {
                                HStack { Text(profile.name).lineLimit(1); Spacer() }.padding(10)
                                    .background(state.selected == profile.id ? Color.white.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Button("Add application…") { state.addApplication() }
                Button("Import Options+ profiles") { state.importLogi() }
                if !state.importSummary.isEmpty { Text(state.importSummary).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Toggle("Open at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { state.launchAtLogin($0) })).font(.caption)
            }.padding(22).frame(width: 238).background(Color(white: 0.105))
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.profile.name).font(.system(size: 25, weight: .medium))
                        Text(state.status).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(state.configuration.enabled ? "Pause" : "Resume") { state.toggleEnabled() }
                }
                if !state.accessibility || !state.monitoring {
                    HStack {
                        if !state.accessibility { Button("Enable Accessibility") { state.permissions(false) } }
                        if !state.monitoring { Button("Enable Input Monitoring") { state.permissions(true) } }
                    }.padding(.vertical, 6)
                }
                if let target = state.shortcutEditor {
                    ShortcutEditorView(state: state, target: target).id(target.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(state.inputs, id: \.self) { input in
                                HStack(spacing: 10) {
                                    Text(Inputs.name(input)).frame(maxWidth: .infinity, alignment: .leading)
                                    Button {
                                        state.beginEditing(input)
                                    } label: {
                                        Text(state.configuration.shortcut(input, app: state.selected)?.label ?? "Native behavior")
                                            .frame(minWidth: 155).padding(.vertical, 3)
                                    }
                                    Menu {
                                        Button("Native behavior") { state.native(input) }
                                        if state.selected != "*" { Button("Use global setting") { state.set(input, shortcut: nil) } }
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
                                }.padding(.vertical, 10)
                                Divider()
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.hidStatus).font(.caption).foregroundStyle(.secondary)
                    Text("Active app: \(state.currentApp)" + (state.lastInput.isEmpty ? "" : "  ·  Last input: \(state.lastInput)")).font(.caption).foregroundStyle(.secondary)
                    Text("Thumb-wheel shortcuts also apply to horizontal scrolling from other pointing devices.").font(.caption2).foregroundStyle(.tertiary)
                }
                if !state.error.isEmpty { Text(state.error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                HStack {
                    Button("View import report") { NSWorkspace.shared.open(Storage.directory.appendingPathComponent("import-report.json")) }
                    Spacer()
                    Button("Reconnect mouse") { state.reconnectMouse() }.disabled(!state.accessibility || !state.monitoring)
                    if FileManager.default.fileExists(atPath: "/Library/LaunchAgents/com.logi.optionsplus.plist") {
                        Button("Restore Options+") { state.restoreOptions() }
                    }
                }.font(.caption)
            }.padding(28).frame(minWidth: 600)
        }.frame(minWidth: 900, minHeight: 700).background(Color(white: 0.135)).preferredColorScheme(.dark)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = AppState()
    var window: NSWindow!
    var item: NSStatusItem!
    private var statusSubscription: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let login = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        NSApp.setActivationPolicy(.accessory)
        let main = NSMenu(); let application = NSMenuItem(); main.addItem(application)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit MouseMap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); application.submenu = appMenu
        NSApp.mainMenu = main
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "MouseMap")
        statusSubscription = state.$status.sink { [weak self] text in self?.item.button?.toolTip = "MouseMap · " + text }
        let menu = NSMenu(); menu.addItem(withTitle: "MouseMap settings…", action: #selector(show), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pause / Resume", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit MouseMap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.menu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MouseMap"; window.delegate = self; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(state: state)); window.center()
        state.start(requestPermissions: CommandLine.arguments.contains("--request-permissions"))
        if (!login && !CommandLine.arguments.contains("--background")) || !state.accessibility || !state.monitoring { show() }
    }
    @objc func show() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func toggle() { state.toggleEnabled() }
    func windowWillClose(_ notification: Notification) { state.cancelRecording() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state.shutdown { DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
}
