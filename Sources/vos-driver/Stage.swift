// A stage: one display with only what the take named in its pixels.
//
// A take of a window is the display with every other window excluded, cropped to the window.
// A stage is the same exclusion with a longer list of what stays and no crop: every window of
// the apps the request names, at its real place and in its real order, and the parts of the
// desk the request asks for. Nothing else is encoded: not another app, not the wallpaper, not
// the Dock, not the menu bar.
//
// A stage request (beside `out`, `fps`, `bitrate`, `maxSeconds`, `pointer`, `frames`):
//   { "apps": ["TextEdit", "com.apple.calculator"],   names or bundle ids, and/or
//     "pids": [1234],                                  processes (tells two instances apart), or
//     "app": "TextEdit", "stage": true,                one app's every window
//     "desk": ["menubar", "dock", "wallpaper"],        parts of the desk to keep; default none
//     "display": 1,                                    a display id; default the one that holds
//                                                      most of the named apps' windows
//     "ground": "#1e1e1e" }                            what is painted where nothing is; default
//                                                      a neutral of the system's appearance
//
// The frame is the display, less the menu bar's strip when the bar is not kept. The pointer's
// track is in that frame's points. `meta.json` says `captureSurface: "desktop"`, the apps by
// name and bundle id, the desk's parts, and `windows`: where each named app's windows were,
// front to back, every time that changed. Never a window's title.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The desk's parts a stage can keep.
let DESK_PARTS = ["menubar", "dock", "wallpaper"]

/// How often the stage's windows are looked at, for the track of where they are.
let STAGE_WATCH_MS = 33

/// A window of an app, as against a control of one: the system lists a titled window's
/// traffic lights as a small window of their own.
let STAGE_WINDOW_MIN = CGSize(width: 120, height: 80)

struct Stage {
  /// The processes whose windows are on the stage.
  let pids: Set<pid_t>
  /// The apps those are, as the take records them. Never a window's title.
  let apps: [(name: String, id: String)]
  let names: [pid_t: String]
  let desk: Set<String>
  let displayID: CGDirectDisplayID
  /// The part of the display the take is of, in global points with a top-left origin.
  let rect: CGRect
  let ground: CGColor
}

/// Which part of the desk a window at this level is, if it is one. The levels are the
/// system's own constants: who owns the wallpaper and what its window is called have both
/// changed between macOS versions, and its level has not.
func deskPart(layer: Int) -> String? {
  if layer == Int(CGWindowLevelForKey(.mainMenuWindow)) { return "menubar" }
  if layer == Int(CGWindowLevelForKey(.dockWindow)) { return "dock" }
  if layer <= Int(CGWindowLevelForKey(.desktopWindow)) { return "wallpaper" }
  return nil
}

func isStageRequest(_ req: [String: Any]) -> Bool {
  req["apps"] != nil || req["pids"] != nil || (req["stage"] as? Bool ?? false)
}

func parseGround(_ raw: Any?, appearance: String) -> CGColor? {
  guard let text = raw as? String else {
    let gray: CGFloat = appearance == "dark" ? 0.11 : 0.93
    return CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
  }
  let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
  guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
  return CGColor(
    srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255,
    alpha: 1)
}

