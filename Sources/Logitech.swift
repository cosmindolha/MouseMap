import AppKit
import IOKit.hid

struct LogitechControl: Identifiable {
    let id: Int
    let flags: Int
    var divertible: Bool { flags & 0x20 != 0 }
    var rawXY: Bool { flags & 0x100 != 0 }
}

struct HIDRecoveryBudget {
    private(set) var attempt = 0
    mutating func nextDelay() -> TimeInterval? {
        let delays: [TimeInterval] = [0.5, 1, 2, 4, 8]
        guard attempt < delays.count else { return nil }
        defer { attempt += 1 }
        return delays[attempt]
    }
    mutating func reset() { attempt = 0 }
}

// HID++ 2.0 over IOHID: no device seizure and no persistent firmware changes.
final class Logitech {
    var changed: () -> Void = {}
    var button: (String, Bool) -> Void = { _, _ in }
    var gesture: (String) -> Void = { _ in }
    var resetInputState: () -> Void = {}
    private(set) var status = "Extra buttons not connected"
    private(set) var controls: [LogitechControl] = []
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var feature: UInt8 = 0
    private var pending: (feature: UInt8, function: UInt8, token: UUID, callback: ([UInt8]?) -> Void)?
    private var diverted: [Int: UInt8] = [:]
    private var desired: [Int: UInt8] = [:]
    private var original: [Int: UInt8] = [:]
    private var pressed = Set<Int>()
    private var motion: [Int: (Int, Int)] = [:]
    private var stopping: (() -> Void)?
    private var querying = false
    private var faulted = false
    private var generation = UUID()
    private var recovery = HIDRecoveryBudget()
    private var recoveryTask: DispatchWorkItem?
    private var recoveryEnabled = true
    private var activityRecoveryTime = -Double.infinity
    private let outputQueue = DispatchQueue(label: "MouseMap.HIDOutput")
    private let writeReport: (IOHIDDevice, [UInt8]) -> IOReturn
    private(set) var reconnectCount = 0
    var recoveryAttempt: Int { recovery.attempt }
    var isReady: Bool { device != nil && feature != 0 && !querying && !faulted && pending == nil && diverted == desired }

