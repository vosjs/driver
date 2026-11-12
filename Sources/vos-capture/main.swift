// vos-capture: a headless capture helper. One process per take, no window, no state.
//
//   vos-capture check                 permissions, as JSON (run from a fresh process)
//   vos-capture windows               windows that can be captured, as JSON lines
//   vos-capture record '<json>'       record one window; NDJSON on stdout; "stop\n" on stdin ends it
//
// record request:
//   { "window": 1234 | "app": "TextEdit",   target (window id wins)
//     "out": "/path/take",                   a directory: recording.mp4, cursor.json, meta.json
//     "filter": "others-out" | …,            default: the display with every OTHER app excluded, cropped
//                                            to the window. Naming the window or its app ("window", "app",
//                                            "display-window") makes macOS draw its sharing control over the
//                                            traffic lights, and that lands in the pixels.
//     "fps": 60, "maxSeconds": 1800, "bitrate": 8000000,
//     "pointer": true,                       sample the real pointer (a performed take)
//     "frames": false,                       read element frames at a press (needs Accessibility)
//     "surface": "app" }                     what meta.captureSurface says
//
// The system pointer is never in the pixels. Samples are emitted on change, never on a timer.
// Key identity never enters this process: typing is the system's COUNT of key-downs.

import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

let PROTOCOL = 1

// MARK: output

let outLock = NSLock()
func emit(_ obj: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
    var line = String(data: data, encoding: .utf8)
  else { return }
  line += "\n"
  outLock.lock()
  FileHandle.standardOutput.write(line.data(using: .utf8)!)
  outLock.unlock()
}
func fail(_ code: String, _ message: String) -> Never {
  emit(["event": "error", "code": code, "message": message])
  exit(1)
}
func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

// MARK: geometry

/// A window's frame in global points, top-left origin (the space CGEvent.location speaks).
func windowFrame(_ id: CGWindowID) -> CGRect? {
  guard
    let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
    let info = list.first,
    let b = info[kCGWindowBounds as String] as? [String: Any],
    let rect = CGRect(dictionaryRepresentation: b as CFDictionary)
  else { return nil }
  return rect
}

func axRect(_ el: AXUIElement) -> CGRect? {
  var p: CFTypeRef?
  var s: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
    AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
    let pv = p, let sv = s
  else { return nil }
  var pt = CGPoint.zero
  var sz = CGSize.zero
  guard AXValueGetValue(pv as! AXValue, .cgPoint, &pt), AXValueGetValue(sv as! AXValue, .cgSize, &sz)
  else { return nil }
  return CGRect(origin: pt, size: sz)
}

