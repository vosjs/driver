// A scripted take: the commands a script sends while the take is recorded, and the two verbs
// a script's author looks at the app with first (`tree`, `still`).
//
// While `record` runs, each line on stdin is `stop`, or one JSON command:
//
//   {"id": 1, "do": "locate", "selector": "button[name='Save']"}
//   {"id": 2, "do": "click",  "selector": "button[name='Save']"}        also "x","y" in window points; "count"; "button": "right"
//   {"id": 3, "do": "hover",  "selector": "..."}
//   {"id": 4, "do": "type",   "text": "hello", "selector": "textfield[id='title']", "delayMs": 70}
//   {"id": 5, "do": "press",  "keys": "Meta+S"}
//   {"id": 6, "do": "scroll", "dy": 240, "selector": "..."}
//   {"id": 7, "do": "drag",   "selector": "...", "to": {"x": 300, "y": 200}}
//   {"id": 8, "do": "move",   "x": 100, "y": 100}
//   {"id": 9, "do": "now"}                                              the take's clock, and nothing else
//   {"id": 10, "do": "focused"}                                         what the keyboard would go to: its role and bounds
//
// and each is answered, in order, with one line:
//
//   {"event": "result", "id": 2, "ok": true, "tStart": 1830.2, "tEnd": 2391.7, "rect": {...}, "count": 1, "enabled": true}
//   {"event": "result", "id": 2, "ok": false, "code": "not-found", "message": "..."}
//
// Times are milliseconds on the take's clock, so they are the step's extent in the footage.
// Rects are in the window's own points, the space the cursor track is in.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

let ACCESSIBILITY_NEEDED =
  "Accessibility is not granted to the app that launched this. A scripted take acts on the app through it. Switch it on in System Settings, Privacy & Security, Accessibility."

final class Driver: @unchecked Sendable {
  let rec: Recorder
  let pid: pid_t
  let windowID: CGWindowID

  init(rec: Recorder, pid: pid_t, windowID: CGWindowID) {
    self.rec = rec
    self.pid = pid
    self.windowID = windowID
  }

  /// Milliseconds on the take's clock, now.
  var now: Double { ((CACurrentMediaTime() - (rec.t0Host ?? CACurrentMediaTime())) * 1000) }

  func frame() throws -> CGRect {
    guard let f = windowFrame(windowID) else {
      throw InputError(code: "no-window", message: "The window being recorded is gone.")
    }
    return f
  }

  /// The window's tree, read now: an interface changes under a script, so it is never kept.
  func tree() throws -> (root: Node, window: CGRect, element: AXUIElement) {
    guard AXIsProcessTrusted() else { throw InputError(code: "accessibility", message: ACCESSIBILITY_NEEDED) }
    let f = try frame()
    guard let w = windowElement(pid, frame: f), let root = readTree(w) else {
      throw InputError(code: "no-tree", message: "The window offers no accessibility tree to find elements in.")
    }
    return (root, f, w)
  }

  struct Target {
    /// Where to act, in global points.
    let point: CGPoint
    /// The element's bounds in global points, when the target is an element.
    let rect: CGRect?
    let count: Int
    let enabled: Bool
    /// What the interface calls the element. Never what a person typed into it.
    var name = ""
  }

  /// What a command acts on: an element by selector (its centre), or a point of the window.
  func target(_ cmd: [String: Any]) throws -> Target? {
    if let selector = cmd["selector"] as? String {
      let (root, window, _) = try tree()
      let steps: [SelectorStep]
      do { steps = try parseSelector(selector) } catch {
        throw InputError(code: "bad-request", message: error.localizedDescription)
      }
      let found = select(steps, in: root).filter { $0.frame.width > 0 && $0.frame.height > 0 }
      guard let first = found.first else { return nil }
      // An element scrolled out of the window is there and cannot be pressed.
      guard first.frame.intersects(window) else {
        throw InputError(code: "not-in-view", message: "\(selector) is outside the window's visible area.")
      }
      let visible = first.frame.intersection(window)
      return Target(
        point: CGPoint(x: visible.midX, y: visible.midY), rect: first.frame, count: found.count,
        enabled: first.enabled, name: first.name)
    }
    if let x = (cmd["x"] as? NSNumber)?.doubleValue, let y = (cmd["y"] as? NSNumber)?.doubleValue {
      let f = try frame()
      return Target(point: CGPoint(x: f.minX + x, y: f.minY + y), rect: nil, count: 1, enabled: true)
    }
    throw InputError(code: "bad-request", message: "The command names no target: a selector, or x and y in the window's points.")
  }

