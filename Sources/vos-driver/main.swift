// vos-driver: a headless helper that records one application window for a vos take.
// One process per take, no window of its own, no settings, no state.
//
//   vos-driver version               the helper's version and protocol, as JSON
//   vos-driver check                 permissions, as JSON (run from a fresh process: the answer is cached)
//   vos-driver windows               windows that can be recorded, one JSON object per line
//   vos-driver record '<json>'       record one window; JSON lines on stdout: `ready` once the
//                                    first frame is in the file, then `stopped` or `error`
//
// A record request:
//   { "window": 1234,          a window id from `windows`, or
//     "app": "TextEdit",       an application's name or bundle id (its largest titled window)
//     "out": "/path/take",     a directory: recording.mp4, cursor.json and meta.json are written there
//     "fps": 60,               the frame-rate ceiling
//     "bitrate": 8000000,      the encoder's average bit rate
//     "maxSeconds": 3600,      a safety ceiling; pass your own
//     "pointer": true,         sample the real pointer (a performed take)
//     "frames": false,         read the bounds of what was pressed (needs Accessibility)
//     "filter": "others-out" } how the window is scoped; see FILTERS
//
// A take ends on `stop` and a newline on stdin, on SIGINT or SIGTERM, at maxSeconds, when the
// capture stream stops, or when stdin is a pipe and it closes (the process that started this is
// gone). End of input on a terminal, /dev/null or a file ends nothing.
//
// What this never does:
//   - put the system pointer in the pixels;
//   - learn what was typed: typing is the system's COUNT of key-downs going up, and no key code
//     ever reaches this process;
//   - sample on a timer: a parked pointer writes nothing, because the planners read the silence.

import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// The wire protocol's version. It moves when a request field or an event changes meaning.
let PROTOCOL = 1

/// How the window is scoped. `others-out` is the display with every OTHER application excluded,
/// cropped to the window: scope by exclusion. The rest name the window or its app, and on
/// macOS 26 that makes the system draw its sharing control over the window's traffic lights,
/// where it lands in the pixels. They are kept for measuring other macOS versions.
let FILTERS = ["others-out", "window", "app", "display-window", "display"]

/// How long a window may take to produce its first frame before the take is given up.
let FIRST_FRAME_SECONDS = 5.0

// MARK: output