let axSystem = AXUIElementCreateSystemWide()
func elementRect(at p: CGPoint) -> CGRect? {
  var el: AXUIElement?
  guard AXUIElementCopyElementAtPosition(axSystem, Float(p.x), Float(p.y), &el) == .success, let e = el
  else { return nil }
  return axRect(e)
}
func focusedElement() -> AXUIElement? {
  var el: CFTypeRef?
  guard AXUIElementCopyAttributeValue(axSystem, kAXFocusedUIElementAttribute as CFString, &el) == .success,
    let e = el
  else { return nil }
  return (e as! AXUIElement)
}
func focusedRect() -> CGRect? { focusedElement().flatMap(axRect) }
/// Where the insertion point is, in global points: the bounds of the focused element's selection.
/// A position only. The text itself is never read.
func caretRect() -> CGRect? {
  guard let e = focusedElement() else { return nil }
  var range: CFTypeRef?
  guard AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
    let r = range
  else { return nil }
  var bounds: CFTypeRef?
  guard
    AXUIElementCopyParameterizedAttributeValue(
      e, kAXBoundsForRangeParameterizedAttribute as CFString, r, &bounds) == .success,
    let bv = bounds
  else { return nil }
  var rect = CGRect.zero
  guard AXValueGetValue(bv as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
  return rect
}

// MARK: recorder

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
  let windowID: CGWindowID
  let outDir: URL
  let fps: Int
  let bitrate: Int
  let wantPointer: Bool
  let wantFrames: Bool
  let surface: String
  let appName: String
  let appID: String

  var stream: SCStream?
  var writer: AVAssetWriter!
  var input: AVAssetWriterInput!
  let videoQ = DispatchQueue(label: "vos.capture.video")
  let pointerQ = DispatchQueue(label: "vos.capture.pointer")
  var timer: DispatchSourceTimer?

  // clock: zero is the first frame the file holds, on the host clock (seconds)
  var t0Host: Double?
  var t0Wall: Double = 0
  var lastPTS: Double = 0
  var frames = 0
  var idle = 0
  var dropped = 0
  var arrivalLagSum = 0.0
  var arrivalLagMax = 0.0

  // geometry
  var pointSize: CGSize = .zero
  var pixelSize: (w: Int, h: Int) = (0, 0)
  var scale: Double = 1
  var resized = false
  var moved = false
  var firstFrame: CGRect = .zero

  // track
  var events: [[String: Any]] = []
  let evLock = NSLock()
  var lastPos: CGPoint?
  var lastDown = false
  var lastKeyCount: UInt32 = 0
  var lastKeyPing = -1.0

  var finished = false
  let done = DispatchSemaphore(value: 0)

  init(
    windowID: CGWindowID, outDir: URL, fps: Int, bitrate: Int, pointer: Bool, frames: Bool, surface: String,
    appName: String, appID: String
  ) {
    self.windowID = windowID
    self.outDir = outDir
    self.fps = fps
    self.bitrate = bitrate
    self.wantPointer = pointer
    self.wantFrames = frames
    self.surface = surface
    self.appName = appName
    self.appID = appID
  }

  func start(content: SCShareableContent, window: SCWindow, filterKind: String) async throws {
    let filter: SCContentFilter
    let config = SCStreamConfiguration()
    let frame = window.frame
    firstFrame = frame
    if filterKind != "window", let app = window.owningApplication,
      let display = content.displays.first(where: { $0.frame.intersects(frame) }) ?? content.displays.first
    {
      switch filterKind {
      case "display-window": filter = SCContentFilter(display: display, including: [window])
      case "display": filter = SCContentFilter(display: display, excludingWindows: [])
      case "others-out":
        // the display with every OTHER application excluded: scope by exclusion, not by naming the window
        let others = content.applications.filter { $0.processID != app.processID }
        filter = SCContentFilter(display: display, excludingApplications: others, exceptingWindows: [])
      default: filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
      }
      config.sourceRect = CGRect(
        x: frame.minX - display.frame.minX, y: frame.minY - display.frame.minY, width: frame.width,
        height: frame.height)
    } else {
      filter = SCContentFilter(desktopIndependentWindow: window)
    }
    scale = Double(filter.pointPixelScale)
    pointSize = frame.size
    var w = Int((frame.width * scale).rounded())
    var h = Int((frame.height * scale).rounded())
    if w > 3840 {
      h = Int(Double(h) * 3840.0 / Double(w))
      w = 3840
    }
    w -= w % 2
    h -= h % 2
    pixelSize = (w, h)

    config.width = w
    config.height = h
    config.showsCursor = false
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.queueDepth = 6
    config.capturesAudio = false
    config.scalesToFit = true

    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let file = outDir.appendingPathComponent("recording.mp4")
    try? FileManager.default.removeItem(at: file)
    writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
    writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
    input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: w,
        AVVideoHeightKey: h,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: bitrate,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          AVVideoExpectedSourceFrameRateKey: fps,
          AVVideoAllowFrameReorderingKey: false,
          AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ] as [String: Any],
      ])
    input.expectsMediaDataInRealTime = true
    writer.add(input)
    guard writer.startWriting() else {
      throw writer.error ?? NSError(domain: "vos.capture", code: 1)
    }

    let s = SCStream(filter: filter, configuration: config, delegate: self)
    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQ)
    try await s.startCapture()
    stream = s

    emit([
      "event": "ready", "protocol": PROTOCOL, "window": Int(windowID), "app": appName,
      "frame": ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height],
      "scale": scale, "captureWidth": w, "captureHeight": h, "filter": filterKind,
      "accessibility": AXIsProcessTrusted(),
    ])
    if wantPointer { startPointer() }
  }

  // MARK: frames

  func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sb.isValid, !finished else { return }
    guard
      let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = atts.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw)
    else { return }
    if status != .complete {
      idle += 1
      return
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
    let now = CACurrentMediaTime()
    if t0Host == nil {
      t0Host = pts
      t0Wall = Date().timeIntervalSince1970 * 1000 - (now - pts) * 1000
      writer.startSession(atSourceTime: .zero)
    }
    let lag = now - pts
    arrivalLagSum += lag
    arrivalLagMax = max(arrivalLagMax, lag)
    let rel = pts - t0Host!
    guard rel >= lastPTS, input.isReadyForMoreMediaData else {
      dropped += 1
      return
    }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMTime(seconds: rel, preferredTimescale: 600_000),
      decodeTimeStamp: .invalid)
    var copy: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(
      allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleBufferOut: &copy)
    if let c = copy, input.append(c) {
      frames += 1
      lastPTS = rel
    } else {
      dropped += 1
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    emit(["event": "notice", "code": "stream-stopped", "message": error.localizedDescription])
    Task { await self.stop(reason: "stream-stopped") }
  }

  // MARK: pointer (a performed take)

  func startPointer() {
    lastKeyCount = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    let t = DispatchSource.makeTimerSource(queue: pointerQ)
    t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
    t.setEventHandler { [weak self] in self?.sample() }
    t.resume()
    timer = t
  }

  func push(_ type: String, _ t: Double, _ p: CGPoint, rect: CGRect? = nil, origin: CGPoint) {
    var e: [String: Any] = ["t": r1(t), "x": r1(p.x - origin.x), "y": r1(p.y - origin.y), "type": type]
    if type == "down" || type == "up" { e["button"] = 0 }
    if let r = rect {
      e["rect"] = ["x": r1(r.minX - origin.x), "y": r1(r.minY - origin.y), "w": r1(r.width), "h": r1(r.height)]
    }
    evLock.lock()
    events.append(e)
    evLock.unlock()
  }

  func sample() {
    guard let t0 = t0Host, !finished else { return }
    let t = (CACurrentMediaTime() - t0) * 1000
    guard t >= 0, let win = windowFrame(windowID), let pos = CGEvent(source: nil)?.location else { return }
    if abs(win.width - firstFrame.width) > 1 || abs(win.height - firstFrame.height) > 1 { resized = true }
    if abs(win.minX - firstFrame.minX) > 1 || abs(win.minY - firstFrame.minY) > 1 { moved = true }
    let inside = win.contains(pos)
    let origin = win.origin

    let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
    if down != lastDown {
      lastDown = down
      if inside {
        let rect = (wantFrames && down) ? elementRect(at: pos) : nil
        push(down ? "down" : "up", t, pos, rect: rect, origin: origin)
      }
    }
    if let last = lastPos {
      if abs(pos.x - last.x) >= 1 || abs(pos.y - last.y) >= 1 {
        lastPos = pos
        if inside { push("move", t, pos, origin: origin) }
      }
    } else {
      lastPos = pos
      if inside { push("move", t, pos, origin: origin) }
    }

    // typing is activity: the count rose, nothing else is known or kept
    let keys = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
    if keys != lastKeyCount {
      lastKeyCount = keys
      if t - lastKeyPing >= 350, NSWorkspace.shared.frontmostApplication?.localizedName == appName {
        lastKeyPing = t
        if wantFrames, let r = focusedRect(), win.intersects(r) {
          // A field names itself. An element that fills the window (an editor, a canvas) says
          // nothing about WHERE the typing is: there the ping sits at the insertion point.
          let fills = r.width * r.height > 0.5 * win.width * win.height
          if fills, let c = caretRect(), win.intersects(c) {
            push("key", t, CGPoint(x: c.midX, y: c.midY), origin: origin)
          } else {
            push("key", t, CGPoint(x: r.midX, y: r.midY), rect: fills ? nil : r, origin: origin)
          }
        } else if inside {
          push("key", t, pos, origin: origin)
        }
      }
    }
  }

  // MARK: stop

  func stop(reason: String) async {
    if finished { return }
    finished = true
    timer?.cancel()
    try? await stream?.stopCapture()
    videoQ.sync {}
    input.markAsFinished()
    await writer.finishWriting()

    let durationMs = lastPTS * 1000
    evLock.lock()
    let track = events.filter { ($0["t"] as? Double ?? 0) <= durationMs + 50 }
    evLock.unlock()

    var meta: [String: Any] = [
      "dpr": scale, "zoom": 1, "t0": t0Wall.rounded(), "durationMs": durationMs.rounded(),
      "width": Int(pointSize.width.rounded()), "height": Int(pointSize.height.rounded()),
      "fps": fps, "captureWidth": pixelSize.w, "captureHeight": pixelSize.h,
      "captureSurface": surface, "platform": "mac", "producer": "desktop",
      "app": ["name": appName, "id": appID],
    ]
    if resized { meta["resizedDuringTake"] = true }
    func write(_ name: String, _ obj: Any) {
      if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
        try? d.write(to: outDir.appendingPathComponent(name))
      }
    }
    write("cursor.json", track)
    write("meta.json", meta)

    let file = outDir.appendingPathComponent("recording.mp4")
    let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    emit([
      "event": "stopped", "reason": reason, "durationMs": durationMs.rounded(), "frames": frames,
      "idleFrames": idle, "droppedFrames": dropped, "bytes": bytes ?? 0, "events": track.count,
      "windowMoved": moved, "resized": resized, "t0Host": t0Host ?? 0,
      "arrivalLagMsMean": frames > 0 ? r1(arrivalLagSum / Double(frames + dropped) * 1000) : 0,
      "arrivalLagMsMax": r1(arrivalLagMax * 1000),
      "writerStatus": writer.status.rawValue, "writerError": writer.error?.localizedDescription ?? "",
    ])
    done.signal()
  }
}