    init(writeReport: ((IOHIDDevice, [UInt8]) -> IOReturn)? = nil) {
        self.writeReport = writeReport ?? { device, report in
            report.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, $0.baseAddress!, $0.count) }
        }
    }

    func start() {
        guard manager == nil else { return }
        recoveryEnabled = true
        guard CGPreflightListenEventAccess() else { status = "Input Monitoring permission needed for extra buttons"; changed(); return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 1133, kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<Logitech>.fromOpaque(context!).takeUnretainedValue().attach(device)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<Logitech>.fromOpaque(context!).takeUnretainedValue().removed(device)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, 0)
        status = result == kIOReturnSuccess ? "Looking for Logitech mouse…" : "HID access denied (\(result)); enable Input Monitoring"
        changed()
    }

    private func attach(_ candidate: IOHIDDevice) {
        guard device == nil else { return }
        let product = IOHIDDeviceGetProperty(candidate, kIOHIDProductKey as CFString) as? String ?? ""
        guard product.contains("MX Master 3") else { status = "This build supports MX Master 3"; changed(); return }
        device = candidate; feature = 0; controls = []; diverted = [:]; original = [:]; pressed = []; motion = [:]; faulted = false
        generation = UUID()
        IOHIDDeviceRegisterInputReportCallback(candidate, buffer, 64, { context, result, _, _, reportID, bytes, count in
            guard result == kIOReturnSuccess else { return }
            let owner = Unmanaged<Logitech>.fromOpaque(context!).takeUnretainedValue()
            var report = Array(UnsafeBufferPointer(start: bytes, count: count))
            if report.first != UInt8(reportID) { report.insert(UInt8(reportID), at: 0) }
            owner.receive(report)
        }, Unmanaged.passUnretained(self).toOpaque())
        querying = true
        resetInputState()
        status = "Reading Logitech controls…"; changed()
        request(0, 0, [0x1b, 0x04]) { reply in
            guard let reply, reply.count >= 5, reply[4] != 0 else { self.failed("HID++ discovery failed; wake the mouse and reconnect"); return }
            self.feature = reply[4]
            self.request(self.feature, 0, []) { reply in
                guard let reply, reply.count >= 5 else { self.failed("Cannot read Logitech button count"); return }
                self.readControl(0, count: Int(reply[4]))
            }
        }
    }

    private func readControl(_ index: Int, count: Int) {
        guard index < count else {
            querying = false; status = "Logitech extra buttons connected"; changed(); reconcile(); return
        }
        request(feature, 0x10, [UInt8(index)]) { reply in
            guard let r = reply, r.count >= 13 else { self.failed("Cannot read Logitech control \(index)"); return }
            let control = LogitechControl(id: Int(r[4]) << 8 | Int(r[5]), flags: Int(r[8]) | Int(r[12]) << 8)
            if control.divertible {
                self.controls.append(control)
                self.request(self.feature, 0x20, [UInt8(control.id >> 8), UInt8(control.id & 255)]) { reply in
                    guard let reply, reply.count > 6 else { self.failed("Cannot read control reporting state"); return }
                    // Options+ has been stopped. Its temporary diversion is stale; native behavior is the restoration target.
                    self.original[control.id] = 0
                    let flags = reply[6] & 0x11
                    if flags != 0 { self.diverted[control.id] = flags }
                    self.readControl(index + 1, count: count)
                }
            } else { self.readControl(index + 1, count: count) }
        }
    }

    func configure(_ configuration: Configuration, app: String, suspended: Bool) {
        // Workspace activation notifications can arrive while Quit is restoring
        // the device. They must not re-divert controls and keep shutdown alive.
        guard stopping == nil else { return }
        var targets: [Int: UInt8] = [:]
        if configuration.enabled && !suspended {
            for control in controls where control.divertible {
                let input = "hid:\(control.id)"
                let directions = ["up", "down", "left", "right"]
                let hasGesture = directions.contains { configuration.shortcut(input + ":" + $0, app: app) != nil }
                if hasGesture && !control.rawXY { continue }
                if configuration.shortcut(input, app: app) != nil || hasGesture { targets[control.id] = hasGesture ? 0x11 : 0x01 }
            }
        }
        desired = targets
        reconcile()
    }

    private func reconcile() {
        guard device != nil, feature != 0, !querying, pending == nil, !faulted else { return }
        guard let cid = Set(diverted.keys).union(desired.keys).sorted().first(where: { diverted[$0] != desired[$0] && !pressed.contains($0) }) else {
            if let done = stopping, diverted.isEmpty { stopping = nil; close(); done() }
            else if isReady { recovery.reset() }
            return
        }
        if original[cid] == nil {
            request(feature, 0x20, [UInt8(cid >> 8), UInt8(cid & 255)]) { reply in
                guard let reply, reply.count > 6 else { self.failed("Cannot read button \(cid) reporting state"); return }
                self.original[cid] = reply[6] & 0x11
                self.reconcile()
            }
            return
        }
        let target = desired[cid]
        let flags = target ?? original[cid] ?? 0
        // Valid bits only for temporary diversion + rawXY. Never alter persistent diversion or CID mapping.
        let valid: UInt8 = controls.first(where: { $0.id == cid })?.rawXY == true ? 0x22 : 0x02
        request(feature, 0x30, [UInt8(cid >> 8), UInt8(cid & 255), flags | valid, 0, 0]) { reply in
            guard let reply, reply.count > 6, Int(reply[4]) << 8 | Int(reply[5]) == cid else { self.failed("Cannot configure button \(cid)"); return }
            self.request(self.feature, 0x20, [UInt8(cid >> 8), UInt8(cid & 255)]) { readback in
                guard let readback, readback.count > 6, Int(readback[4]) << 8 | Int(readback[5]) == cid,
                      readback[6] & 0x11 == flags & 0x11 else { self.failed("Button \(cid) reporting verification failed"); return }
                if let target { self.diverted[cid] = target } else { self.diverted.removeValue(forKey: cid) }
                self.reconcile()
            }
        }
    }

    private func request(_ feature: UInt8, _ function: UInt8, _ parameters: [UInt8], callback: @escaping ([UInt8]?) -> Void) {
        guard let device, pending == nil else { callback(nil); return }
        let token = UUID(); let generation = self.generation
        pending = (feature, function, token, callback)
        var report: [UInt8] = [0x11, 0xff, feature, function | 0x0d] + parameters
        report += Array(repeating: 0, count: max(0, 20 - report.count))
        // IOHID SetReport can block; keep it off the event-tap run loop.
        outputQueue.async {
            let result = self.writeReport(device, report)
            DispatchQueue.main.async {
                guard self.generation == generation, self.pending?.token == token else { return }
                if result != kIOReturnSuccess { self.complete(nil) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard self.generation == generation, self.pending?.token == token else { return }
            self.complete(nil)
        }
    }
    private func complete(_ reply: [UInt8]?) { let callback = pending?.callback; pending = nil; callback?(reply) }

    private func receive(_ r: [UInt8]) {
        if r.first == 2, faulted, recoveryEnabled, recoveryTask == nil,
           ProcessInfo.processInfo.systemUptime - activityRecoveryTime >= 10 {
            // Fresh physical mouse activity is a new opportunity after the
            // bounded startup/wake retries have been exhausted.
            activityRecoveryTime = ProcessInfo.processInfo.systemUptime
            recovery.reset(); scheduleRecovery()
        }
        guard r.count >= 4, r[0] == 0x11 else { return }
        if let pending, r[2] == pending.feature, r[3] == pending.function | 0x0d { complete(r); return }
        if let pending, r[2] == 0xff, r.count >= 7, r[3] == pending.feature, r[4] == pending.function | 0x0d { complete(nil); return }
        guard feature != 0, r[2] == feature, r[3] & 0x0f == 0 else { return }
        if r[3] == 0 {
            let now = Self.pressedControls(r)
            for cid in now.subtracting(pressed) {
                if diverted[cid] == 0x11 { motion[cid] = (0, 0) }
                else { button("hid:\(cid)", true) }
            }
            for cid in pressed.subtracting(now) {
                if let xy = motion.removeValue(forKey: cid) { gesture(Self.gestureInput(cid, x: xy.0, y: xy.1)) }
                else { button("hid:\(cid)", false) }
            }
            pressed = now
            reconcile()
        } else if r[3] == 0x10, r.count >= 8 {
            let dx = Int(Int16(bitPattern: UInt16(r[4]) << 8 | UInt16(r[5])))
            let dy = Int(Int16(bitPattern: UInt16(r[6]) << 8 | UInt16(r[7])))
            for cid in Array(motion.keys) { let xy = motion[cid]!; motion[cid] = (xy.0 + dx, xy.1 + dy) }
        }
    }
    static func pressedControls(_ report: [UInt8]) -> Set<Int> {
        guard report.count >= 12 else { return [] }
        return Set(stride(from: 4, to: 12, by: 2).map { Int(report[$0]) << 8 | Int(report[$0 + 1]) }.filter { $0 != 0 })
    }
    static func gestureInput(_ cid: Int, x: Int, y: Int) -> String {
        guard max(abs(x), abs(y)) >= 50 else { return "hid:\(cid)" }
        return "hid:\(cid):" + (abs(x) > abs(y) ? (x > 0 ? "right" : "left") : (y > 0 ? "down" : "up"))
    }
    private func failed(_ message: String) {
        querying = false; faulted = true; status = message; changed()
        if let done = stopping { close(); done() }
        else { scheduleRecovery() }
    }
    private func scheduleRecovery() {
        guard recoveryEnabled, stopping == nil, recoveryTask == nil,
              let delay = recovery.nextDelay() else { return }
        status += " · reconnecting (\(recovery.attempt)/5)"
        changed()
        let recoveryGeneration = generation
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.recoveryEnabled, self.generation == recoveryGeneration else { return }
            self.recoveryTask = nil
            self.close(); self.reconnectCount += 1; self.start()
        }
        recoveryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    func resetForWake() {
        recoveryEnabled = false; recoveryTask?.cancel(); recoveryTask = nil
        recovery.reset(); close(); reconnectCount += 1
        status = "Waiting for mouse to reconnect"; changed()
    }
    private func removed(_ removed: IOHIDDevice) {
        guard device == removed else { return }
        generation = UUID(); device = nil; pending = nil; feature = 0; controls = []; diverted = [:]; original = [:]; pressed = []; motion = [:]
        recoveryTask?.cancel(); recoveryTask = nil; recovery.reset(); faulted = false; querying = false
        resetInputState()
        let done = stopping; stopping = nil
        status = "Mouse disconnected"; changed()
        if let done { close(); done() }
    }
    func stop(completion: @escaping () -> Void) {
        recoveryEnabled = false; recoveryTask?.cancel(); recoveryTask = nil
        desired = [:]
        guard device != nil, feature != 0, !diverted.isEmpty else { close(); completion(); return }
        // Release handling remains active while restoring temporary reporting modes.
        stopping = completion; faulted = false; reconcile()
        let stopGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == stopGeneration, let done = self.stopping else { return }
            self.close(); done()
        }
    }
    private func close() {
        generation = UUID(); pending = nil
        let oldDevice = device; let oldManager = manager
        device = nil; manager = nil
        if let oldDevice { IOHIDDeviceRegisterInputReportCallback(oldDevice, buffer, 64, nil, nil) }
        if let manager = oldManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        device = nil; manager = nil; feature = 0; controls = []; diverted = [:]; original = [:]; pressed = []; motion = [:]
        desired = [:]; stopping = nil; querying = false; faulted = false
        resetInputState()
    }
}