let outLock = NSLock()
func locked<T>(_ lock: NSLock, _ body: () -> T) -> T {
  lock.lock()
  defer { lock.unlock() }
  return body()
}
func emit(_ obj: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
    var line = String(data: data, encoding: .utf8)
  else { return }
  line += "\n"
  locked(outLock) { FileHandle.standardOutput.write(line.data(using: .utf8)!) }
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

/// One take. Its state is touched from three places and each has its own guard: frames on
/// `videoQ`, pointer samples on `pointerQ` (the track behind `evLock`), and the end of the take
/// behind `stopLock`. Hence unchecked.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let windowID: CGWindowID
  let outDir: URL
  let fps: Int
  let bitrate: Int
  let wantPointer: Bool
  let wantFrames: Bool
  let appName: String
  let appID: String

  var stream: SCStream?
  var writer: AVAssetWriter!
  var input: AVAssetWriterInput!
  let videoQ = DispatchQueue(label: "vos.driver.video")
  let pointerQ = DispatchQueue(label: "vos.driver.pointer")
  var timer: DispatchSourceTimer?

  var readyEvent: [String: Any] = [:]

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

  let stopLock = NSLock()
  var finished = false
  /// What the process exits with once the take is over.
  var exitCode: Int32 = 0
  let done = DispatchSemaphore(value: 0)

  init(
    windowID: CGWindowID, outDir: URL, fps: Int, bitrate: Int, pointer: Bool, frames: Bool,
    appName: String, appID: String
  ) {
    self.windowID = windowID
    self.outDir = outDir
    self.fps = fps
    self.bitrate = bitrate
    self.wantPointer = pointer
    self.wantFrames = frames
    self.appName = appName
    self.appID = appID
  }

  var recordingFile: URL { outDir.appendingPathComponent("recording.mp4") }

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
      case "app": filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
      default:
        // others-out: the display with every OTHER application excluded
        let others = content.applications.filter { $0.processID != app.processID }
        filter = SCContentFilter(display: display, excludingApplications: others, exceptingWindows: [])
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

    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: recordingFile)
    writer = try AVAssetWriter(outputURL: recordingFile, fileType: .mp4)
    // Fragments while recording, so a killed process leaves more than an empty box.
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
      throw writer.error ?? NSError(domain: "vos.driver", code: 1)
    }

    let s = SCStream(filter: filter, configuration: config, delegate: self)
    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQ)
    try await s.startCapture()
    stream = s

    // `ready` is said when the first frame is in the file (see the frame handler): only then
    // does the take have a time zero for anything that follows to be measured against.
    readyEvent = [
      "event": "ready", "protocol": PROTOCOL, "window": Int(windowID), "app": appName,
      "frame": ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height],
      "scale": scale, "captureWidth": w, "captureHeight": h, "filter": filterKind,
      "accessibility": AXIsProcessTrusted(),
    ]
    // A window that never draws would leave the caller waiting on `ready` for good.
    DispatchQueue.global().asyncAfter(deadline: .now() + FIRST_FRAME_SECONDS) { [weak self] in
      guard let self, self.t0Host == nil else { return }
      Task { await self.stop(reason: "no first frame in \(Int(FIRST_FRAME_SECONDS)) s") }
    }
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
      if frames == 1 {
        emit(readyEvent)
        if wantPointer { startPointer() }
      }
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
    locked(evLock) { events.append(e) }
  }

  func sample() {
    guard let t0 = t0Host, !finished else { return }
    let t = (CACurrentMediaTime() - t0) * 1000
    guard t >= 0, let win = windowFrame(windowID), let pos = CGEvent(source: nil)?.location else { return }
    if abs(win.width - firstFrame.width) > 1 || abs(win.height - firstFrame.height) > 1 { resized = true }
    if abs(win.minX - firstFrame.minX) > 1 || abs(win.minY - firstFrame.minY) > 1 { moved = true }
    let inside = win.contains(pos)
    // The track is the WINDOW's: every sample is taken against where the window is now.
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

  /// True for the first caller only: a take ends once, whatever asked.
  func claimStop() -> Bool {
    locked(stopLock) {
      if finished { return false }
      finished = true
      return true
    }
  }

  func stop(reason: String) async {
    guard claimStop() else { return }
    timer?.cancel()
    try? await stream?.stopCapture()
    videoQ.sync {}

    // No frame ever arrived: there is no take, and the writer has no session to finish.
    guard t0Host != nil else {
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: recordingFile)
      emit(["event": "error", "code": "no-frames", "message": "The window produced no frame before the take ended (\(reason))."])
      exitCode = 1
      done.signal()
      return
    }

    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      let why = writer.error?.localizedDescription ?? "the writer ended in state \(writer.status.rawValue)"
      emit(["event": "error", "code": "write-failed", "message": "The recording could not be written: \(why)"])
      exitCode = 1
      done.signal()
      return
    }

    let durationMs = lastPTS * 1000
    let track = locked(evLock) { events.filter { ($0["t"] as? Double ?? 0) <= durationMs + 50 } }

    var meta: [String: Any] = [
      "dpr": scale, "zoom": 1, "t0": t0Wall.rounded(), "durationMs": durationMs.rounded(),
      "width": Int(pointSize.width.rounded()), "height": Int(pointSize.height.rounded()),
      "fps": fps, "captureWidth": pixelSize.w, "captureHeight": pixelSize.h,
      "captureSurface": "app", "platform": "mac", "producer": "desktop",
      "app": ["name": appName, "id": appID],
    ]
    if resized { meta["resizedDuringTake"] = true }
    let cursorFile = outDir.appendingPathComponent("cursor.json")
    let metaFile = outDir.appendingPathComponent("meta.json")
    func write(_ file: URL, _ obj: Any) -> Bool {
      guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return false }
      return (try? d.write(to: file)) != nil
    }
    guard write(cursorFile, track), write(metaFile, meta) else {
      emit(["event": "error", "code": "write-failed", "message": "The take's cursor.json or meta.json could not be written."])
      exitCode = 1
      done.signal()
      return
    }

    let attrs = try? FileManager.default.attributesOfItem(atPath: recordingFile.path)
    let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    emit([
      "event": "stopped", "reason": reason, "durationMs": durationMs.rounded(), "frames": frames,
      "idleFrames": idle, "droppedFrames": dropped, "bytes": bytes, "events": track.count,
      "windowMoved": moved, "resized": resized,
      "files": ["recording": recordingFile.path, "cursor": cursorFile.path, "meta": metaFile.path],
      "clock": [
        "t0Host": t0Host ?? 0,
        "arrivalLagMsMean": frames > 0 ? r1(arrivalLagSum / Double(frames + dropped) * 1000) : 0,
        "arrivalLagMsMax": r1(arrivalLagMax * 1000),
      ],
    ])
    done.signal()
  }
}

// MARK: verbs

func cmdVersion() {
  emit(["event": "version", "version": DRIVER_VERSION, "protocol": PROTOCOL])
}

