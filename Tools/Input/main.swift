import AppKit
import CoreGraphics

// input: presses keys, types text and clicks through the HID event stream, for driving an
// app in the VM. Steps run in order:
//
//   input key cmd+f type "invoice" key down key return
//   input click 640 300 wait 200 double 640 300 rightclick 700 320 drag 600 300 900 300
//   input hold 640 300 120      a click held for 120 ms, as people click
//   input slowdrag 956 500 600 500 1200    a drag at a hand's pace, over 1200 ms
//   input scroll 640 300 -40    scrolls 40 lines at a point, negative down
//
// Keys: letters and digits, return, tab, space, delete, esc, up, down, left, right, f1-f12,
// lbracket and rbracket, with cmd, shift, opt and ctrl. Points are screen points from the top left.

let codes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "esc": 53, "f5": 96, "f6": 97,
    "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f10": 109, "f12": 111, "f4": 118, "f2": 120, "f1": 122,
    "left": 123, "right": 124, "down": 125, "up": 126, "backslash": 42, "slash": 44, "minus": 27, "equal": 24, "period": 47, "comma": 43,
    // Spelled out for the shell, which reads [ and ] as a pattern.
    "lbracket": 33, "rbracket": 30,
]

func press(_ chord: String) {
    var flags: CGEventFlags = []
    var key: CGKeyCode = 0
    for part in chord.lowercased().split(separator: "+", omittingEmptySubsequences: false) where !part.isEmpty {
        switch part {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "alt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default:
            guard let code = codes[String(part)] else { FileHandle.standardError.write(Data("unknown key \(part)\n".utf8)); exit(2) }
            key = code
        }
    }
    let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
    let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)!
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    // The event system keeps the last modifiers it saw; without letting go of them here,
    // every later click would arrive as a Command- or Shift-click.
    if !flags.isEmpty, let release = CGEvent(source: nil) {
        release.type = .flagsChanged
        release.flags = []
        release.post(tap: .cghidEventTap)
    }
    usleep(40_000)
}

/// Types text. Plain characters go as their own keys, which text fields need: they read
/// the key through the input system, not the string attached to the event.
func type(_ text: String) {
    for character in text {
        let lower = String(character).lowercased()
        if character.isASCII, codes[lower] != nil || character == " " {
            press((character.isUppercase ? "shift+" : "") + (character == " " ? "space" : lower))
            continue
        }
        let units = Array(String(character).utf16)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

func mouse(_ type: CGEventType, _ point: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    event.flags = []
    event.post(tap: .cghidEventTap)
}

func click(_ point: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
    mouse(.mouseMoved, point)
    usleep(30_000)
    for n in 1...clicks {
        mouse(button == .left ? .leftMouseDown : .rightMouseDown, point, button: button, clicks: n)
        mouse(button == .left ? .leftMouseUp : .rightMouseUp, point, button: button, clicks: n)
        usleep(20_000)
    }
    usleep(60_000)
}

var args = Array(CommandLine.arguments.dropFirst())
func next() -> String {
    guard !args.isEmpty else { FileHandle.standardError.write(Data("missing argument\n".utf8)); exit(2) }
    return args.removeFirst()
}
func point() -> CGPoint { CGPoint(x: Double(next())!, y: Double(next())!) }

while !args.isEmpty {
    switch next() {
    case "key": press(next())
    case "type": type(next())
    case "click": click(point())
    case "double": click(point(), clicks: 2)
    case "hold":
        // A click held as long as a person holds one: press, wait, release.
        let at = point(), ms = Int(next())!
        mouse(.mouseMoved, at); usleep(30_000)
        mouse(.leftMouseDown, at)
        usleep(UInt32(ms * 1000))
        mouse(.leftMouseUp, at)
        usleep(60_000)
    case "rightclick": click(point(), button: .right)
    case "move": mouse(.mouseMoved, point())
    case "scroll":
        let at = point(), lines = Int32(next())!
        mouse(.mouseMoved, at); usleep(30_000)
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        usleep(200_000)
    case "drag":
        let from = point(), to = point()
        mouse(.mouseMoved, from); usleep(30_000)
        mouse(.leftMouseDown, from); usleep(80_000)
        for step in 1...20 {
            let t = Double(step) / 20
            mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            usleep(15_000)
        }
        usleep(150_000)
        mouse(.leftMouseUp, to)
        usleep(100_000)
    case "slowdrag":
        // One step a frame, as a hand on a trackpad sends them.
        let from = point(), to = point(), steps = max(1, Int(next())! / 16)
        mouse(.mouseMoved, from); usleep(30_000)
        mouse(.leftMouseDown, from); usleep(120_000)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            usleep(16_000)
        }
        usleep(150_000)
        mouse(.leftMouseUp, to)
        usleep(100_000)
    case "wait": usleep(UInt32(Int(next())! * 1000))
    case let step:
        FileHandle.standardError.write(Data("unknown step \(step)\n".utf8))
        exit(2)
    }
}
