import Carbon.HIToolbox
import CoreGraphics
import PlanetsCore

/// Maps key names from the config to the key codes the keyboard sends.
///
/// Letters, digits and punctuation are looked up in the active keyboard layout, so
/// "mod+h" is the key that types h, wherever that key sits. Keys the layout doesn't
/// produce unshifted (digits on AZERTY, for one) fall back to their US-layout position.
@MainActor
enum KeyCodes {
    static let fixed: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]

    static let ansi: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29,
        "rightbracket": 30, "o": 31, "u": 32, "leftbracket": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "quote": 39, "k": 40, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45,
        "m": 46, "period": 47, "grave": 50, "plus": 24,
    ]

    static let punctuation: [Character: String] = [
        "-": "minus", "=": "equal", ",": "comma", ".": "period", "/": "slash", ";": "semicolon",
        "'": "quote", "`": "grave", "[": "leftbracket", "]": "rightbracket", "\\": "backslash",
    ]

    static func currentMap() -> [String: CGKeyCode] {
        var map = fixed
        if let layout = layoutData() {
            CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { pointer in
                for code in 0..<UInt16(128) where !fixed.values.contains(CGKeyCode(code)) {
                    var deadKeyState: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let status = UCKeyTranslate(
                        pointer, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
                    )
                    guard status == noErr, length == 1 else { continue }
                    let text = String(utf16CodeUnits: chars, count: length).lowercased()
                    guard let char = text.first else { continue }
                    let name = char.isLetter || char.isNumber ? text : punctuation[char]
                    // Keypad keys also type digits; the first match is the main row, keep it.
                    if let name, map[name] == nil { map[name] = CGKeyCode(code) }
                }
            }
        }
        for (name, code) in ansi where map[name] == nil { map[name] = code }
        return map
    }

    private static func layoutData() -> CFData? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }
}