func cmdCheck() {
  emit([
    "event": "check", "version": DRIVER_VERSION, "protocol": PROTOCOL,
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
    fail(
      "screen-recording",
      "Screen Recording is not granted to the app that launched this (\(error.localizedDescription)). Switch it on in System Settings, Privacy & Security, Screen & System Audio Recording.")
  }
}

/// Windows a take can be of: ordinary layer, big enough to be a window and not a control.
func recordable(_ content: SCShareableContent) -> [SCWindow] {
  content.windows.filter { $0.windowLayer == 0 && $0.frame.width >= 120 && $0.frame.height >= 80 }
}
func titled(_ w: SCWindow) -> Bool { !(w.title ?? "").isEmpty }

func cmdWindows() async {
  let content = await shareable()
  for w in recordable(content) {
    emit([
      "event": "window", "id": Int(w.windowID), "app": w.owningApplication?.applicationName ?? "",
      "appId": w.owningApplication?.bundleIdentifier ?? "", "titled": titled(w),
      "frame": ["x": w.frame.minX, "y": w.frame.minY, "w": w.frame.width, "h": w.frame.height],
    ])
  }
}

/// A stdin that closes because the process holding its other end is gone.
func stdinIsPipe() -> Bool {
  var st = stat()
  guard fstat(0, &st) == 0 else { return false }
  let type = st.st_mode & S_IFMT
  return type == S_IFIFO || type == S_IFSOCK
}

func cmdRecord(_ json: String) async {
  guard let data = json.data(using: .utf8),
    let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { fail("bad-request", "The record request is not a JSON object.") }
  guard let out = req["out"] as? String, !out.isEmpty else {
    fail("bad-request", "The request names no out directory.")
  }
  let filterKind = req["filter"] as? String ?? "others-out"
  guard FILTERS.contains(filterKind) else {
    fail("bad-request", "Unknown filter \"\(filterKind)\". One of: \(FILTERS.joined(separator: ", ")).")
  }
  let fps = req["fps"] as? Int ?? 60
  guard (1...120).contains(fps) else { fail("bad-request", "fps is between 1 and 120.") }
  let bitrate = req["bitrate"] as? Int ?? 8_000_000
  guard bitrate >= 100_000 else { fail("bad-request", "bitrate is at least 100000.") }
  let maxSeconds = (req["maxSeconds"] as? NSNumber)?.doubleValue ?? 3600
  guard maxSeconds > 0 else { fail("bad-request", "maxSeconds is above 0.") }
  guard req["window"] is Int || req["app"] is String else {
    fail("bad-request", "The request names no target: a window id, or an app's name or bundle id.")
  }

  let content = await shareable()
  let candidates = recordable(content)
  var window: SCWindow?
  if let id = req["window"] as? Int {
    window = candidates.first { Int($0.windowID) == id }
  } else if let app = req["app"] as? String {
    let match = candidates.filter {
      $0.owningApplication?.applicationName == app || $0.owningApplication?.bundleIdentifier == app
    }
    // An app's alert is an untitled window of its own: the app's window is a titled one first.
    let named = match.filter(titled)
    let pool = named.isEmpty ? match : named
    window = pool.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
  }
  guard let w = window else { fail("no-window", "No window on screen matches the request.") }

  let rec = Recorder(
    windowID: w.windowID, outDir: URL(fileURLWithPath: out), fps: fps, bitrate: bitrate,
    pointer: req["pointer"] as? Bool ?? true, frames: req["frames"] as? Bool ?? false,
    appName: w.owningApplication?.applicationName ?? "", appID: w.owningApplication?.bundleIdentifier ?? "")
  do {
    try await rec.start(content: content, window: w, filterKind: filterKind)
  } catch {
    fail("start-failed", error.localizedDescription)
  }

  DispatchQueue.global().asyncAfter(deadline: .now() + maxSeconds) { Task { await rec.stop(reason: "cap") } }

  let parentHoldsStdin = stdinIsPipe()
  Thread.detachNewThread {
    while let line = readLine() {
      if line.trimmingCharacters(in: .whitespaces) == "stop" {
        Task { await rec.stop(reason: "stop") }
        return
      }
    }
    // End of input. On a pipe, whatever started this is gone, and a recorder never outlives it.
    if parentHoldsStdin { Task { await rec.stop(reason: "parent-gone") } }
  }

  var signals: [DispatchSourceSignal] = []
  for (number, reason) in [(SIGINT, "interrupt"), (SIGTERM, "terminated")] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler { Task { await rec.stop(reason: reason) } }
    source.resume()
    signals.append(source)
  }

  await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
    DispatchQueue.global().async {
      rec.done.wait()
      c.resume()
    }
  }
  signals.forEach { $0.cancel() }
  exit(rec.exitCode)
}

let USAGE = "usage: vos-driver version | check | windows | record '<json>'\n"

@main
struct Main {
  static func main() async {
    let args = CommandLine.arguments
    let verb = args.count > 1 ? args[1] : ""
    if verb == "version" || verb == "--version" {
      cmdVersion()
      exit(0)
    }
    _ = NSApplication.shared  // a window-server connection, or shareable content can hang in a bare tool
    switch verb {
    case "check": cmdCheck()
    case "windows": await cmdWindows()
    case "record": await cmdRecord(args.count > 2 ? args[2] : "")
    default:
      FileHandle.standardError.write(USAGE.data(using: .utf8)!)
      exit(2)
    }
    exit(0)
  }
}
