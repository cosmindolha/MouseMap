import AppKit
import SwiftUI

// Name the property-wrapper type explicitly: newer SDKs also export a State
// macro, which is unavailable in a standalone swiftc build.
private typealias EditorState<Value> = SwiftUI.State<Value>

struct ShortcutEditorTarget: Identifiable {
    let id = UUID()
    let input: String
    let profileID: String
    let profileName: String
    let shortcut: Shortcut?
}

struct ShortcutKey: Identifiable {
    let code: UInt16
    let symbol: String
    let name: String
    var id: UInt16 { code }
}

enum ShortcutKeys {
    static let common: [ShortcutKey] = [
        .init(code: 48, symbol: "⇥", name: "Tab"), .init(code: 36, symbol: "↩", name: "Return"),
        .init(code: 49, symbol: "Space", name: "Space"), .init(code: 53, symbol: "⎋", name: "Escape"),
        .init(code: 51, symbol: "⌫", name: "Backspace"), .init(code: 117, symbol: "⌦", name: "Forward Delete"),
        .init(code: 123, symbol: "←", name: "Left Arrow"), .init(code: 124, symbol: "→", name: "Right Arrow"),
        .init(code: 126, symbol: "↑", name: "Up Arrow"), .init(code: 125, symbol: "↓", name: "Down Arrow"),
        .init(code: 115, symbol: "↖", name: "Home"), .init(code: 119, symbol: "↘", name: "End"),
        .init(code: 116, symbol: "⇞", name: "Page Up"), .init(code: 121, symbol: "⇟", name: "Page Down")
    ]
    static let letters: [ShortcutKey] = {
        let codes: [UInt16] = [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]
        return zip(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), codes).map { .init(code: $0.1, symbol: String($0.0), name: String($0.0)) }
    }()
    static let numbers: [ShortcutKey] = {
        let codes: [UInt16] = [29,18,19,20,21,23,22,26,28,25]
        return codes.enumerated().map { .init(code: $0.element, symbol: String($0.offset), name: String($0.offset)) }
    }()
    static let symbols: [ShortcutKey] = [
        .init(code: 33, symbol: "[", name: "Left Bracket"), .init(code: 30, symbol: "]", name: "Right Bracket"),
        .init(code: 42, symbol: "\\", name: "Backslash"), .init(code: 41, symbol: ";", name: "Semicolon"),
        .init(code: 39, symbol: "'", name: "Quote"), .init(code: 43, symbol: ",", name: "Comma"),
        .init(code: 47, symbol: ".", name: "Period"), .init(code: 44, symbol: "/", name: "Slash"),
        .init(code: 27, symbol: "-", name: "Minus"), .init(code: 24, symbol: "=", name: "Equals"),
        .init(code: 50, symbol: "`", name: "Backtick")
    ]
    static let function: [ShortcutKey] = {
        let codes: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        return codes.enumerated().map { .init(code: $0.element, symbol: "F\($0.offset + 1)", name: "F\($0.offset + 1)") }
    }()
    static let groups = ["Common", "Letters", "Numbers", "Symbols", "F-keys"]
    static func keys(in group: String) -> [ShortcutKey] {
        switch group {
        case "Letters": return letters
        case "Numbers": return numbers
        case "Symbols": return symbols
        case "F-keys": return function
        default: return common
        }
    }
    static var all: [ShortcutKey] { common + letters + numbers + symbols + function }
    static func key(_ code: UInt16) -> ShortcutKey? { all.first { $0.code == code } }
}

struct ShortcutDraft {
    static let modifiers: [(flag: UInt64, symbol: String, name: String)] = [
        (1 << 18, "⌃", "Control"), (1 << 19, "⌥", "Option"), (1 << 17, "⇧", "Shift"),
        (1 << 20, "⌘", "Command"), (1 << 23, "fn", "Function")
    ]
    static let allowedFlags: UInt64 = modifiers.reduce(0) { $0 | $1.flag }
    var keyCode: UInt16?
    var flags: UInt64 = 0
    var capturedLabel: String?

    init(shortcut: Shortcut? = nil) {
        if let shortcut, shortcut.action == nil {
            keyCode = shortcut.keyCode; flags = shortcut.modifiers & Self.allowedFlags
        }
    }
    mutating func toggle(_ flag: UInt64) { flags = (flags ^ flag) & Self.allowedFlags }
    mutating func select(_ key: ShortcutKey) { keyCode = key.code; capturedLabel = nil }
    mutating func capture(code: UInt16, modifiers: UInt64, characters: String?) {
        keyCode = code; flags = modifiers & Self.allowedFlags
        capturedLabel = ShortcutKeys.key(code)?.symbol ?? characters?.uppercased()
    }
    var shortcut: Shortcut? {
        guard let keyCode else { return nil }
        var label = ""
        for modifier in Self.modifiers where flags & modifier.flag != 0 { label += modifier.symbol }
        label += capturedLabel ?? ShortcutKeys.key(keyCode)?.symbol ?? "Key \(keyCode)"
        return Shortcut(keyCode: keyCode, modifiers: flags, label: label)
    }
    var description: String {
        var names = Self.modifiers.filter { flags & $0.flag != 0 }.map { $0.name }
        if let keyCode { names.append(ShortcutKeys.key(keyCode)?.name ?? capturedLabel ?? "Key \(keyCode)") }
        return names.joined(separator: " + ")
    }
}

