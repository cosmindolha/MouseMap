import AppKit
import ApplicationServices
import ServiceManagement

func printJSON(_ object: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
}

if CommandLine.arguments.contains("--diagnose") {
    printJSON(["accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess(), "devices": deviceInventory(), "profilesPath": Storage.url.path, "loginService": SMAppService.mainApp.status.rawValue] as [String: Any])
} else if CommandLine.arguments.contains("--enable-login") {
    do {
        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        printJSON(["enabled": SMAppService.mainApp.status == .enabled, "status": SMAppService.mainApp.status.rawValue])
    } catch { fputs("Login registration failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
} else if CommandLine.arguments.contains("--probe-hid") {
    let connection = Logitech()
    var finished = false
    connection.changed = {
        if connection.status == "Logitech extra buttons connected" {
            printJSON(["status": connection.status, "controls": connection.controls.map { ["id": $0.id, "rawXY": $0.rawXY, "name": Inputs.name("hid:\($0.id)")] }] as [String: Any])
            connection.stop { finished = true }
        } else if connection.status.contains("failed") || connection.status.contains("Cannot") || connection.status.contains("denied") || connection.status.contains("permission needed") {
            printJSON(["status": connection.status]); finished = true
        }
    }
    connection.start()
    let deadline = Date().addingTimeInterval(15)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    if !finished { printJSON(["status": "HID probe timed out", "detail": connection.status]); exit(1) }
} else if CommandLine.arguments.contains("--import-options") {
    do {
        let result = try LogiImport.run()
        if FileManager.default.fileExists(atPath: Storage.url.path) {
            try FileManager.default.copyItem(at: Storage.url, to: Storage.directory.appendingPathComponent("profiles-before-import-\(UUID().uuidString).json"))
        }
        try Storage.save(result.configuration)
        printJSON(result.report)
    } catch { fputs("Import failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
