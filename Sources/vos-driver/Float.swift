import CoreVideo
import Foundation

// A floating stage: the windows with nothing behind them.
//
// The file is H.264, which carries no transparency, so a floating take's frame holds two
// things: the picture on top, exactly as any take's, and under it a strip holding the
// MATTE, which says how much of each pixel of the picture is a window (white) and how much
// is nothing (black). Whoever plays the take draws the picture through the matte.
//
// The matte is smaller than the picture (a window's edge is rebuilt from it, and an edge
// needs far fewer samples than what is inside it), and it is cut into bands laid side by
// side so the strip is short:
//
//     +--------------------------------+
//     |            picture             |   w x h
//     |                                |
//     +----------+----------+----------+
//     | band 0   | band 1   |  ...     |   each (w / scale) wide, bandH tall
//     +----------+----------+----------+
//
// Band n holds the matte's rows n * bandH ..< (n + 1) * bandH. The matte as a whole is
// `w` x `h` pixels of its own (the picture's size divided by `scale`, rounded as said in
// the `ready` event, which gives every number here).

/// What a decoder that plays H.264 level 5.2 has to take: this many macroblocks in a frame,
/// and this many a second. A take stays inside both where it can: past them a browser's
/// decoders stop agreeing.
let LEVEL_52_MACROBLOCKS = 36864
let LEVEL_52_MACROBLOCKS_A_SECOND = 2_073_600

struct Matte {
  /// How many picture pixels one matte pixel stands for, each way.
  let scale: Int
  /// The matte's own size.
  let w: Int
  let h: Int
  /// The rows of the matte one band holds, and how many bands there are.
  let bandH: Int
  let bands: Int
  /// The picture's size, and the strip's height under it.
  let pictureW: Int
  let pictureH: Int
  let strip: Int

  /// The largest matte that keeps the whole frame inside level 5.2 at this frame rate; the
  /// smallest matte when none does.
  static func layout(width w: Int, height h: Int, fps: Int) -> Matte {
    func made(_ k: Int) -> Matte {
      let mw = w / k
      let mh = (h + k - 1) / k
      let bandH = (mh + k - 1) / k
      return Matte(
        scale: k, w: mw, h: mh, bandH: bandH, bands: k, pictureW: w, pictureH: h, strip: bandH + bandH % 2)
    }
    let tried = [2, 3, 4].map(made)
    let most = min(LEVEL_52_MACROBLOCKS, LEVEL_52_MACROBLOCKS_A_SECOND / max(1, fps))
    return tried.first { ((w + 15) / 16) * ((h + $0.strip + 15) / 16) <= most } ?? tried[2]
  }

  var json: [String: Any] {
    ["y": pictureH, "w": w, "h": h, "bands": bands, "bandHeight": bandH, "height": pictureH + strip]
  }

  /// Writes the matte of `source` (a frame of the picture, with its own alpha) into the
  /// strip of `out` (a frame of the file, whose top already holds the picture).
  func pack(_ source: CVPixelBuffer, into out: CVPixelBuffer) -> Bool {
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
      CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_32BGRA,
      CVPixelBufferGetWidth(source) == pictureW, CVPixelBufferGetHeight(source) == pictureH,
      CVPixelBufferGetWidth(out) == pictureW, CVPixelBufferGetHeight(out) == pictureH + strip
    else { return false }
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(out, [])
    defer {
      CVPixelBufferUnlockBaseAddress(out, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(out) else {
      return false
    }
    let fromStride = CVPixelBufferGetBytesPerRow(source)
    let toStride = CVPixelBufferGetBytesPerRow(out)
    let src = from.assumingMemoryBound(to: UInt8.self)
    let dst = to.assumingMemoryBound(to: UInt8.self)
    // The strip starts as nothing: a pooled buffer comes back holding an earlier frame.
    memset(to + pictureH * toStride, 0, strip * toStride)
    let k = scale
    let area = k * k
    DispatchQueue.concurrentPerform(iterations: h) { my in
      let band = my / bandH
      let row = dst + (pictureH + my % bandH) * toStride + band * w * 4
      let y0 = my * k
      for mx in 0..<w {
        var sum = 0
        for j in 0..<k {
          // The last rows of the matte can stand past the picture's last row: it repeats.
          let line = src + min(pictureH - 1, y0 + j) * fromStride + mx * k * 4 + 3
          for i in 0..<k { sum += Int(line[i * 4]) }
        }
        let a = UInt8(sum / area)
        let p = row + mx * 4
        p[0] = a
        p[1] = a
        p[2] = a
        p[3] = 255
      }
    }
    return true
  }
}