// MARK: verbs

func cmdCheck() {
  emit([
    "event": "check", "protocol": PROTOCOL,
    "screenRecording": CGPreflightScreenCaptureAccess(),
    "accessibility": AXIsProcessTrusted(),
    "path": CommandLine.arguments[0],
    "bundleId": Bundle.main.bundleIdentifier ?? "",
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
  ])
}

func shareable() async -> SCShareableContent {
  do {
    return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
  } catch {
    fail("screen-recording", "Screen Recording is not granted to the process that launched this: \(error.localizedDescription)")
  }
}

func cmdWindows() async {
  let content = await shareable()
  for w in content.windows where w.windowLayer == 0 && w.frame.width >= 120 && w.frame.height >= 80 {
    emit([
      "event": "window", "id": Int(w.windowID), "app": w.owningApplication?.applicationName ?? "",
      "appId": w.owningApplication?.bundleIdentifier ?? "", "titled": !(w.title ?? "").isEmpty,
      "frame": ["x": w.frame.minX, "y": w.frame.minY, "w": w.frame.width, "h": w.frame.height],
    ])
  }
}

func cmdRecord(_ json: String) async {
  guard let data = json.data(using: .utf8),
    let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { fail("bad-request", "The record request is not JSON.") }
  guard let out = req["out"] as? String else { fail("bad-request", "The request names no out directory.") }
  let content = await shareable()
  let candidates = content.windows.filter { $0.windowLayer == 0 && $0.frame.width >= 120 && $0.frame.height >= 80 }
  var window: SCWindow?
  if let id = req["window"] as? Int {
    window = candidates.first { Int($0.windowID) == id }
  } else if let app = req["app"] as? String {
    let match = candidates.filter {
      $0.owningApplication?.applicationName == app || $0.owningApplication?.bundleIdentifier == app
    }
    window = match.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
  }
  guard let w = window else { fail("no-window", "No window on screen matches the request.") }

  let rec = Recorder(
    windowID: w.windowID, outDir: URL(fileURLWithPath: out), fps: req["fps"] as? Int ?? 60,
    bitrate: req["bitrate"] as? Int ?? 8_000_000, pointer: req["pointer"] as? Bool ?? true,
    frames: req["frames"] as? Bool ?? false, surface: req["surface"] as? String ?? "app",
    appName: w.owningApplication?.applicationName ?? "", appID: w.owningApplication?.bundleIdentifier ?? "")
  do {
    try await rec.start(content: content, window: w, filterKind: req["filter"] as? String ?? "others-out")
  } catch {
    fail("start-failed", error.localizedDescription)
  }

  let maxSeconds = req["maxSeconds"] as? Double ?? 1800
  DispatchQueue.global().asyncAfter(deadline: .now() + maxSeconds) { Task { await rec.stop(reason: "cap") } }
  Thread.detachNewThread {
    while let line = readLine() {
      if line.trimmingCharacters(in: .whitespaces) == "stop" { break }
    }
    Task { await rec.stop(reason: "stop") }
  }
  signal(SIGINT, SIG_IGN)
  let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
  sig.setEventHandler { Task { await rec.stop(reason: "interrupt") } }
  sig.resume()

  await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
    DispatchQueue.global().async {
      rec.done.wait()
      c.resume()
    }
  }
}

@main
struct Main {
  static func main() async {
    _ = NSApplication.shared  // a window-server connection, or shareable content can hang in a bare tool
    let args = CommandLine.arguments
    switch args.count > 1 ? args[1] : "" {
    case "check": cmdCheck()
    case "windows": await cmdWindows()
    case "record": await cmdRecord(args.count > 2 ? args[2] : "")
    default:
      FileHandle.standardError.write("usage: vos-capture check | windows | record '<json>'\n".data(using: .utf8)!)
      exit(2)
    }
    exit(0)
  }
}