/// Everything on screen, the desk's own windows included: a stage is scoped against all of it.
func everythingOnScreen() async throws -> SCShareableContent {
  try await limited("The list of windows on screen") {
    Handed(value: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
  }
}

/// The stage a request names, from what is running and on screen now. Nil while none of the
/// named apps has a window on a display (an app launched a moment ago has a process first).
func requestedStage(_ req: [String: Any], _ content: SCShareableContent, appearance: String) -> Stage? {
  var wanted: [String] = (req["apps"] as? [String]) ?? []
  if let one = req["app"] as? String, req["stage"] as? Bool ?? false { wanted.append(one) }
  var pids = Set<pid_t>(((req["pids"] as? [Int]) ?? []).map { pid_t($0) })
  if let one = req["pid"] as? Int, req["stage"] as? Bool ?? false { pids.insert(pid_t(one)) }

  for name in wanted {
    let matches = content.applications.filter { $0.applicationName == name || $0.bundleIdentifier == name }
    guard !matches.isEmpty else { fail("no-window", "No running app is named \"\(name)\".") }
    for app in matches { pids.insert(app.processID) }
  }
  guard !pids.isEmpty else { fail("bad-request", "The stage names no app: give apps, pids, or an app with stage.") }

  var apps: [(name: String, id: String)] = []
  var names: [pid_t: String] = [:]
  for app in content.applications where pids.contains(app.processID) {
    names[app.processID] = app.applicationName
    if !apps.contains(where: { $0.name == app.applicationName && $0.id == app.bundleIdentifier }) {
      apps.append((app.applicationName, app.bundleIdentifier))
    }
  }

  let mine = content.windows.filter {
    $0.windowLayer == 0 && pids.contains($0.owningApplication?.processID ?? -1)
      && $0.frame.width >= STAGE_WINDOW_MIN.width && $0.frame.height >= STAGE_WINDOW_MIN.height
  }
  guard !mine.isEmpty else { return nil }

  let display: SCDisplay
  if let id = req["display"] as? Int {
    guard let named = content.displays.first(where: { Int($0.displayID) == id }) else {
      fail("bad-request", "No display has the id \(id).")
    }
    display = named
  } else {
    func held(_ d: SCDisplay) -> CGFloat {
      mine.reduce(0) { sum, w in
        let part = w.frame.intersection(d.frame)
        return sum + (part.isNull ? 0 : part.width * part.height)
      }
    }
    guard let most = content.displays.max(by: { held($0) < held($1) }) else { return nil }
    display = most
  }

  let desk = Set((req["desk"] as? [String]) ?? [])
  var rect = display.frame
  if !desk.contains("menubar") {
    // The bar's strip holds nothing of a stage that does not keep the bar: the frame starts under it.
    let bar = content.windows.first {
      deskPart(layer: $0.windowLayer) == "menubar" && $0.frame.intersects(display.frame)
        && $0.frame.height < display.frame.height / 4
    }
    if let bar {
      rect = CGRect(
        x: rect.minX, y: bar.frame.maxY, width: rect.width, height: rect.maxY - bar.frame.maxY)
    }
  }
  guard let ground = parseGround(req["ground"], appearance: appearance) else {
    fail("bad-request", "ground is a colour like \"#1e1e1e\".")
  }
  return Stage(
    pids: pids, apps: apps, names: names, desk: desk, displayID: display.displayID, rect: rect, ground: ground)
}

/// The stage a request names, waited for as a window is.
func awaitedStage(_ req: [String: Any], appearance: String) async -> (SCShareableContent, Stage?) {
  let deadline = CACurrentMediaTime() + WINDOW_WAIT_SECONDS
  while true {
    let content: SCShareableContent
    do {
      content = try await everythingOnScreen()
    } catch let late as TimedOut {
      fail("start-failed", late.localizedDescription)
    } catch {
      fail(
        "screen-recording",
        "Screen Recording is not granted to the app that launched this (\(error.localizedDescription)). Switch it on in System Settings, Privacy & Security, Screen & System Audio Recording.")
    }
    if let stage = requestedStage(req, content, appearance: appearance) { return (content, stage) }
    if CACurrentMediaTime() >= deadline { return (content, nil) }
    usleep(300_000)
  }
}

/// One window as the window server has it.
struct ServerWindow {
  let id: CGWindowID
  let pid: pid_t
  let layer: Int
  let alpha: Double
  let bounds: CGRect
  /// Whether it has a title. An app's alert, popover or tip is a window with none. The title
  /// itself is never kept.
  let titled: Bool
}

/// Every window on screen, front to back.
func serverWindows() -> [ServerWindow]? {
  guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
  else { return nil }
  return list.compactMap { info in
    guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
      let b = info[kCGWindowBounds as String] as? [String: Any],
      let bounds = CGRect(dictionaryRepresentation: b as CFDictionary)
    else { return nil }
    return ServerWindow(
      id: id, pid: (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1,
      layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
      alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1, bounds: bounds,
      titled: !((info[kCGWindowName as String] as? String) ?? "").isEmpty)
  }
}

extension Stage {
  /// True for a window the stage holds: one of a named app's, or a kept part of the desk.
  func holds(pid: pid_t, layer: Int) -> Bool {
    if pids.contains(pid) { return true }
    if let part = deskPart(layer: layer) { return desk.contains(part) }
    return false
  }

  /// What the capture leaves out: every window that is not the stage's.
  func others(_ content: SCShareableContent) -> [SCWindow] {
    content.windows.filter { !holds(pid: $0.owningApplication?.processID ?? -1, layer: $0.windowLayer) }
  }

  /// A named app's own windows on the display, front to back: no control, no menu, no panel
  /// of another process.
  func windows(in list: [ServerWindow]) -> [ServerWindow] {
    list.filter {
      $0.layer == 0 && pids.contains($0.pid) && $0.alpha > 0 && $0.bounds.intersects(rect)
        && $0.bounds.width >= STAGE_WINDOW_MIN.width && $0.bounds.height >= STAGE_WINDOW_MIN.height
    }
  }

  /// True when a point is on the stage: inside the frame, and not over a window of an app
  /// the take did not name. The ground between the stage's windows is the stage's.
  func isOn(_ p: CGPoint, order: [ServerWindow]) -> Bool {
    guard rect.contains(p) else { return false }
    for w in order where w.layer == 0 && w.alpha > 0 && w.bounds.contains(p) {
      return pids.contains(w.pid)
    }
    return true
  }
}

extension Recorder {
  /// Scopes the capture to the stage and starts it.
  func startStage(content: SCShareableContent, stage: Stage) async throws {
    progress.at("scoping the capture to the stage")
    self.stage = stage
    guard let display = content.displays.first(where: { $0.displayID == stage.displayID }) else {
      throw NSError(
        domain: "vos.driver", code: 2, userInfo: [NSLocalizedDescriptionKey: "The stage's display is gone."])
    }
    let others = stage.others(content)
    let filter = SCContentFilter(display: display, excludingWindows: others)
    excludesOthers = true
    excluded = Set(others.map { $0.windowID })
    displayID = display.displayID
    displayOrigin = display.frame.origin
    // What is on the display now and cannot be excluded is known from the start, so a take
    // does not open by waiting on it.
    ignored = (windowsOver() ?? []).subtracting(excluded)
    // Always said: a filter left to choose its own rectangle does not always choose the display's.
    appliedRect = CGRect(
      x: stage.rect.minX - display.frame.minX, y: stage.rect.minY - display.frame.minY, width: stage.rect.width,
      height: stage.rect.height)
    config.sourceRect = appliedRect
    firstFrame = stage.rect
    try await open(filter: filter, frame: stage.rect, filterKind: "stage", outside: stage.ground)
  }

  /// Looks at the stage's windows, thirty times a second: where each is, front to back, is
  /// written down every time it changes, and the pointer's samples are judged against it.
  func startStageWatch() {
    guard stage != nil else { return }
    let t = DispatchSource.makeTimerSource(queue: watchQ)
    t.schedule(deadline: .now(), repeating: .milliseconds(STAGE_WATCH_MS), leeway: .milliseconds(4))
    t.setEventHandler { [weak self] in self?.watchStage() }
    t.resume()
    watcher = t
  }

  func watchStage() {
    guard !finished, let stage, let list = serverWindows() else { return }
    let now = CACurrentMediaTime()
    let mine = stage.windows(in: list)
    let entry: [[String: Any]] = mine.map { w in
      var e: [String: Any] = [
        "id": Int(w.id), "app": stage.names[w.pid] ?? "",
        "x": r1(w.bounds.minX - stage.rect.minX), "y": r1(w.bounds.minY - stage.rect.minY),
        "w": r1(w.bounds.width), "h": r1(w.bounds.height),
      ]
      // An alert, a popover, a tip: a window of the app's with no title. What happens in one
      // is happening in the app's window, and whoever reads the track can tell.
      if !w.titled { e["panel"] = true }
      return e
    }
    let signature = mine.map { "\($0.id):\(Int($0.bounds.minX)),\(Int($0.bounds.minY)),\(Int($0.bounds.width)),\(Int($0.bounds.height))" }
      .joined(separator: "|")
    locked(evLock) {
      stageOrder = list
      if signature != stageSignature {
        stageSignature = signature
        stageTrack.append((now, entry))
      }
    }
  }

  /// The track of the stage's windows on the take's clock: what was there at the first frame,
  /// then every change.
  func stageWindowsJSON(durationMs: Double) -> [[String: Any]] {
    guard let t0 = t0Host else { return [] }
    let track = locked(evLock) { stageTrack }
    var out: [[String: Any]] = []
    for (host, windows) in track {
      let t = (host - t0) * 1000
      if t > durationMs + 50 { break }
      if t <= 0 || out.isEmpty {
        // Before the first frame, only the last look is what the take opens on; and the
        // first look of all is that, even when the first frame beat it by a tick.
        out = [["t": 0, "windows": windows]]
      } else {
        out.append(["t": r1(t), "windows": windows])
      }
    }
    return out
  }

  /// One sample of the real pointer on a stage. A sample counts only while the pointer is on
  /// the stage: over a window of an app the take did not name, the track is silent.
  func sampleStage(_ stage: Stage) {
    guard let t0 = t0Host, !finished else { return }
    let t = (CACurrentMediaTime() - t0) * 1000
    guard t >= 0, let pos = CGEvent(source: nil)?.location else { return }
    let order = locked(evLock) { stageOrder }
    let on = stage.isOn(pos, order: order)
    let origin = stage.rect.origin

    let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
    if down != lastDown {
      lastDown = down
      if down {
        if on {
          pressOnStage = true
          push("down", t, pos, rect: wantFrames ? elementRect(at: pos) : nil, origin: origin)
        }
      } else if pressOnStage {
        // A press that began on the stage ends in the track wherever it is let go.
        pressOnStage = false
        push("up", t, pos, origin: origin)
      }
    }
    if let last = lastPos {
      if abs(pos.x - last.x) >= 1 || abs(pos.y - last.y) >= 1 {
        lastPos = pos
        if on || pressOnStage { push("move", t, pos, origin: origin) }
      }
    } else {
      lastPos = pos
      if on { push("move", t, pos, origin: origin) }
    }

    // typing is activity: the count rose, nothing else is known or kept
    let keys = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    if keys != lastKeyCount {
      lastKeyCount = keys
      guard t - lastKeyPing >= 350, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        stage.pids.contains(front)
      else { return }
      lastKeyPing = t
      // The window the typing is in: the frontmost of the app the keyboard goes to.
      let win = stage.windows(in: order).first(where: { $0.pid == front })?.bounds ?? stage.rect
      if wantFrames, let r = focusedRect(), stage.rect.intersects(r) {
        let fills = r.width * r.height > 0.5 * win.width * win.height
        if fills, let c = caretRect(), stage.rect.intersects(c) {
          push("key", t, CGPoint(x: c.midX, y: c.midY), origin: origin)
        } else {
          push("key", t, CGPoint(x: r.midX, y: r.midY), rect: fills ? nil : r, origin: origin)
        }
      } else if on {
        push("key", t, pos, origin: origin)
      }
    }
  }

  /// The windows on the stage's display that are not the stage's, as the window server has them.
  func stageStrangers(_ stage: Stage) -> Set<CGWindowID>? {
    guard let list = serverWindows() else { return nil }
    return Set(
      list.filter { $0.alpha > 0 && $0.bounds.intersects(stage.rect) && !stage.holds(pid: $0.pid, layer: $0.layer) }
        .map { $0.id })
  }
}
