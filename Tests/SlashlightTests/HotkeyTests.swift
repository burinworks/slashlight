import Foundation
import SlashlightKit
import Testing
@testable import Slashlight

@Suite("Hotkeys") @MainActor
struct HotkeyTests {
    private func binding(_ owner: String, _ action: String, _ scope: HotkeyBinding.Scope, _ key: String?) -> HotkeyBinding {
        HotkeyBinding(owner: owner, ownerTitle: owner, action: action, title: action, scope: scope,
                      defaultShortcut: nil, shortcut: key.flatMap(Shortcut.init(string:)), run: { _ in })
    }

    @Test func userKeysWinOverDefaultsAndCanBeCleared() {
        var s = Settings()
        let d = Shortcut("k", .command)
        #expect(HotkeyMap.shortcut("slashlight/actions", default: d, in: s) == d)
        s.hotkeys["slashlight/actions"] = "cmd+shift+k"
        #expect(HotkeyMap.shortcut("slashlight/actions", default: d, in: s) == Shortcut("k", [.command, .shift]))
        s.hotkeys["slashlight/actions"] = ""
        #expect(HotkeyMap.shortcut("slashlight/actions", default: d, in: s) == nil)
    }

    @Test func oldWindowSwitcherKeyCarriesOver() throws {
        let old = #"{"windowSwitcherHotkey":"cmd+opt+tab"}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(s.hotkeys["window-switcher/switch"] == "cmd+opt+tab")
        let unchanged = try JSONDecoder().decode(Settings.self, from: Data(#"{"windowSwitcherHotkey":"opt+tab"}"#.utf8))
        #expect(unchanged.hotkeys.isEmpty)
    }

    @Test func globalKeysNeedAModifier() {
        #expect(HotkeyMap.isAllowed(Shortcut("v", [.command, .option]), scope: .global))
        #expect(!HotkeyMap.isAllowed(Shortcut("v", .shift), scope: .global))
        #expect(!HotkeyMap.isAllowed(Shortcut("escape"), scope: .global))
        #expect(HotkeyMap.isAllowed(Shortcut("escape"), scope: .system))
        #expect(HotkeyMap.isAllowed(Shortcut("f5"), scope: .local))
        #expect(!HotkeyMap.isAllowed(Shortcut("a"), scope: .local))
    }

    @Test func clashesOnlyWhereBothCanFire() {
        let all = [
            binding("slashlight", "back", .system, "escape"),
            binding("clipboard", "pin", .local, "cmd+p"),
            binding("snippets", "pin", .local, "cmd+p"),
            binding("emoji", "close", .local, "escape"),
            binding("apps", "open", .global, "cmd+opt+p"),
            binding("files", "find", .local, "cmd+opt+p"),
        ]
        // Two extensions' local keys are never live together.
        #expect(HotkeyMap.conflicts(of: all[1], in: all).isEmpty)
        // A local key shadowed by Slashlight's own.
        #expect(HotkeyMap.conflicts(of: all[3], in: all).map(\.id) == ["slashlight/back"])
        // A global key is live everywhere.
        #expect(HotkeyMap.conflicts(of: all[4], in: all).map(\.id) == ["files/find"])
        // No key, no clash.
        #expect(HotkeyMap.conflicts(of: binding("x", "y", .global, nil), in: all).isEmpty)
    }

    @Test func everyAppsKeysAreOffLimits() {
        // ⌘C copies in every app: never a global key, and not a panel key either (the search field needs it).
        #expect(ReservedKeys.standardReason(Shortcut("c", .command), scope: .global) == "⌘C is Copy in every app")
        #expect(ReservedKeys.standardReason(Shortcut("c", .command), scope: .local) != nil)
        // ⌘Q quits other apps, but inside the panel it is free to use.
        #expect(ReservedKeys.standardReason(Shortcut("q", .command), scope: .global) != nil)
        #expect(ReservedKeys.standardReason(Shortcut("q", .command), scope: .local) == nil)
        #expect(ReservedKeys.standardReason(Shortcut("v", [.command, .option]), scope: .global) == nil)
        // Slashlight's own defaults don't trip over the list.
        for key in SystemHotkey.allCases where key != .settings {
            #expect(ReservedKeys.standardReason(key.defaultShortcut, scope: .system) == nil, "\(key)")
        }
    }

    @Test func macOSShortcutsAreReadWithoutCrashing() {
        // Whatever this Mac has turned on; every entry needs a key Slashlight can name.
        for (s, name) in ReservedKeys.macOS {
            #expect(!name.isEmpty)
            #expect(KeyCodes.code(for: s.key) != nil)
        }
    }

    @Test func functionKeysAndPunctuationRegister() {
        for key in ["f5", "f12", ";", "[", "\\"] { #expect(KeyCodes.code(for: key) != nil, "\(key)") }
        #expect(Shortcut(string: "ctrl+f5")?.display == "⌃F5")
    }

    @Test func manifestHotkeysAreChecked() throws {
        func ext(_ hotkeys: String) throws -> ExternalExtension {
            let json = #"{"id":"x","title":"X","triggers":[],"exec":["./x"],"hotkeys":"# + hotkeys + "}"
            return try ExternalExtension(file: JSONDecoder().decode(ExternalExtension.FileManifest.self, from: Data(json.utf8)),
                                         directory: URL(fileURLWithPath: "/tmp"))
        }
        let ok = try ext(#"[{"id":"paste","title":"Paste","scope":"global","default":"ctrl+opt+u"},{"id":"pin","title":"Pin","scope":"local","default":"f2"}]"#)
        #expect(ok.hotkeys.map(\.id) == ["paste", "pin"])
        #expect(ok.hotkeys[0].scope == .global && ok.hotkeys[0].defaultShortcut == Shortcut("u", [.control, .option]))
        #expect(throws: (any Error).self) { try ext(#"[{"id":"a","title":"A","scope":"everywhere"}]"#) }
        #expect(throws: (any Error).self) { try ext(#"[{"id":"a","title":"A","scope":"global","default":"u"}]"#) }
        #expect(throws: (any Error).self) { try ext(#"[{"id":"open","title":"A","scope":"local"}]"#) }
        #expect(throws: (any Error).self) { try ext(#"[{"id":"a","title":"A","scope":"local"},{"id":"a","title":"B","scope":"local"}]"#) }
        #expect(throws: (any Error).self) { try ext(#"[{"id":"a","title":"A","scope":"local","default":"cmd+nosuchkey"}]"#) }
        #expect(throws: (any Error).self) { try ext(#"[{"id":"a","title":"A","scope":"global","default":"cmd+c"}]"#) }
        #expect(throws: (any Error).self) { try ext(#"[{"id":"a","title":"A","scope":"local","default":"cmd+v"}]"#) }
    }
}