  func rectJSON(_ r: CGRect, _ window: CGRect) -> [String: Any] {
    ["x": r1(r.minX - window.minX), "y": r1(r.minY - window.minY), "w": r1(r.width), "h": r1(r.height)]
  }

  /// The app in front, where input goes. A take that acts on an app nobody can see acts on
  /// another one.
  func forward() throws {
    if frontmostPid() == pid { return }
    let f = try frame()
    guard bringForward(pid: pid, window: windowElement(pid, frame: f)) else {
      throw InputError(code: "not-frontmost", message: "The app could not be brought to the front, so input would go to another one.")
    }
    usleep(200_000)
  }

  /// Runs one command and answers it.
  func run(_ cmd: [String: Any]) -> [String: Any] {
    var result: [String: Any] = ["event": "result"]
    if let id = cmd["id"] { result["id"] = id }
    guard rec.t0Host != nil else {
      result["ok"] = false
      result["code"] = "not-ready"
      result["message"] = "The take has not begun: wait for `ready` before a command."
      return result
    }
    guard let verb = cmd["do"] as? String else {
      result["ok"] = false
      result["code"] = "bad-request"
      result["message"] = "A command says what to do: \"do\"."
      return result
    }
    // A command changes what is on screen: what the take covers is looked for again at once.
    defer { rec.masks?.soon() }
    do {
      let started = now
      var answer: [String: Any] = [:]
      switch verb {
      case "now":
        break
      case "focused":
        // What a key would go to, so a script can know before it types. Its role and where it
        // is; its name when it is not something typed into. Never its value.
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
          let v = value
        {
          let el = v as! AXUIElement
          let role = roleName(axString(el, kAXRoleAttribute as String))
          var focused: [String: Any] = ["role": role]
          let name = nameOf(el, role: role)
          if !name.isEmpty { focused["name"] = name }
          if let r = axRect(el) { focused["rect"] = rectJSON(r, try frame()) }
          answer["focused"] = focused
        }
        answer["frontmost"] = frontmostPid() == pid
      case "locate":
        if let t = try target(cmd) {
          answer["count"] = t.count
          answer["enabled"] = t.enabled
          if !t.name.isEmpty { answer["name"] = t.name }
          if let r = t.rect { answer["rect"] = rectJSON(r, try frame()) }
        } else {
          answer["count"] = 0
        }
      case "click", "hover":
        guard let t = try target(cmd) else { throw notFound(cmd) }
        try forward()
        glide(to: t.point)
        answer["count"] = t.count
        answer["enabled"] = t.enabled
        if let r = t.rect { answer["rect"] = rectJSON(r, try frame()) }
        if verb == "click" {
          // A disabled control is found and not pressed: the script hears it, and decides.
          if t.enabled {
            usleep(60_000)
            // The press carries the element's own bounds, not whatever a hit test finds there.
            rec.pressRect = t.rect
            let held = try modifierFlags(cmd["modifiers"])
            holdModifiers(held)
            press(
              at: t.point, count: (cmd["count"] as? Int) ?? 1, right: (cmd["button"] as? String) == "right",
              flags: held)
            releaseModifiers(held)
            answer["pressed"] = true
          } else {
            answer["pressed"] = false
          }
        }
      case "type":
        guard let text = cmd["text"] as? String else {
          throw InputError(code: "bad-request", message: "type takes the text to type.")
        }
        try forward()
        if cmd["selector"] != nil || cmd["x"] != nil {
          guard let t = try target(cmd) else { throw notFound(cmd) }
          glide(to: t.point)
          usleep(60_000)
          rec.pressRect = t.rect
          press(at: t.point)
          usleep(150_000)
          answer["count"] = t.count
          if let r = t.rect { answer["rect"] = rectJSON(r, try frame()) }
        }
        let app = pid
        guard typeText(text, delayMs: (cmd["delayMs"] as? NSNumber)?.doubleValue ?? 70, stillThere: { frontmostPid() == app })
        else {
          throw InputError(
            code: "not-frontmost",
            message: "Another app took the keyboard while the script was typing, so typing stopped there.")
        }
      case "press":
        try forward()
        let chords = (cmd["keys"] as? [String]) ?? (cmd["keys"] as? String).map { [$0] } ?? []
        guard !chords.isEmpty else {
          throw InputError(code: "bad-request", message: "press takes keys: a chord like Meta+S, or a list of them.")
        }
        for chord in chords {
          // A chord sent to the wrong app does something there: Meta+W, Meta+Q.
          guard frontmostPid() == pid else {
            throw InputError(
              code: "not-frontmost",
              message: "Another app took the keyboard, so the keys were not pressed.")
          }
          try pressKeys(chord)
          usleep(80_000)
        }
      case "scroll":
        try forward()
        if cmd["selector"] != nil || cmd["x"] != nil {
          guard let t = try target(cmd) else { throw notFound(cmd) }
          glide(to: t.point)
          if let r = t.rect { answer["rect"] = rectJSON(r, try frame()) }
        } else if let f = windowFrame(windowID), !f.contains(pointerLocation()) {
          // The wheel turns what is under the pointer: over the window, or nothing happens.
          glide(to: CGPoint(x: f.midX, y: f.midY))
        }
        scroll(
          dy: (cmd["dy"] as? NSNumber)?.doubleValue ?? 0, dx: (cmd["dx"] as? NSNumber)?.doubleValue ?? 0,
          ms: (cmd["ms"] as? NSNumber)?.doubleValue ?? 300)
      case "drag":
        guard let from = try target(cmd) else { throw notFound(cmd) }
        guard let to = cmd["to"] as? [String: Any], let end = try target(to) else {
          throw InputError(code: "bad-request", message: "drag takes where to: \"to\", a selector or x and y.")
        }
        try forward()
        glide(to: from.point)
        usleep(60_000)
        let held = try modifierFlags(cmd["modifiers"])
        rec.pressRect = from.rect
        holdModifiers(held)
        postMouse(.leftMouseDown, from.point, flags: held)
        usleep(120_000)
        glide(to: end.point, ms: (cmd["ms"] as? NSNumber)?.doubleValue, dragging: true, flags: held)
        usleep(80_000)
        postMouse(.leftMouseUp, end.point, flags: held)
        releaseModifiers(held)
        if let r = from.rect { answer["rect"] = rectJSON(r, try frame()) }
      case "move":
        guard let t = try target(cmd) else { throw notFound(cmd) }
        glide(to: t.point, ms: (cmd["ms"] as? NSNumber)?.doubleValue)
      default:
        throw InputError(code: "bad-request", message: "\"\(verb)\" is not a command. One of: locate, click, hover, type, press, scroll, drag, move, now, focused.")
      }
      result["ok"] = true
      result["tStart"] = r1(started)
      result["tEnd"] = r1(now)
      for (k, v) in answer { result[k] = v }
    } catch let e as InputError {
      result["ok"] = false
      result["code"] = e.code
      result["message"] = e.message
    } catch {
      result["ok"] = false
      result["code"] = "failed"
      result["message"] = error.localizedDescription
    }
    return result
  }

