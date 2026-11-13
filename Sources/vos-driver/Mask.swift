// What a take keeps out of its pixels.
//
// A mask names an element of the window (a selector) or a rectangle of it (points). Every
// frame is covered there BEFORE it is encoded, so what was under a mask is in no file: not
// the recording, not anything made from it.
//
// A cover is one flat colour, taken from the edge of what it covers, so it reads as an empty
// part of the interface and carries nothing of what was there.
//
// What it cannot promise. An element is found by reading the app's accessibility tree, and
// its bounds are read again about thirty times a second. Something that appears or moves is
// covered from the next reading, so a frame or two can show it first. What must never show
// is on screen before the take begins, or is named as a rectangle.

import AVFoundation
import ApplicationServices
import CoreGraphics
import CoreVideo
import Foundation

final class Masks: @unchecked Sendable {
  struct Spec {
    /// The selector as it was written, for what the take reports.
    let selector: String?
    let steps: [SelectorStep]
    /// A rectangle of the window, in its points.
    let rect: CGRect?
  }

  /// Points added around what is covered: a glyph's overhang, a focus ring.
  static let PAD: CGFloat = 2
  /// How long a place stays covered after its element left it: a frame taken a moment ago
  /// may still show it there.
  static let TRAIL_SECONDS = 0.25
  /// How often the bounds of what is covered are read again.
  static let READ_SECONDS = 1.0 / 30.0
  /// The least time between two searches of the tree for new matches.
  static let SEARCH_SECONDS = 0.25

  let pid: pid_t
  let windowID: CGWindowID
  let specs: [Spec]

  private let lock = NSLock()
  /// What each selector matched at the last search.
  private var elements: [[AXUIElement]]
  /// The most elements each mask has covered at once.
  private var most: [Int]
  /// What is covered now, in the window's points.
  private var covered: [CGRect] = []
  /// Places covered a moment ago, with the host time each stops being covered.
  private var trailing: [(rect: CGRect, until: Double)] = []
  private var searchAt = 0.0
  private var paintedCount = 0

  private let q = DispatchQueue(label: "vos.driver.mask")
  private var timer: DispatchSourceTimer?

  init(pid: pid_t, windowID: CGWindowID, specs: [Spec]) {
    self.pid = pid
    self.windowID = windowID
    self.specs = specs
    elements = Array(repeating: [], count: specs.count)
    most = Array(repeating: 0, count: specs.count)
  }

  /// The masks of a record request: a list of `{ selector }` and `{ x, y, w, h }`.
  static func parse(_ raw: Any?) throws -> [Spec] {
    guard let raw else { return [] }
    guard let list = raw as? [[String: Any]] else {
      throw SelectorError(message: "mask is a list of { selector } or { x, y, w, h }.")
    }
    return try list.map { item in
      if let selector = item["selector"] as? String {
        return Spec(selector: selector, steps: try parseSelector(selector), rect: nil)
      }
      func n(_ k: String) -> Double? { (item[k] as? NSNumber)?.doubleValue }
      guard let x = n("x"), let y = n("y"), let w = n("w"), let h = n("h"), w > 0, h > 0 else {
        throw SelectorError(message: "A mask is { selector } or { x, y, w, h } with a size above 0.")
      }
      return Spec(selector: nil, steps: [], rect: CGRect(x: x, y: y, width: w, height: h))
    }
  }

  // MARK: reading the app

  /// Finds what every selector matches now, then reads where it all is.
  func search() {
    guard let frame = windowFrame(windowID) else { return }
    let needsTree = specs.contains { $0.selector != nil }
    var found: [[AXUIElement]] = Array(repeating: [], count: specs.count)
    if needsTree, let window = windowElement(pid, frame: frame), let root = readTree(window) {
      for (i, spec) in specs.enumerated() where spec.selector != nil {
        found[i] = select(spec.steps, in: root).map { $0.element }
      }
    }
    locked(lock) {
      elements = found
      for (i, f) in found.enumerated() { most[i] = max(most[i], f.count) }
    }
    read()
  }

  /// Reads where each covered element is now. Cheap: two attributes an element.
  func read() {
    guard let frame = windowFrame(windowID) else { return }
    let held = locked(lock) { elements }
    var next: [CGRect] = []
    for (i, spec) in specs.enumerated() {
      if let r = spec.rect {
        next.append(r)
        continue
      }
      for el in held[i] {
        guard let g = axRect(el), g.width > 0, g.height > 0 else { continue }
        next.append(g.offsetBy(dx: -frame.minX, dy: -frame.minY))
      }
    }
    let now = CACurrentMediaTime()
    locked(lock) {
      for old in covered where !next.contains(where: { $0.equalTo(old) }) {
        trailing.append((old, now + Masks.TRAIL_SECONDS))
      }
      trailing.removeAll { $0.until < now }
      covered = next
    }
  }

