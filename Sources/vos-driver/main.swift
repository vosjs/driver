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

/// How long the frame in hand may take to finish when a take ends.
let DRAIN_SECONDS = 5.0

/// How long a take may take to begin, from the request to the first frame in the file. Past
/// it the helper says where it was and leaves: it never waits for good, whatever stalled.
let BEGIN_SECONDS = 20.0

/// How long frames are held for an owner the system's list of applications does not have yet.
/// An application that has just opened its first window takes a moment to be listed; one that
/// is still not listed after this is not going to be.
let STRANGER_SECONDS = 2.0

/// No window's corners are rounder than this. A corner that reads rounder is a window that
/// is black where it meets the black outside it, and says nothing about its shape.
let CORNER_CEILING_POINTS = 40.0

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

/// True when everything already on the queue has run within the time given.
func drains(_ queue: DispatchQueue, within seconds: Double) -> Bool {
  let drained = DispatchSemaphore(value: 0)
  queue.async { drained.signal() }
  return drained.wait(timeout: .now() + seconds) == .success
}

// MARK: progress

/// Where a take is on its way to its first frame, so a take that never begins can say where
/// it stopped. Written from the task that starts the take, read by the limit that ends it.
final class Progress: @unchecked Sendable {
  private let lock = NSLock()
  private var stageNow = "reading the request"
  private var hasBegun = false
  private var accountNow: (@Sendable () -> String)?

  var stage: String { locked(lock) { stageNow } }
  var begun: Bool { locked(lock) { hasBegun } }
  /// What became of the frames so far, once there is a writer to ask.
  var account: String { locked(lock) { accountNow }?() ?? "" }

  func at(_ stage: String) { locked(lock) { stageNow = stage } }
  func begin() { locked(lock) { hasBegun = true } }
  func accounting(_ account: @escaping @Sendable () -> String) { locked(lock) { accountNow = account } }
}
let progress = Progress()

// MARK: time limits

/// A system call that did not answer in time.
struct TimedOut: Error, LocalizedError {
  let what: String
  let seconds: Double
  var errorDescription: String? { "\(what) did not answer within \(Int(seconds)) s." }
}

/// How long the system may take to list windows, and to start or stop a capture.
let SYSTEM_SECONDS = 10.0

/// A value crossing from the task that made it to the one waiting for it.
struct Handed<T>: @unchecked Sendable { let value: T }

/// The first of two outcomes wins; the other is dropped.
final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var taken = false
  func claim() -> Bool {
    locked(lock) {
      if taken { return false }
      taken = true
      return true
    }
  }
}

