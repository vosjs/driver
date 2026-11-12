// A spike driver: posts real pointer and key events at the system level into one window,
// prints what it posted and when (host clock, seconds), then puts the pointer back.
//   drive <windowId>
import AppKit
import CoreGraphics
import Foundation

func frame(_ id: CGWindowID) -> CGRect {
  let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as! [[String: Any]]
  return CGRect(dictionaryRepresentation: list[0][kCGWindowBounds as String] as! CFDictionary)!
}
func say(_ what: String, _ extra: [String: Any] = [:]) {
  var o = extra
  o["what"] = what
  o["host"] = CACurrentMediaTime()
  let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
  print(String(data: d, encoding: .utf8)!)
}
let src = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ p: CGPoint) {
  CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
/// Clock-driven travel, eased, as the web recorder's moveTo does.
func glide(from a: CGPoint, to b: CGPoint, ms: Double) {
  let start = CACurrentMediaTime()
  while true {
    let k = min(1, (CACurrentMediaTime() - start) * 1000 / ms)
    let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
    post(.mouseMoved, CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e))
    if k >= 1 { break }
    usleep(8000)
  }
}
func click(_ p: CGPoint) {
  say("down", ["x": p.x, "y": p.y])
  post(.leftMouseDown, p)
  usleep(70000)
  post(.leftMouseUp, p)
}
func key(_ code: CGKeyCode) {
  say("key")
  CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
  usleep(30000)
  CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
}

let id = CGWindowID(CommandLine.arguments[1])!
let w = frame(id)
let home = CGEvent(source: nil)!.location
func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: w.minX + x, y: w.minY + y) }

let a = at(120, 330)
let b = at(330, 78)  // end of line 3
let c = at(160, 38)  // line 1
CGWarpMouseCursorPosition(a)
usleep(300_000)
glide(from: a, to: b, ms: 700)
usleep(150_000)
click(b)
usleep(600_000)
for code: CGKeyCode in [49, 4, 34, 47] {  // space h i .
  key(code)
  usleep(140_000)
}
usleep(900_000)  // a parked pointer: nothing should be sampled here
glide(from: b, to: c, ms: 600)
usleep(120_000)
click(c)
usleep(700_000)
CGWarpMouseCursorPosition(home)
say("done")
