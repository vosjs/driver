// Acting on the app: the pointer and the keyboard, through the system's own input path.
//
// A scripted take does what a hand does. Every event here is posted where a mouse's or a
// keyboard's would enter the system, so the app sees ordinary input, the real pointer moves,
// and the pointer's track is sampled exactly as a person's is. It needs Accessibility, and it
// takes the foreground: the app is brought forward and nobody else touches the machine while
// the take runs.

import AppKit
import CoreGraphics
import Foundation

struct InputError: Error, LocalizedError {
  let code: String
  let message: String
  var errorDescription: String? { message }
}

let inputSource = CGEventSource(stateID: .hidSystemState)

/// Where the pointer is, in global points.
func pointerLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func postMouse(
  _ type: CGEventType, _ p: CGPoint, clicks: Int = 1, button: CGMouseButton = .left, flags: CGEventFlags = []
) {
  guard let e = CGEvent(mouseEventSource: inputSource, mouseType: type, mouseCursorPosition: p, mouseButton: button)
  else { return }
  e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
  // Always said, even when it is none: an event that does not say takes whatever the
  // system last heard, and a click that inherits Control is a context menu.
  e.flags = flags
  e.post(tap: .cghidEventTap)
}

/// The modifier keys, in the order a hand puts them down: where each is on the keyboard.
let MODIFIER_KEYS: [(CGEventFlags, CGKeyCode)] = [
  (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55),
]

/// Puts modifier keys down, as key events of their own: the system keeps a table of which
/// are held, and an event that only CLAIMS a modifier leaves that table saying it still is.
func holdModifiers(_ flags: CGEventFlags) {
  var held: CGEventFlags = []
  for (flag, code) in MODIFIER_KEYS where flags.contains(flag) {
    held.insert(flag)
    guard let e = CGEvent(keyboardEventSource: inputSource, virtualKey: code, keyDown: true) else { continue }
    e.flags = held
    e.post(tap: .cghidEventTap)
    usleep(12_000)
  }
}

/// Lets them go, last down first, until none is held. Every hold is followed by this, so
/// nothing a script pressed is still down when the script, or the take, ends.
func releaseModifiers(_ flags: CGEventFlags) {
  var held = flags
  for (flag, code) in MODIFIER_KEYS.reversed() where flags.contains(flag) {
    held.remove(flag)
    guard let e = CGEvent(keyboardEventSource: inputSource, virtualKey: code, keyDown: false) else { continue }
    e.flags = held
    e.post(tap: .cghidEventTap)
    usleep(12_000)
  }
}

/// How long the pointer takes to travel a distance: a reach across the window is slower than a
/// nudge, within bounds a person's hand keeps.
func travelMs(_ from: CGPoint, _ to: CGPoint) -> Double {
  let distance = hypot(to.x - from.x, to.y - from.y)
  return min(900, max(220, 180 + distance * 0.9))
}

/// Moves the pointer along a straight line, eased at both ends, on the clock: where it is at
/// any moment depends on the time alone, not on how many steps were taken.
func glide(to target: CGPoint, ms: Double? = nil, dragging: Bool = false, flags: CGEventFlags = []) {
  let from = pointerLocation()
  let duration = ms ?? travelMs(from, target)
  guard duration > 0, hypot(target.x - from.x, target.y - from.y) >= 0.5 else {
    postMouse(dragging ? .leftMouseDragged : .mouseMoved, target, flags: flags)
    return
  }
  let start = CACurrentMediaTime()
  while true {
    let k = min(1, (CACurrentMediaTime() - start) * 1000 / duration)
    let eased = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
    postMouse(
      dragging ? .leftMouseDragged : .mouseMoved,
      CGPoint(x: from.x + (target.x - from.x) * eased, y: from.y + (target.y - from.y) * eased), flags: flags)
    if k >= 1 { break }
    usleep(8000)
  }
}

/// A press and its release, where the pointer is.
func press(at p: CGPoint, count: Int = 1, right: Bool = false, flags: CGEventFlags = []) {
  let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
  let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
  let button: CGMouseButton = right ? .right : .left
  for n in 1...max(1, count) {
    postMouse(down, p, clicks: n, button: button, flags: flags)
    usleep(70_000)
    postMouse(up, p, clicks: n, button: button, flags: flags)
    if n < count { usleep(90_000) }
  }
}

/// Types text as a person does, a character at a time. Each character is posted as itself, not
/// as a key of some layout, so what arrives is what the script says on any keyboard.
///
/// `stillThere` is asked before every character. When it says no, typing stops there and
/// this returns false: what a script types must never land in another app.
func typeText(_ text: String, delayMs: Double, stillThere: () -> Bool = { true }) -> Bool {
  for character in text {
    guard stillThere() else { return false }
    // A new line and a tab are keys, not characters: an app acts on Return, it does not insert it.
    if let code: CGKeyCode = character == "\n" ? 36 : character == "\t" ? 48 : nil {
      for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: inputSource, virtualKey: code, keyDown: down) else { continue }
        e.flags = []
        e.post(tap: .cghidEventTap)
        if down { usleep(18_000) }
      }
      usleep(UInt32(max(0, delayMs) * 1000))
      continue
    }
    let units = Array(String(character).utf16)
    for down in [true, false] {
      guard let e = CGEvent(keyboardEventSource: inputSource, virtualKey: 0, keyDown: down) else { continue }
      units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
      e.flags = []  // a character is itself: never somebody's Command or Control
      e.post(tap: .cghidEventTap)
      if down { usleep(18_000) }
    }
    usleep(UInt32(max(0, delayMs) * 1000))
  }
  return true
}