// Only this focused responder records keys. Key equivalents are consumed here
// before they can invoke MouseMap menus or SwiftUI keyboard navigation.
private final class ShortcutCaptureView: NSView {
    var captured: (NSEvent) -> Void = { _ in }
    var cancelled: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { cancelled() } else { captured(event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { keyDown(with: event); return true }
    override func flagsChanged(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
}

private struct ShortcutCapture: NSViewRepresentable {
    let captured: (NSEvent) -> Void
    let cancelled: () -> Void
    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView(); view.captured = captured; view.cancelled = cancelled; return view
    }
    func updateNSView(_ view: ShortcutCaptureView, context: Context) { view.captured = captured; view.cancelled = cancelled }
}

struct ShortcutEditorView: View {
    @ObservedObject var state: AppState
    let target: ShortcutEditorTarget
    @EditorState private var draft: ShortcutDraft
    @EditorState private var group = "Common"
    @EditorState private var listening = false

    init(state: AppState, target: ShortcutEditorTarget) {
        self.state = state; self.target = target
        _draft = EditorState(initialValue: ShortcutDraft(shortcut: target.shortcut))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Inputs.name(target.input)).font(.headline)
                    Text(target.profileName).font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    Text(draft.shortcut?.label ?? "Choose a key")
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                    Text(draft.description).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 76)
                    .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Shortcut preview: " + (draft.shortcut?.label ?? "Choose a key"))
                HStack {
                    Button(listening ? "Stop recording" : "Record keyboard shortcut") {
                        listening.toggle(); state.setListening(listening, target: target.id)
                    }
                    if listening { Text("Press a combination · Esc stops").font(.caption).foregroundStyle(.secondary) }
                }
                if listening {
                    ShortcutCapture(captured: { event in
                        draft.capture(code: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue), characters: event.charactersIgnoringModifiers)
                        listening = false; state.setListening(false, target: target.id)
                    }, cancelled: {
                        listening = false; state.setListening(false, target: target.id)
                    }).frame(height: 1).accessibilityLabel("Keyboard shortcut recorder")
                }
                Text("Or hold modifiers · select as many as needed").font(.subheadline).foregroundStyle(.secondary)
                modifierButtons.disabled(listening)
                Text("Then choose one key. Previous tab: Control + Shift + Tab.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Keys", selection: $group) {
                    ForEach(ShortcutKeys.groups, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).disabled(listening)
                keyButtons.disabled(listening)
                }.padding(.bottom, 4)
            }
            HStack {
                Button("Cancel") { state.cancelEditing() }
                Spacer()
                Button("Save shortcut") {
                    if let shortcut = draft.shortcut { state.commitEditing(shortcut, target: target) }
                }.disabled(draft.shortcut == nil || listening)
            }
        }.padding(20).frame(width: 460).preferredColorScheme(.dark)
    }
    private var modifierButtons: some View {
        HStack(spacing: 8) {
            ForEach(ShortcutDraft.modifiers, id: \.flag) { modifier in
                Button { draft.toggle(modifier.flag) } label: {
                    VStack(spacing: 3) {
                        Text(modifier.symbol).font(.system(size: 20))
                        Text(modifier.name).font(.system(size: 10))
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(draft.flags & modifier.flag != 0 ? Color.white.opacity(0.2) : Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityLabel(modifier.name + " modifier")
                    .accessibilityValue(draft.flags & modifier.flag != 0 ? "On" : "Off")
            }
        }
    }
    private var keyButtons: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
            ForEach(ShortcutKeys.keys(in: group)) { key in
                Button { draft.select(key) } label: {
                    VStack(spacing: 2) {
                        Text(key.symbol).font(.system(size: 17, weight: .medium))
                        if group == "Common" { Text(key.name).font(.system(size: 9)).lineLimit(1) }
                    }.frame(maxWidth: .infinity, minHeight: 44)
                        .background(draft.keyCode == key.code ? Color.white.opacity(0.2) : Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help(key.name).accessibilityLabel(key.name + " key")
            }
        }.frame(minHeight: 124, alignment: .top)
    }
}