/// Runs a system call with a limit. ScreenCaptureKit's calls can stall and do not hear a
/// cancellation, so this does not wait for the stalled one: it answers `TimedOut` and leaves
/// it behind. The helper exits soon after, which ends it.
func limited<T>(
  _ what: String, seconds: Double = SYSTEM_SECONDS, _ call: @escaping @Sendable () async throws -> Handed<T>
) async throws -> T {
  try await withCheckedThrowingContinuation { (c: CheckedContinuation<Handed<T>, Error>) in
    let once = Once()
    Task {
      do {
        let value = try await call()
        if once.claim() { c.resume(returning: value) }
      } catch {
        if once.claim() { c.resume(throwing: error) }
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
      if once.claim() { c.resume(throwing: TimedOut(what: what, seconds: seconds)) }
    }
  }.value
}

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

  // The capture follows the window and keeps every other application out, for the whole
  // take. All of this is read and written on `watchQ` alone.
  let watchQ = DispatchQueue(label: "vos.driver.window")
  var watcher: DispatchSourceTimer?
  let config = SCStreamConfiguration()
  /// What the capture paints where the app is not. The configuration does not keep it alive.
  let outside = CGColor(gray: 0, alpha: 1)
  /// True when the capture is a rectangle of a display (it must be moved with the window).
  var followsWindow = false
  /// True when other applications are kept out by a list (it must be kept current).
  var excludesOthers = false
  var displayID: CGDirectDisplayID = 0
  var displayOrigin: CGPoint = .zero
  var appPID: pid_t = 0
  /// The rectangle of the display the capture was last told to take.
  var appliedRect: CGRect = .zero
  var moving = false
  var nextMoveAt = 0.0
  var sourceUpdates = 0
  var refreshing = false
  var filterRefreshes = 0
  var saidBeyond = false

  // Who is kept out of the picture. Read by the frame handler, written when the list is
  // brought up to date: behind `exLock`.
  let exLock = NSLock()
  /// Applications the capture excludes.
  var excluded: Set<pid_t> = []
  /// Owners of windows the capture cannot exclude (the system does not list them as
  /// applications). They are let through: holding frames for them would hold every frame.
  var ignored: Set<pid_t> = []
  /// Owners of windows seen over this one and not yet excluded or ignored, with the host
  /// time each was first seen.
  var unsettled: [pid_t: Double] = [:]
  /// Frames taken before this host time may still show an application excluded since.
  var cleanFrom = 0.0
  /// Frames held back because another application's window was over this one.
  var held = 0

  // clock: zero is the first frame the file holds, on the host clock (seconds)
  var t0Host: Double?
  var t0Wall: Double = 0
  var lastPTS: Double = 0
  var frames = 0
  var idle = 0
  var dropped = 0
  /// Frames with new pixels handed over by the capture, whatever became of them.
  var arrived = 0
  var arrivalLagSum = 0.0
  var arrivalLagMax = 0.0

  // geometry
  var pointSize: CGSize = .zero
  var pixelSize: (w: Int, h: Int) = (0, 0)
  var scale: Double = 1
  var resized = false
  var moved = false
  var firstFrame: CGRect = .zero
  /// The radius of the window's own rounded corners, in points; 0 when it has none or it
  /// could not be read. Outside it the recording is opaque black.
  var cornerRadius = 0.0

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
    progress.at("scoping the capture to the window")
    let filter: SCContentFilter
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
        excludesOthers = true
        excluded = Set(others.map { $0.processID })
      }
      // A rectangle of the display, where the window is now. It does not move by itself.
      followsWindow = true
      displayID = display.displayID
      displayOrigin = display.frame.origin
      appPID = app.processID
      appliedRect = CGRect(
        x: frame.minX - display.frame.minX, y: frame.minY - display.frame.minY, width: frame.width,
        height: frame.height)
      config.sourceRect = appliedRect
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
    // What is not the app is black: the window's own shape is read from that
    // (see cornerRadiusPoints), and the file has no alpha to say it another way.
    config.backgroundColor = outside

    progress.at("opening the recording file")
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
    progress.accounting { [weak self] in self?.frameAccount ?? "" }

    progress.at("starting the capture")

    // Everything the frame handler and `stop` read is in place BEFORE the capture starts:
    // frames can arrive before `startCapture` returns, and on a slow machine they do.
    //
    // `ready` is said when the first frame is in the file (see the frame handler): only then
    // does the take have a time zero for anything that follows to be measured against.
    readyEvent = [
      "event": "ready", "protocol": PROTOCOL, "window": Int(windowID), "app": appName,
      "frame": ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height],
      "scale": scale, "captureWidth": w, "captureHeight": h, "filter": filterKind,
      "accessibility": AXIsProcessTrusted(),
    ]
    let s = SCStream(filter: filter, configuration: config, delegate: self)
    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQ)
    stream = s
    try await limited("The start of the capture") {
      try await s.startCapture()
      return Handed(value: ())
    }
    progress.at("waiting for the window's first frame to reach the file")
    startWatching()

    // A take with no frame in its file would leave the caller waiting on `ready` for good:
    // a window that never draws, or frames the writer will not take.
    DispatchQueue.global().asyncAfter(deadline: .now() + FIRST_FRAME_SECONDS) { [weak self] in
      guard let self, self.frames == 0 else { return }
      Task { await self.stop(reason: "no frame in the file after \(Int(FIRST_FRAME_SECONDS)) s") }
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
    arrived += 1
    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
    let now = CACurrentMediaTime()
    // Another application's window over this one is not in the take, not for one frame: a
    // frame that may show one is held back, and the picture keeps its last clean frame.
    if excludesOthers {
      if let strangers = strangersOver() {
        held += 1
        exclude(strangers)
        return
      }
      if pts < locked(exLock, { cleanFrom }) {
        held += 1
        return
      }
    }
    let lag = now - pts
    arrivalLagSum += lag
    arrivalLagMax = max(arrivalLagMax, lag)
    // A frame the writer cannot take now is let go (an encoder still warming up does this).
    // It defines nothing: time zero is the first frame that REACHES the file.
    guard input.isReadyForMoreMediaData else {
      dropped += 1
      return
    }
    if t0Host == nil {
      t0Host = pts
      t0Wall = Date().timeIntervalSince1970 * 1000 - (now - pts) * 1000
      writer.startSession(atSourceTime: .zero)
    }
    let rel = pts - t0Host!
    // Times in the file only go forward.
    guard frames == 0 || rel > lastPTS else {
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
        progress.begin()
        cornerRadius = cornerRadiusPoints(sb)
        readyEvent["cornerRadius"] = r1(cornerRadius)
        emit(readyEvent)
        if wantPointer { startPointer() }
      }
    } else {
      dropped += 1
      // A writer that has failed takes no more frames: end the take now and say why.
      if writer.status == .failed { Task { await self.stop(reason: "the writer failed") } }
    }
  }

  /// What became of the frames, for an error that has to explain a take with none.
  var frameAccount: String {
    var text =
      "\(arrived) arrived, \(frames) written, \(dropped) refused, \(held) held back, \(idle) unchanged; writer state \(writer.status.rawValue)"
    if let error = writer.error { text += "; the writer said: \(error)" }
    return text
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    emit(["event": "notice", "code": "stream-stopped", "message": error.localizedDescription])
    Task { await self.stop(reason: "stream-stopped") }
  }

  // MARK: the window, for the length of the take

  /// How round a frame around this window must be, read from a frame of it: the radius of
  /// the smallest circular corner that covers ALL the black outside the window's own corners.
  ///
  /// A window's corner is not a circle (macOS draws a continuous curve), and its edge is
  /// anti-aliased against the black, so its extent along one edge says too little: a circle
  /// that only reaches that far leaves a sliver of black showing. At each corner this takes
  /// the black that is connected to the corner pixel, and for every pixel of it the radius a
  /// circle tangent to both edges needs to leave that pixel outside.
  ///
  /// A corner whose black runs on past any window's roundness is a window that is itself
  /// black there: it says nothing about its shape and is left out, and what is black against
  /// black needs no rounding. 0 when no corner can be read, or the corners are square.
  func cornerRadiusPoints(_ sb: CMSampleBuffer) -> Double {
    guard followsWindow, let pb = CMSampleBufferGetImageBuffer(sb),
      CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA
    else { return 0 }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0 }
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let pixelsPerPoint = Double(w) / max(1, Double(pointSize.width))
    let box = Int(CORNER_CEILING_POINTS * pixelsPerPoint)
    guard box > 1, min(w, h) > 2 * box else { return 0 }
    /// Black to the eye: the outside, and the faint edge pixels that are mostly outside.
    func outside(_ x: Int, _ y: Int) -> Bool {
      let i = y * stride + x * 4
      return bytes[i] <= 16 && bytes[i + 1] <= 16 && bytes[i + 2] <= 16
    }
    /// The radius one corner needs, in pixels; nil when it cannot be read. (cx, cy) is the
    /// corner pixel and (sx, sy) points into the frame.
    func need(_ cx: Int, _ cy: Int, _ sx: Int, _ sy: Int) -> Double? {
      guard outside(cx, cy) else { return 0 }  // a square corner
      var seen = [Bool](repeating: false, count: box * box)
      var stack = [(0, 0)]
      seen[0] = true
      var most = 0.0
      while let (x, y) = stack.popLast() {
        // Black that reaches the edge of the box is not a corner's.
        if x == box - 1 || y == box - 1 { return nil }
        // The far corner of the pixel: the whole pixel must fall outside the circle.
        let fx = Double(x + 1)
        let fy = Double(y + 1)
        most = max(most, fx + fy + (2 * fx * fy).squareRoot())
        for (nx, ny) in [(x + 1, y), (x, y + 1), (x - 1, y), (x, y - 1)] where nx >= 0 && ny >= 0 {
          let i = ny * box + nx
          if !seen[i] && outside(cx + sx * nx, cy + sy * ny) {
            seen[i] = true
            stack.append((nx, ny))
          }
        }
      }
      return most <= Double(box) ? most : nil
    }
    let corners = [need(0, 0, 1, 1), need(w - 1, 0, -1, 1), need(0, h - 1, 1, -1), need(w - 1, h - 1, -1, -1)]
    guard let most = corners.compactMap({ $0 }).max() else { return 0 }
    return most / pixelsPerPoint
  }

  func startWatching() {
    guard followsWindow else { return }
    let t = DispatchSource.makeTimerSource(queue: watchQ)
    t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
    t.setEventHandler { [weak self] in self?.watch() }
    t.resume()
    watcher = t
  }

  /// One look at the window, sixty times a second: move the capture if the window moved.
  func watch() {
    guard !finished, let win = windowFrame(windowID) else { return }
    if abs(win.width - firstFrame.width) > 1 || abs(win.height - firstFrame.height) > 1 { resized = true }
    if abs(win.minX - firstFrame.minX) > 1 || abs(win.minY - firstFrame.minY) > 1 { moved = true }
    follow(win, CACurrentMediaTime())
  }

  /// The capture is a rectangle of the display. When the window leaves it, the rectangle goes
  /// with the window, so the picture stays the window's as the pointer's track does.
  func follow(_ win: CGRect, _ now: Double) {
    let want = CGRect(
      x: win.minX - displayOrigin.x, y: win.minY - displayOrigin.y, width: win.width, height: win.height)
    let same =
      abs(want.minX - appliedRect.minX) < 0.5 && abs(want.minY - appliedRect.minY) < 0.5
      && abs(want.width - appliedRect.width) < 0.5 && abs(want.height - appliedRect.height) < 0.5
    guard !same, !moving, now >= nextMoveAt, let s = stream else { return }
    moving = true
    config.sourceRect = want
    let config = self.config
    Task {
      var moved = false
      do {
        try await limited("Moving the capture with the window", seconds: 3) {
          try await s.updateConfiguration(config)
          return Handed(value: ())
        }
        moved = true
      } catch {}
      let done = moved
      self.watchQ.async {
        if done {
          self.appliedRect = want
          self.sourceUpdates += 1
        } else {
          // A rectangle the display cannot give (the window is leaving it): not every tick.
          self.nextMoveAt = CACurrentMediaTime() + 0.5
        }
        self.moving = false
      }
    }
  }

  /// The owners of windows that are over this one right now and are neither excluded from
  /// the capture nor known to be beyond excluding. Nil when there are none.
  ///
  /// The applications to keep out are a list, made when the capture started. One that opens
  /// a window later (a notification, an app launched mid-take) is not on it yet, and its
  /// window is in the frames until it is. This is how a frame knows.
  func strangersOver() -> Set<pid_t>? {
    guard
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return nil }
    var mine: CGRect?
    var others: [(pid_t, CGRect)] = []
    for info in list {
      guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        let b = info[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: b as CFDictionary)
      else { continue }
      if (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID {
        mine = bounds
      } else if pid != appPID, ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0 {
        others.append((pid, bounds))
      }
    }
    guard let rect = mine else { return nil }
    let (out, beyond) = locked(exLock) { (excluded, ignored) }
    var found = Set<pid_t>()
    for (pid, bounds) in others where !out.contains(pid) && !beyond.contains(pid) && bounds.intersects(rect) {
      found.insert(pid)
    }
    return found.isEmpty ? nil : found
  }

  /// Asks for these owners to be kept out, and holds frames until they are.
  func exclude(_ strangers: Set<pid_t>) {
    let now = CACurrentMediaTime()
    locked(exLock) {
      for pid in strangers where unsettled[pid] == nil { unsettled[pid] = now }
    }
    watchQ.async { self.refreshExclusions() }
  }

  /// Brings the capture's list of excluded applications up to date, then settles every
  /// owner that was asked about: excluded now, or beyond excluding and let through.
  func refreshExclusions() {
    guard !refreshing, !finished, let s = stream else { return }
    let asked = locked(exLock) { unsettled }
    guard !asked.isEmpty else { return }
    refreshing = true
    Task {
      var now: Set<pid_t>?
      if let content = try? await limited("The list of running applications", seconds: 3, {
        Handed(value: try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
      }), let display = content.displays.first(where: { $0.displayID == self.displayID }) {
        let others = content.applications.filter { $0.processID != self.appPID }
        let filter = SCContentFilter(display: display, excludingApplications: others, exceptingWindows: [])
        let updated: Void? = try? await limited("Keeping other applications out of the capture", seconds: 3) {
          try await s.updateContentFilter(filter)
          return Handed(value: ())
        }
        if updated != nil { now = Set(others.map { $0.processID }) }
      }
      let applied = now
      let since = CACurrentMediaTime()
      self.watchQ.async {
        let beyond: Set<pid_t> = locked(self.exLock) {
          if let applied {
            self.excluded = applied
            // Frames taken before now were taken under the old list.
            self.cleanFrom = since
          }
          var given = Set<pid_t>()
          for (pid, firstSeen) in asked {
            if self.excluded.contains(pid) {
              self.unsettled[pid] = nil
            } else if since - firstSeen >= STRANGER_SECONDS {
              // Still not on the system's list of applications after this long: it will not
              // be, and holding frames for it would hold them for good. It is let through.
              self.unsettled[pid] = nil
              self.ignored.insert(pid)
              given.insert(pid)
            }
            // Otherwise it stays unsettled: an application that has only just opened its
            // window may not be on the list yet. Frames stay held and the next one asks again.
          }
          return given
        }
        if applied != nil { self.filterRefreshes += 1 }
        if !beyond.isEmpty, !self.saidBeyond {
          self.saidBeyond = true
          emit([
            "event": "notice", "code": "not-excludable",
            "message":
              "A window over this one could not be kept out of the capture: the system does not list its owner as an application.",
          ])
        }
        self.refreshing = false
      }
    }
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
    watcher?.cancel()
    // A capture that will not stop must not keep the take from being written.
    if let s = stream {
      do {
        try await limited("The end of the capture") {
          try await s.stopCapture()
          return Handed(value: ())
        }
      } catch let late as TimedOut {
        emit(["event": "notice", "code": "slow-stop", "message": late.localizedDescription])
      } catch {}
    }
    // Let the frame in hand finish. If the encoder is stuck inside it, the writer cannot be
    // finished and waiting would never end: say so and leave.
    if !drains(videoQ, within: DRAIN_SECONDS) {
      emit([
        "event": "error", "code": "write-failed",
        "message":
          "The video encoder stopped answering while the take ended (\(reason)): \(frameAccount). The recording is not complete.",
      ])
      exit(1)
    }

    // No frame in the file: there is no take. Either the window drew nothing, or the writer
    // refused what it was given, and the error says which.
    guard frames > 0 else {
      let account = frameAccount
      let failed = writer.status == .failed
      if writer.status == .writing { writer.cancelWriting() }
      try? FileManager.default.removeItem(at: recordingFile)
      emit([
        "event": "error", "code": failed ? "write-failed" : "no-frames",
        "message": "No frame reached the recording before the take ended (\(reason)): \(account).",
      ])
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
    if cornerRadius > 0 { meta["cornerRadius"] = r1(cornerRadius) }
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
      "sourceUpdates": watchQ.sync { sourceUpdates }, "filterRefreshes": watchQ.sync { filterRefreshes },
      "heldFrames": held,
      "files": ["recording": recordingFile.path, "cursor": cursorFile.path, "meta": metaFile.path],
      "clock": [
        "t0Host": t0Host ?? 0,
        "arrivalLagMsMean": arrived > 0 ? r1(arrivalLagSum / Double(arrived) * 1000) : 0,
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
    return try await limited("The list of the screen's windows") {
      Handed(value: try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
    }
  } catch let late as TimedOut {
    fail("start-failed", late.localizedDescription)
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

  // Whatever stalls on the way to the first frame, the caller hears about it.
  DispatchQueue.global().asyncAfter(deadline: .now() + BEGIN_SECONDS) {
    guard !progress.begun else { return }
    let account = progress.account
    emit([
      "event": "error", "code": "start-failed",
      "message":
        "The take did not begin within \(Int(BEGIN_SECONDS)) s. It was \(progress.stage)\(account.isEmpty ? "" : " (\(account))").",
    ])
    exit(1)
  }

  progress.at("listing the screen's windows")
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