  func notFound(_ cmd: [String: Any]) -> InputError {
    InputError(code: "not-found", message: "Nothing in the window matches \(cmd["selector"] as? String ?? "the target").")
  }
}

// MARK: finding an app without recording it

/// A running app by its name or bundle id, and its main window as accessibility has it.
func appWindow(_ req: [String: Any]) -> (pid: pid_t, name: String, window: AXUIElement, frame: CGRect)? {
  var pid: pid_t?
  var name = ""
  var wanted: CGRect?
  if let id = req["window"] as? Int {
    guard
      let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
      let info = list.first, let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    else { return nil }
    pid = owner
    wanted = windowFrame(CGWindowID(id))
  } else if let given = req["pid"] as? Int {
    pid = pid_t(given)
  } else if let app = req["app"] as? String {
    pid = NSWorkspace.shared.runningApplications.first {
      $0.localizedName == app || $0.bundleIdentifier == app
    }?.processIdentifier
  }
  guard let p = pid else { return nil }
  name = NSRunningApplication(processIdentifier: p)?.localizedName ?? ""
  let element = appElement(p)
  if let f = wanted, let w = windowElement(p, frame: f) { return (p, name, w, f) }
  // The app's main window, else its largest.
  var main: CFTypeRef?
  if AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &main) == .success, let m = main {
    let w = m as! AXUIElement
    if let f = axRect(w) { return (p, name, w, f) }
  }
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
    let windows = value as? [AXUIElement]
  else { return nil }
  let sized = windows.compactMap { w in axRect(w).map { (w, $0) } }
  guard let (w, f) = sized.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else { return nil }
  return (p, name, w, f)
}

