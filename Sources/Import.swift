import Foundation
import AppKit
import SQLite3

struct ImportResult {
    var configuration: Configuration
    var report: [String: Any]
}

enum LogiImport {
    static let database = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LogiOptionsPlus/settings.db")
    static func read() throws -> (Data, OpaquePointer) {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw failure("Cannot read Options+ settings.db")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "SELECT file FROM data ORDER BY _id DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else { sqlite3_close(connection); throw failure("Unknown Options+ database format") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { sqlite3_close(connection); throw failure("No Options+ settings found") }
        return (Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))), connection)
    }
    static func failure(_ text: String) -> Error { NSError(domain: "MouseMap.Import", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    static func run() throws -> ImportResult {
        let (data, connection) = try read(); defer { sqlite3_close(connection) }
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = Storage.directory.appendingPathComponent("Imports/\(date)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // SQLite backup includes the live WAL, unlike copying settings.db alone.
        var backupConnection: OpaquePointer?
        guard sqlite3_open(destination.appendingPathComponent("options-settings.db").path, &backupConnection) == SQLITE_OK, let backupConnection else { throw failure("Could not create Options+ backup") }
        let backup = sqlite3_backup_init(backupConnection, "main", connection, "main")
        guard let backup else { sqlite3_close(backupConnection); throw failure("Could not snapshot Options+ settings") }
        let backupStatus = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup); sqlite3_close(backupConnection)
        guard backupStatus == SQLITE_DONE else { throw failure("Options+ backup failed: \(backupStatus)") }
        let result = try convert(data)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.configuration).write(to: destination.appendingPathComponent("converted-profiles.json"), options: .atomic)
        var report = result.report; report["backup"] = destination.path
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: Storage.directory.appendingPathComponent("import-report.json"), options: .atomic)
        return ImportResult(configuration: result.configuration, report: report)
    }

    static func convert(_ data: Data) throws -> ImportResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appList = (root["applications"] as? [String: Any])?["applications"] as? [[String: Any]] else { throw failure("Unknown Options+ profile format") }
        var apps: [String: [String: Any]] = [:]
        for app in appList { if let id = app["applicationId"] as? String { apps[id] = app } }
        var config = Configuration(); config.profiles = []
        var imported = 0; var skipped: [[String: String]] = []; var duplicates: [String] = []
        let keys = (root["profile_keys"] as? [String] ?? root.keys.filter { $0.hasPrefix("profile-") }.sorted())
        for rawKey in keys {
            let key = rawKey.hasPrefix("profile-") ? rawKey : "profile-" + rawKey
            guard let source = root[key] as? [String: Any], let appID = source["applicationId"] as? String,
                  let app = apps[appID], let assignments = source["assignments"] as? [[String: Any]] else { continue }
            let isGlobal = app["name"] as? String == "APPLICATION_NAME_DESKTOP"
            let name = isGlobal ? "All applications" : (app["name"] as? String ?? appID)
            let path = app["applicationPath"] as? String
            let bundle = isGlobal ? "*" : ((app["bundleId"] as? String) ?? path.flatMap { Bundle(path: $0)?.bundleIdentifier })
            guard let bundle else { skipped.append(["profile": name, "reason": "Cannot resolve application bundle ID", "path": path ?? ""]); continue }
            var profile = Profile(id: bundle, name: name)
            for assignment in assignments {
                guard let slot = assignment["slotId"] as? String, slot.hasPrefix("mx-master-3-6b023_"), var card = assignment["card"] as? [String: Any] else { continue }
                if let selected = card["selectedNestedCard"] as? String, let nested = card["nestedCards"] as? [String: [String: Any]], let chosen = nested[selected] { card = chosen }
                let suffix = String(slot.dropFirst("mx-master-3-6b023_".count))
                let input: String
                if suffix.hasPrefix("c"), let cid = Int(suffix.dropFirst()) { input = "hid:\(cid)" }
                else if suffix == "thumb_wheel_adapter" { input = "wheel" }
                else { continue } // pointer, scrolling and keyboard hardware settings are preserved in the backup
                let nested = card["nestedCards"] as? [String: [String: Any]]
                if let nested, card["attribute"] as? String == "ADAPTER_4WAYS" || input == "wheel" {
                    for (direction, child) in nested {
                        let target = input == "wheel" ? "wheel:\(direction)" : (direction == "click" ? input : input + ":" + direction)
                        if let value = shortcut(child) { profile.bindings[target] = value; imported += 1 }
                        else { skipped.append(["profile": name, "input": target, "reason": child["name"] as? String ?? "Unknown gesture action"]) }
                    }
                } else if let value = shortcut(card) { profile.bindings[input] = value; imported += 1 }
                else if nativeMouse(card, input: input) || card["name"] as? String == "ASSIGNMENT_NAME_HORIZONTAL_SCROLL" {
                    if input == "wheel" { profile.defaults.formUnion(["wheel:left", "wheel:right"]) } else { profile.defaults.insert(input) }
                } else { skipped.append(["profile": name, "input": input, "reason": card["name"] as? String ?? "Unknown action"]) }
            }
            if let existing = config.profiles.firstIndex(where: { $0.id == bundle }) {
                // An installed application's explicit bundle ID wins over a stale path entry.
                if app["bundleId"] != nil { config.profiles[existing] = profile }
                duplicates.append(name)
            } else { config.profiles.append(profile) }
        }
        if !config.profiles.contains(where: { $0.id == "*" }) { config.profiles.insert(Profile(id: "*", name: "All applications"), at: 0) }
        config.profiles.sort { $0.id == "*" || ($1.id != "*" && $0.name < $1.name) }
        return ImportResult(configuration: config, report: ["profiles": config.profiles.count, "convertedAssignments": config.profiles.reduce(0) { $0 + $1.bindings.count }, "sourceAssignmentsConverted": imported, "skipped": skipped, "mergedDuplicateProfiles": duplicates])
    }

    static func shortcut(_ card: [String: Any]) -> Shortcut? {
        guard let macro = card["macro"] as? [String: Any] else { return nil }
        if let key = macro["keystroke"] as? [String: Any], let usage = key["code"] as? Int, let code = keyCodes[usage] {
            var mods: UInt64 = 0
            for modifier in key["modifiers"] as? [Int] ?? [] {
                switch modifier {
                case 224, 228: mods |= 1 << 18
                case 225, 229: mods |= 1 << 17
                case 226, 230: mods |= 1 << 19
                case 227, 231: mods |= 1 << 20
                default: break
                }
            }
            let name = key["displayCharacter"] as? String ?? String((key["virtualKeyId"] as? String ?? "Key").replacingOccurrences(of: "VK_", with: ""))
            let prefix = [(18, "⌃"), (19, "⌥"), (17, "⇧"), (20, "⌘")].filter { mods & (1 << $0.0) != 0 }.map { $0.1 }.joined()
            return Shortcut(keyCode: code, modifiers: mods, label: prefix + name)
        }
        let action = ((macro["quickLaunch"] ?? macro["system"]) as? [String: Any])?["action"] as? String
        let known = ["MISSION_CONTROL": ("mission-control", "Mission Control"), "APP_EXPOSE": ("app-expose", "App Exposé"), "SWITCH_BETWEEN_DESKTOPS_LEFT": ("desktop-left", "Previous desktop"), "SWITCH_BETWEEN_DESKTOPS_RIGHT": ("desktop-right", "Next desktop")]
        if let action, let pair = known[action] { return Shortcut(keyCode: 0, modifiers: 0, label: pair.1, action: pair.0) }
        return nil
    }

    static func nativeMouse(_ card: [String: Any], input: String) -> Bool {
        guard let macro = card["macro"] as? [String: Any], macro["type"] as? String == "MOUSE",
              let mouse = macro["mouse"] as? [String: Any], let usage = mouse["hidUsage"] as? Int else { return false }
        return ["hid:82": 3, "hid:83": 4, "hid:86": 5][input] == usage
    }

    // USB HID keyboard usage IDs are not macOS virtual keycodes.
    static let keyCodes: [Int: UInt16] = [4:0, 5:11, 6:8, 7:2, 8:14, 9:3, 10:5, 11:4, 12:34, 13:38, 14:40, 15:37, 16:46, 17:45, 18:31, 19:35, 20:12, 21:15, 22:1, 23:17, 24:32, 25:9, 26:13, 27:7, 28:16, 29:6, 30:18, 31:19, 32:20, 33:21, 34:23, 35:22, 36:26, 37:28, 38:25, 39:29, 40:36, 41:53, 42:51, 43:48, 44:49, 45:27, 46:24, 47:33, 48:30, 49:42, 51:41, 52:39, 53:50, 54:43, 55:47, 56:44, 57:57, 58:122, 59:120, 60:99, 61:118, 62:96, 63:97, 64:98, 65:100, 66:101, 67:109, 68:103, 69:111, 73:114, 74:115, 75:116, 76:117, 77:119, 78:121, 79:124, 80:123, 81:125, 82:126]
}