/// Keys a script names, by where they are on the keyboard.
let KEY_CODES: [String: CGKeyCode] = [
  "enter": 36, "return": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 117, "escape": 53, "esc": 53,
  "arrowleft": 123, "arrowright": 124, "arrowdown": 125, "arrowup": 126, "left": 123, "right": 124, "down": 125,
  "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
  "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
  "f11": 103, "f12": 111,
  "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46,
  "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
  "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
  "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
]

let MODIFIERS: [String: CGEventFlags] = [
  "meta": .maskCommand, "cmd": .maskCommand, "command": .maskCommand, "control": .maskControl, "ctrl": .maskControl,
  "alt": .maskAlternate, "option": .maskAlternate, "shift": .maskShift,
]

/// The modifiers a click or a drag is made with: a list of their names.
func modifierFlags(_ value: Any?) throws -> CGEventFlags {
  guard let value else { return [] }
  guard let names = value as? [String] else {
    throw InputError(code: "bad-request", message: "modifiers is a list of names: Meta, Control, Alt, Shift.")
  }
  var flags: CGEventFlags = []
  for name in names {
    guard let m = MODIFIERS[name.lowercased()] else {
      throw InputError(code: "bad-request", message: "\"\(name)\" is not a modifier. One of: Meta, Control, Alt, Shift.")
    }
    flags.insert(m)
  }
  return flags
}

/// Presses a chord: `Enter`, `Meta+S`, `Shift+Tab`, `Meta+Shift+P`.
func pressKeys(_ chord: String) throws {
  var flags: CGEventFlags = []
  var key: CGKeyCode?
  for part in chord.split(separator: "+", omittingEmptySubsequences: false).map({ $0.lowercased() }) {
    if let m = MODIFIERS[part] {
      flags.insert(m)
    } else if let k = KEY_CODES[part], key == nil {
      key = k
    } else {
      throw InputError(code: "bad-request", message: "\"\(chord)\" is not a key this knows: a chord is modifiers and one key, like Meta+S or Enter.")
    }
  }
  guard let code = key else {
    throw InputError(code: "bad-request", message: "\"\(chord)\" names no key, only modifiers.")
  }
  holdModifiers(flags)
  defer { releaseModifiers(flags) }
  for down in [true, false] {
    guard let e = CGEvent(keyboardEventSource: inputSource, virtualKey: code, keyDown: down) else { continue }
    e.flags = flags
    e.post(tap: .cghidEventTap)
    if down { usleep(40_000) }
  }
}

/// Turns the wheel where the pointer is, in points, over a few steps so the app scrolls and
/// does not jump. Positive `dy` moves the content up, as a page scrolls down.
func scroll(dy: Double, dx: Double, ms: Double) {
  let steps = max(1, Int(ms / 16))
  var sentY = 0.0
  var sentX = 0.0
  for n in 1...steps {
    let wantY = dy * Double(n) / Double(steps)
    let wantX = dx * Double(n) / Double(steps)
    let stepY = Int32((wantY - sentY).rounded())
    let stepX = Int32((wantX - sentX).rounded())
    sentY += Double(stepY)
    sentX += Double(stepX)
    if stepY != 0 || stepX != 0,
      let e = CGEvent(
        scrollWheelEvent2Source: inputSource, units: .pixel, wheelCount: 2, wheel1: -stepY, wheel2: -stepX, wheel3: 0)
    {
      e.flags = []
      e.post(tap: .cghidEventTap)
    }
    usleep(16_000)
  }
}

/// The app the keyboard goes to, asked of the system now. (`NSWorkspace` answers from what
/// it last heard, and a tool with no run loop hears nothing.)
func frontmostPid() -> pid_t? {
  var value: CFTypeRef?
  if AXUIElementCopyAttributeValue(
    AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
    let app = value
  {
    var pid: pid_t = 0
    if AXUIElementGetPid(app as! AXUIElement, &pid) == .success { return pid }
  }
  return NSWorkspace.shared.frontmostApplication?.processIdentifier
}

/// Brings the app and its window to the front, and waits until it is there.
func bringForward(pid: pid_t, window: AXUIElement?) -> Bool {
  guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
  app.activate(options: [.activateAllWindows])
  if let w = window {
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
  }
  let deadline = CACurrentMediaTime() + 3
  while CACurrentMediaTime() < deadline {
    if frontmostPid() == pid { return true }
    usleep(50_000)
  }
  return frontmostPid() == pid
}
