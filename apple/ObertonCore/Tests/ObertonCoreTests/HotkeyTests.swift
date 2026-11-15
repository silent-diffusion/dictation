import Testing
@testable import ObertonCore

// Shortcuts as the settings store them (Windows' HotkeyManager.TryParse and Format), read for the Mac.

@Suite struct HotkeyTests {
    @Test func theDefaultsParse() throws {
        let toggle = try #require(Hotkey(AppSettings.defaultHotkey))
        #expect(toggle.modifiers == [.control])
        #expect(toggle.key == "D")
        #expect(toggle.keyCode == 0x02) // kVK_ANSI_D
        #expect(Hotkey(AppSettings.defaultCycleProfileHotkey)?.modifiers == [.control, .option])
        #expect(Hotkey(AppSettings.defaultSpeakHotkey)?.keyCode == 0x31) // kVK_Space
    }

    @Test func windowsAndMacNamesMeanTheSameKeys() {
        #expect(Hotkey("Control+Option+Command+d") == Hotkey("ctrl + alt + cmd + D"))
        #expect(Hotkey("Win+K")?.modifiers == [.command])
        #expect(Hotkey("Ctrl+Enter")?.key == "Return")
        #expect(Hotkey("Ctrl+Back")?.key == "Back")
        #expect(Hotkey("Ctrl+Backspace")?.keyCode == 0x33) // kVK_Delete, the Mac's backspace
        #expect(Hotkey("Ctrl+Delete")?.keyCode == 0x75)    // kVK_ForwardDelete, as WPF's Delete
    }

    @Test func writesWPFKeyNamesAsWindowsStoresThem() {
        // HotkeyManager.Format: key.ToString() gives "D1", "OemMinus", "Back"…
        #expect(Hotkey(modifiers: [.control], key: Hotkey.keyName(forKeyCode: 0x12)!)?.text == "Ctrl+D1")
        #expect(Hotkey(modifiers: [.control], key: Hotkey.keyName(forKeyCode: 0x1B)!)?.text == "Ctrl+OemMinus")
        #expect(Hotkey(modifiers: [.control], key: Hotkey.keyName(forKeyCode: 0x2B)!)?.text == "Ctrl+OemComma")
        #expect(Hotkey(modifiers: [.control], key: Hotkey.keyName(forKeyCode: 0x33)!)?.text == "Ctrl+Back")
        #expect(Hotkey(modifiers: [.control], key: Hotkey.keyName(forKeyCode: 0x52)!)?.text == "Ctrl+NumPad0")
    }

    @Test func readsWhatEarlierMacVersionsStored() {
        #expect(Hotkey("Ctrl+1")?.text == "Ctrl+D1")
        #expect(Hotkey("Ctrl+-")?.text == "Ctrl+OemMinus")
        #expect(Hotkey("Ctrl+,")?.text == "Ctrl+OemComma")
        #expect(Hotkey("Ctrl+=")?.text == "Ctrl+OemPlus")
        #expect(Hotkey("Ctrl++")?.text == "Ctrl+OemPlus")
        #expect(Hotkey("Ctrl+Oem2")?.text == "Ctrl+OemQuestion")
        #expect(Hotkey.same("Ctrl+1", "ctrl+d1"))
    }

    @Test func carbonModifierBits() {
        #expect(Hotkey("Ctrl+Space")?.carbonModifiers == 0x1000)          // controlKey
        #expect(Hotkey("Ctrl+Alt+Shift+Cmd+D")?.carbonModifiers == 0x1B00)
    }

    @Test func formatsInTheWindowsOrder() {
        #expect(Hotkey(modifiers: [.command, .shift, .option, .control], key: "d")?.text == "Ctrl+Alt+Shift+Cmd+D")
        #expect(Hotkey("space+ctrl")?.text == "Ctrl+Space")
        #expect(Hotkey("f9")?.text == "F9")
    }

    @Test func roundTripsEveryKey() {
        for (name, code) in Hotkey.keys {
            let h = Hotkey(modifiers: [.control], key: name)
            #expect(h != nil && Hotkey(h!.text) == h, "\(name)")
            #expect(Hotkey.keyName(forKeyCode: UInt16(code)) == name)
        }
        #expect(Set(Hotkey.keys.map(\.code)).count == Hotkey.keys.count)
    }

    @Test func rejectsWhatIsNotAShortcut() {
        #expect(Hotkey("") == nil)
        #expect(Hotkey("Ctrl") == nil)
        #expect(Hotkey("Ctrl+D+E")?.text == "Ctrl+E") // the last key counts, as on Windows
        #expect(Hotkey("Ctrl+Banana") == nil)
        #expect(Hotkey("Ctrl+Banana+D") == nil)
        #expect(Hotkey.keyName(forKeyCode: 0x3B) == nil) // kVK_Control on its own
    }

    @Test func needsAModifierUnlessItIsAnFKey() {
        #expect(Hotkey("D")?.isAllowed == false)
        #expect(Hotkey("Space")?.isAllowed == false)
        #expect(Hotkey("F9")?.isAllowed == true)
        #expect(Hotkey("Shift+D")?.isAllowed == true)
        #expect(Hotkey("Alt+D")?.isOptionOnly == true)
        #expect(Hotkey("Alt+Shift+D")?.isOptionOnly == true)
        #expect(Hotkey("Ctrl+Alt+D")?.isOptionOnly == false)
    }

    @Test func sameComparesCombinationsNotSpelling() {
        #expect(Hotkey.same("ctrl+d", "Ctrl+D"))
        #expect(Hotkey.same("Alt+Ctrl+D", "Ctrl+Alt+D"))
        #expect(!Hotkey.same("Ctrl+D", "Ctrl+Alt+D"))
        #expect(!Hotkey.same("", ""))
    }
}