/// `tree`: the outline of an app's window, for someone about to script it.
func cmdTree(_ json: String) {
  guard let data = json.data(using: .utf8),
    let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { fail("bad-request", "The tree request is not a JSON object.") }
  guard AXIsProcessTrusted() else { fail("accessibility", ACCESSIBILITY_NEEDED) }
  // An app that does not answer accessibility holds every question for seconds.
  answerWithin(BEGIN_SECONDS, "Reading the window's outline")
  // An app launched a moment ago has a process before it has a window.
  var target = appWindow(req)
  let windowDeadline = CACurrentMediaTime() + WINDOW_WAIT_SECONDS
  while target == nil, CACurrentMediaTime() < windowDeadline {
    usleep(300_000)
    target = appWindow(req)
  }
  guard let found = target else { fail("no-window", "No window matches the request.") }
  // A Chromium app builds the tree of its pages only when asked, and not at once: an Electron
  // app asked while it runs can take seconds. It is waited for, within a limit, and the answer
  // says whether it came, so the caller can say what to do when it did not.
  let kind = appKind(found.pid)
  var root = readTree(found.window)
  let deadline = CACurrentMediaTime() + (kind == "native" ? 1.5 : TREE_BUILD_SECONDS)
  while CACurrentMediaTime() < deadline, !(root.map { isBuilt($0, kind: kind) } ?? false) {
    usleep(300_000)
    root = readTree(found.window)
  }
  guard let tree = root else { fail("no-tree", "The window offers no accessibility tree.") }
  emit([
    "event": "tree", "app": found.name, "kind": kind, "built": isBuilt(tree, kind: kind),
    "window": ["w": r1(found.frame.width), "h": r1(found.frame.height)],
    "elements": outline(tree, window: found.frame),
  ])
}

/// How long a Chromium app is given to build the tree it was asked for.
let TREE_BUILD_SECONDS = 10.0

/// What an app is made of, as far as its tree is concerned: `electron`, `chromium` (a browser
/// or another shell around Chromium's pages) or `native`. Read from what its bundle carries.
func appKind(_ pid: pid_t) -> String {
  guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return "native" }
  let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
  guard let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return "native" }
  if names.contains("Electron Framework.framework") { return "electron" }
  // Chromium's processes come as helper apps, and a renderer among them is the mark of its
  // pages: "… Helper (Renderer).app" in a browser, "… (Renderer).app" in some shells.
  if names.contains(where: { $0.hasSuffix("Renderer).app") }) { return "chromium" }
  for name in names where name.hasSuffix(".framework") {
    let helpers = frameworks.appendingPathComponent(name).appendingPathComponent("Helpers")
    let versioned = frameworks.appendingPathComponent(name).appendingPathComponent("Versions/Current/Helpers")
    for dir in [helpers, versioned] {
      if let inside = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
        inside.contains(where: { $0.hasSuffix("Renderer).app") })
      {
        return "chromium"
      }
    }
  }
  return "native"
}

/// Whether the tree a window offers is the one a script can use. A native window's is, as
/// soon as it has anything in it. A Chromium window's is once a page area has content: before
/// that it is a few empty groups and the window's own buttons.
func isBuilt(_ root: Node, kind: String) -> Bool {
  let all = descendants(root)
  if kind == "native" { return all.count >= 3 }
  return all.contains { $0.role == "webarea" && !$0.children.isEmpty }
}
