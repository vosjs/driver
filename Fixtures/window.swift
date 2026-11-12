// A window for the tests to record and to script: titled, 480 x 320 of content in one flat
// colour, with a bar that moves so the capture has frames, and a few real controls that say
// what was done to them. It takes no focus by itself and shows no Dock icon. Its one menu is
// Edit, with Select All.
//
//   window [--color r,g,b] [--title text]
//
// The controls, each with an accessibility identifier:
//   button "Save"         id save       each press adds one to the label beside it
//   label  "clicks 0"     id clicks
//   field  (placeholder Title)  id title   what is typed is counted, never shown elsewhere
//   label  "typed 0"      id typed
//   checkbox "Remember"   id remember
//   two buttons "Again"   (no id)       the same name twice, for a selector that is not unique
//   a swatch              id swatch     white until Save is pressed, then green: what a
//                                       picture can see of a press
//
// It prints {"window": <id>} once it is on screen. On stdin, `move <dx> <dy>` moves it by
// that many points (right and down) and prints {"moved": true}; `state` prints what was done
// to it: {"clicks": n, "typed": n, "remember": bool, "again": n}. It exits when stdin closes.
import AppKit

var color: [CGFloat] = [40, 90, 160]
var title = "vos-driver fixture"
var args = Array(CommandLine.arguments.dropFirst())
while args.count >= 2 {
  let flag = args.removeFirst()
  let value = args.removeFirst()
  if flag == "--color" {
    let parts = value.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
    if parts.count == 3 { color = parts }
  } else if flag == "--title" {
    title = value
  }
}
let fill = NSColor(srgbRed: color[0] / 255, green: color[1] / 255, blue: color[2] / 255, alpha: 1)

final class Field: NSView {
  var phase: CGFloat = 0
  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    bounds.fill()
    // The moving bar stays in the middle band, so the corners and edges hold the flat colour.
    NSColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1).setFill()
    NSRect(x: 120 + phase * (bounds.width - 300), y: bounds.midY - 20, width: 60, height: 40).fill()
  }
}

final class Swatch: NSView {
  var on = false { didSet { needsDisplay = true } }
  override func draw(_ dirtyRect: NSRect) {
    (on ? NSColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1) : NSColor.white).setFill()
    bounds.fill()
  }
}

final class Controls: NSObject, NSTextFieldDelegate {
  var clicks = 0
  var again = 0
  let clicksLabel = NSTextField(labelWithString: "clicks 0")
  let typedLabel = NSTextField(labelWithString: "typed 0")
  let field = NSTextField(string: "")
  let remember = NSButton(checkboxWithTitle: "Remember", target: nil, action: nil)
  let swatch = Swatch(frame: NSRect(x: 420, y: 262, width: 40, height: 40))

  func install(in view: NSView) {
    let save = NSButton(title: "Save", target: self, action: #selector(saved))
    save.frame = NSRect(x: 16, y: 270, width: 80, height: 28)
    save.setAccessibilityIdentifier("save")
    clicksLabel.frame = NSRect(x: 104, y: 274, width: 80, height: 20)
    clicksLabel.textColor = .white
    clicksLabel.setAccessibilityIdentifier("clicks")
    field.frame = NSRect(x: 16, y: 232, width: 200, height: 24)
    field.placeholderString = "Title"
    field.delegate = self
    field.setAccessibilityIdentifier("title")
    typedLabel.frame = NSRect(x: 224, y: 234, width: 80, height: 20)
    typedLabel.textColor = .white
    typedLabel.setAccessibilityIdentifier("typed")
    remember.frame = NSRect(x: 16, y: 198, width: 120, height: 24)
    remember.contentTintColor = .white
    remember.setAccessibilityIdentifier("remember")
    swatch.setAccessibilityIdentifier("swatch")
    swatch.setAccessibilityElement(true)
    swatch.setAccessibilityRole(.image)
    swatch.setAccessibilityLabel("Saved swatch")
    var views: [NSView] = [save, clicksLabel, field, typedLabel, remember, swatch]
    for (i, x) in [150, 250].enumerated() {
      let b = NSButton(title: "Again", target: self, action: #selector(againPressed))
      b.frame = NSRect(x: CGFloat(x), y: 86, width: 80, height: 28)
      b.tag = i
      views.append(b)
    }
    for v in views { view.addSubview(v) }
  }

  @objc func saved() {
    clicks += 1
    clicksLabel.stringValue = "clicks \(clicks)"
    swatch.on = true
  }
  @objc func againPressed() { again += 1 }
  func controlTextDidChange(_ obj: Notification) {
    typedLabel.stringValue = "typed \(field.stringValue.count)"
  }
  var state: String {
    "{\"clicks\":\(clicks),\"typed\":\(field.stringValue.count),\"remember\":\(remember.state == .on),\"again\":\(again)}"
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// An Edit menu, as any app has: a chord like Meta+A is the menu's key equivalent.
let mainMenu = NSMenu()
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
mainMenu.addItem(editItem)
app.mainMenu = mainMenu

let window = NSWindow(
  contentRect: NSRect(x: 120, y: 160, width: 480, height: 320), styleMask: [.titled, .closable],
  backing: .buffered, defer: false)
window.title = title
let field = Field(frame: window.contentView!.bounds)
field.autoresizingMask = [.width, .height]
window.contentView!.addSubview(field)
let controls = Controls()
controls.install(in: window.contentView!)
window.orderFrontRegardless()

Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
  field.phase = (field.phase + 0.02).truncatingRemainder(dividingBy: 1)
  field.needsDisplay = true
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
  print("{\"window\":\(window.windowNumber)}")
  fflush(stdout)
}
Thread.detachNewThread {
  while let line = readLine() {
    let parts = line.split(separator: " ")
    if parts.count == 3, parts[0] == "move", let dx = Double(parts[1]), let dy = Double(parts[2]) {
      DispatchQueue.main.async {
        // AppKit's y grows upward; "down" on screen is a smaller y.
        var origin = window.frame.origin
        origin.x += dx
        origin.y -= dy
        window.setFrameOrigin(origin)
        print("{\"moved\":true}")
        fflush(stdout)
      }
    } else if parts.first == "state" {
      DispatchQueue.main.async {
        print(controls.state)
        fflush(stdout)
      }
    }
  }
  exit(0)
}
app.run()