  /// Before the first frame: what is on screen now is covered from the start.
  func begin() {
    search()
    let t = DispatchSource.makeTimerSource(queue: q)
    t.schedule(deadline: .now() + Masks.READ_SECONDS, repeating: Masks.READ_SECONDS)
    t.setEventHandler { [weak self] in self?.tick() }
    t.resume()
    timer = t
  }

  func end() { timer?.cancel() }

  /// The interface is about to change (a script acted): look for new matches at once.
  func soon() { locked(lock) { searchAt = 0 } }

  private func tick() {
    let now = CACurrentMediaTime()
    guard now >= locked(lock, { searchAt }) else {
      read()
      return
    }
    search()
    // A large tree takes long to read; searching it back to back would starve the readings.
    let took = CACurrentMediaTime() - now
    locked(lock) { searchAt = CACurrentMediaTime() + max(Masks.SEARCH_SECONDS, took * 4) }
  }

  /// How many elements each mask covers now, in the order they were given.
  var matched: [Int] { locked(lock) { elements.enumerated().map { specs[$0.offset].rect != nil ? 1 : $0.element.count } } }

  /// What the take says of its masks when it ends.
  var report: [[String: Any]] {
    let top = locked(lock) { most }
    return specs.enumerated().map { i, spec in
      if let r = spec.rect {
        return ["rect": ["x": r1(r.minX), "y": r1(r.minY), "w": r1(r.width), "h": r1(r.height)], "matched": 1]
      }
      return ["selector": spec.selector ?? "", "matched": top[i]]
    }
  }

  var painted: Int { locked(lock) { paintedCount } }

  // MARK: covering a frame

  /// A copy of a frame with every mask covered, or nil when no copy could be made. The
  /// caller writes nothing in that case: a frame that could not be covered is not a frame
  /// of the take.
  func covering(_ source: CVPixelBuffer, pool: CVPixelBufferPool, window: CGSize) -> CVPixelBuffer? {
    var made: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let out = made,
      CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
      CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(out),
      CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(out)
    else { return nil }
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(out, [])
    defer {
      CVPixelBufferUnlockBaseAddress(out, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(out) else { return nil }
    let w = CVPixelBufferGetWidth(out)
    let h = CVPixelBufferGetHeight(out)
    let fromStride = CVPixelBufferGetBytesPerRow(source)
    let toStride = CVPixelBufferGetBytesPerRow(out)
    if fromStride == toStride {
      memcpy(to, from, fromStride * h)
    } else {
      for y in 0..<h { memcpy(to + y * toStride, from + y * fromStride, w * 4) }
    }

    let now = CACurrentMediaTime()
    let rects = locked(lock) { covered + trailing.filter { $0.until >= now }.map { $0.rect } }
    guard window.width > 0, window.height > 0 else { return nil }
    let sx = CGFloat(w) / window.width
    let sy = CGFloat(h) / window.height
    for r in rects {
      let p = r.insetBy(dx: -Masks.PAD, dy: -Masks.PAD)
      let x0 = max(0, Int((p.minX * sx).rounded(.down)))
      let y0 = max(0, Int((p.minY * sy).rounded(.down)))
      let x1 = min(w, Int((p.maxX * sx).rounded(.up)))
      let y1 = min(h, Int((p.maxY * sy).rounded(.up)))
      guard x1 > x0, y1 > y0 else { continue }
      fill(to, stride: toStride, x0: x0, y0: y0, x1: x1, y1: y1)
    }
    locked(lock) { paintedCount += 1 }
    return out
  }

  /// One flat colour over a rectangle: the mean of its own outline, which is the surface it
  /// sits on far more often than it is what the rectangle holds.
  private func fill(_ base: UnsafeMutableRawPointer, stride: Int, x0: Int, y0: Int, x1: Int, y1: Int) {
    var sum = (b: 0, g: 0, r: 0)
    var count = 0
    func add(_ x: Int, _ y: Int) {
      let p = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
      sum.b += Int(p[0])
      sum.g += Int(p[1])
      sum.r += Int(p[2])
      count += 1
    }
    for x in x0..<x1 {
      add(x, y0)
      add(x, y1 - 1)
    }
    for y in y0..<y1 {
      add(x0, y)
      add(x1 - 1, y)
    }
    let n = max(1, count)
    let pixel: [UInt8] = [UInt8(sum.b / n), UInt8(sum.g / n), UInt8(sum.r / n), 255]
    var row = [UInt8](repeating: 0, count: (x1 - x0) * 4)
    for i in 0..<(x1 - x0) {
      row[i * 4] = pixel[0]
      row[i * 4 + 1] = pixel[1]
      row[i * 4 + 2] = pixel[2]
      row[i * 4 + 3] = pixel[3]
    }
    row.withUnsafeBytes { bytes in
      for y in y0..<y1 { memcpy(base.advanced(by: y * stride + x0 * 4), bytes.baseAddress!, bytes.count) }
    }
  }
}
