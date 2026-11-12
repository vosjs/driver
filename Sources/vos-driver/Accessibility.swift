// An app's window as its accessibility tree, and selectors over it.
//
// This is how a script names what it acts on. A selector is a short path of steps:
//
//   button[name='Save']                 a role, and what a person would call the element
//   textfield[id='issue-title']         the accessibility identifier, the stable one a maker sets
//   toolbar > button[name*='Share']     `>` is a child, a space is any descendant; `*=` contains
//   button[name='Delete']:nth(1)        the second match, counted from 0
//   *[id='sidebar']                     any role
//
// What is read of an element: its role, its name, its identifier, where it is, whether it is
// enabled. The name is what the interface calls it (a title, a description, a label's words,
// a field's placeholder). The CONTENTS of anything a person types into are never read.

import AppKit
import ApplicationServices
import Foundation

/// One element, as a selector sees it.
final class Node {
  let element: AXUIElement
  let role: String
  let name: String
  let id: String
  /// Global points, top-left origin.
  let frame: CGRect
  let enabled: Bool
  var children: [Node] = []
  weak var parent: Node?

  init(element: AXUIElement, role: String, name: String, id: String, frame: CGRect, enabled: Bool) {
    self.element = element
    self.role = role
    self.name = name
    self.id = id
    self.frame = frame
    self.enabled = enabled
  }
}

// MARK: reading

func axString(_ el: AXUIElement, _ attribute: String) -> String {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return "" }
  return (value as? String) ?? ""
}

func axBool(_ el: AXUIElement, _ attribute: String, default fallback: Bool) -> Bool {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return fallback }
  return (value as? Bool) ?? fallback
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
  return (value as? [AXUIElement]) ?? []
}

/// `AXButton` is `button`. A few are shortened to what people say.
func roleName(_ raw: String) -> String {
  var role = raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw
  role = role.lowercased()
  switch role {
  case "statictext": return "text"
  case "radiobutton": return "radio"
  case "popupbutton": return "popup"
  default: return role
  }
}

/// Roles a person types into. Their value is what was typed, so it is never read.
let TYPED_INTO: Set<String> = ["textfield", "textarea", "combobox", "searchfield", "securetextfield"]

/// What a person would call an element: its title, else its description, else (a label) its
/// words, else (a field) its placeholder or the label that titles it.
func nameOf(_ el: AXUIElement, role: String) -> String {
  let title = axString(el, kAXTitleAttribute as String)
  if !title.isEmpty { return title }
  let description = axString(el, kAXDescriptionAttribute as String)
  if !description.isEmpty { return description }
  if role == "text" {
    // A label's value is its words: interface text, not anything a person entered.
    let words = axString(el, kAXValueAttribute as String)
    if !words.isEmpty { return words }
  }
  if TYPED_INTO.contains(role) {
    let placeholder = axString(el, kAXPlaceholderValueAttribute as String)
    if !placeholder.isEmpty { return placeholder }
  }
  var titled: CFTypeRef?
  if AXUIElementCopyAttributeValue(el, kAXTitleUIElementAttribute as CFString, &titled) == .success,
    let t = titled
  {
    let label = t as! AXUIElement
    let words = axString(label, kAXValueAttribute as String)
    if !words.isEmpty { return words }
    return axString(label, kAXTitleAttribute as String)
  }
  return ""
}

/// The most a tree is read to: a tree past this is an interface nobody scripts by hand.
let TREE_MAX_NODES = 6000
let TREE_MAX_DEPTH = 60

/// Reads the tree under one element.
func readTree(_ root: AXUIElement) -> Node? {
  var budget = TREE_MAX_NODES
  func read(_ el: AXUIElement, _ depth: Int) -> Node? {
    guard budget > 0, depth <= TREE_MAX_DEPTH else { return nil }
    budget -= 1
    let role = roleName(axString(el, kAXRoleAttribute as String))
    guard !role.isEmpty else { return nil }
    let node = Node(
      element: el, role: role, name: nameOf(el, role: role),
      id: axString(el, kAXIdentifierAttribute as String), frame: axRect(el) ?? .zero,
      enabled: axBool(el, kAXEnabledAttribute as String, default: true))
    for child in axChildren(el) {
      if let c = read(child, depth + 1) {
        c.parent = node
        node.children.append(c)
      }
    }
    return node
  }
  return read(root, 0)
}

// MARK: the app and its window

/// The app's accessibility element, with its tree switched on. Chromium and Electron build
/// theirs only when asked: these two attributes are how assistive software asks.
func appElement(_ pid: pid_t) -> AXUIElement {
  let app = AXUIElementCreateApplication(pid)
  AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
  AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
  return app
}

/// The accessibility window that is the window being recorded: the one of the app's windows
/// whose frame is that window's frame. (There is no public way from a window id to its
/// accessibility element; the frame is what both sides agree on.)
func windowElement(_ pid: pid_t, frame: CGRect) -> AXUIElement? {
  let app = appElement(pid)
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
    let windows = value as? [AXUIElement]
  else { return nil }
  var best: (AXUIElement, CGFloat)?
  for w in windows {
    guard let f = axRect(w) else { continue }
    let off = abs(f.minX - frame.minX) + abs(f.minY - frame.minY) + abs(f.width - frame.width)
      + abs(f.height - frame.height)
    if best == nil || off < best!.1 { best = (w, off) }
  }
  // A few points of slack: the two frames are measured by different parts of the system.
  guard let (window, off) = best, off <= 8 else { return nil }
  return window
}

// MARK: selectors

struct SelectorStep {
  enum Combinator { case descendant, child }
  var combinator: Combinator = .descendant
  var role = "*"
  /// (key, contains, value): `name` or `id`; `=` or `*=`.
  var tests: [(String, Bool, String)] = []
  var nth: Int?

  func matches(_ n: Node) -> Bool {
    if role != "*" && role != n.role { return false }
    for (key, contains, value) in tests {
      let has = key == "id" ? n.id : n.name
      if contains ? !has.localizedCaseInsensitiveContains(value) : has != value { return false }
    }
    return true
  }
}

struct SelectorError: Error, LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Parses a selector. A selector that does not parse says what is wrong with it.
func parseSelector(_ text: String) throws -> [SelectorStep] {
  let chars = Array(text)
  var i = 0
  var steps: [SelectorStep] = []
  var next = SelectorStep.Combinator.descendant
  func bad(_ why: String) -> SelectorError {
    SelectorError(message: "The selector \"\(text)\" is not one: \(why) (at character \(i + 1)).")
  }
  func skipSpaces() -> Bool {
    let from = i
    while i < chars.count, chars[i] == " " { i += 1 }
    return i > from
  }
  _ = skipSpaces()
  while i < chars.count {
    var step = SelectorStep()
    step.combinator = next
    // the role
    var role = ""
    while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "*" || chars[i] == "-" {
      role.append(chars[i])
      i += 1
    }
    if role.isEmpty && (i >= chars.count || chars[i] != "[") { throw bad("a role or * is expected") }
    step.role = role.isEmpty ? "*" : role.lowercased()
    // [name='…'] [id='…']
    while i < chars.count, chars[i] == "[" {
      i += 1
      var key = ""
      while i < chars.count, chars[i].isLetter {
        key.append(chars[i])
        i += 1
      }
      guard key == "name" || key == "id" else { throw bad("a test is on name or id") }
      var contains = false
      if i < chars.count, chars[i] == "*" {
        contains = true
        i += 1
      }
      guard i < chars.count, chars[i] == "=" else { throw bad("= or *= is expected") }
      i += 1
      guard i < chars.count, chars[i] == "'" || chars[i] == "\"" else { throw bad("a quoted value is expected") }
      let quote = chars[i]
      i += 1
      var value = ""
      var closed = false
      while i < chars.count {
        if chars[i] == "\\", i + 1 < chars.count {
          value.append(chars[i + 1])
          i += 2
          continue
        }
        if chars[i] == quote {
          closed = true
          i += 1
          break
        }
        value.append(chars[i])
        i += 1
      }
      guard closed else { throw bad("the quoted value does not end") }
      guard i < chars.count, chars[i] == "]" else { throw bad("] is expected") }
      i += 1
      step.tests.append((key, contains, value))
    }
    // :nth(n)
    if i < chars.count, chars[i] == ":" {
      let rest = String(chars[i...])
      guard rest.hasPrefix(":nth(") else { throw bad(":nth(n) is the one suffix") }
      i += 5
      var digits = ""
      while i < chars.count, chars[i].isNumber {
        digits.append(chars[i])
        i += 1
      }
      guard let n = Int(digits), i < chars.count, chars[i] == ")" else { throw bad(":nth(n) takes a number") }
      i += 1
      step.nth = n
    }
    steps.append(step)
    // what joins it to the next step
    let spaced = skipSpaces()
    if i >= chars.count { break }
    if chars[i] == ">" {
      i += 1
      _ = skipSpaces()
      next = .child
      if i >= chars.count { throw bad("a step is expected after >") }
    } else if spaced {
      next = .descendant
    } else {
      throw bad("a space or > is expected between steps")
    }
  }
  guard !steps.isEmpty else { throw SelectorError(message: "The selector is empty.") }
  return steps
}

/// Every node under `root`, in the order a person reads them.
func descendants(_ root: Node) -> [Node] {
  var out: [Node] = []
  func walk(_ n: Node) {
    for c in n.children {
      out.append(c)
      walk(c)
    }
  }
  walk(root)
  return out
}

/// The elements a selector names, in reading order.
func select(_ steps: [SelectorStep], in root: Node) -> [Node] {
  var current: [Node] = [root]
  for step in steps {
    var found: [Node] = []
    var seen = Set<ObjectIdentifier>()
    for from in current {
      let pool = step.combinator == .child ? from.children : descendants(from)
      for n in pool where step.matches(n) {
        if seen.insert(ObjectIdentifier(n)).inserted { found.append(n) }
      }
    }
    if let nth = step.nth { found = nth < found.count ? [found[nth]] : [] }
    current = found
    if current.isEmpty { break }
  }
  return current
}

// MARK: the outline

func quoted(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
}

/// Roles a script acts on. Anything else is listed only when it has a name or an id.
let ACTED_ON: Set<String> = [
  "button", "checkbox", "radio", "popup", "menubutton", "menuitem", "link", "slider", "tab", "disclosuretriangle",
  "incrementor", "colorwell", "switch", "toggle", "cell", "row",
]

/// The outline of a window for someone about to script it: each element worth naming, with
/// ONE selector proposed for it, and whether that selector names it alone.
func outline(_ root: Node, window: CGRect) -> [[String: Any]] {
  let all = descendants(root)
  var out: [[String: Any]] = []
  for n in all {
    let interesting = ACTED_ON.contains(n.role) || TYPED_INTO.contains(n.role) || !n.name.isEmpty || !n.id.isEmpty
    guard interesting, n.frame.width > 0, n.frame.height > 0, n.frame.intersects(window) else { continue }
    // The identifier first: it is the one a maker set, and the one that survives a redesign.
    var selector = n.role
    if !n.id.isEmpty {
      selector += "[id=\(quoted(n.id))]"
    } else if !n.name.isEmpty {
      selector += "[name=\(quoted(n.name))]"
    }
    var unique = true
    if let steps = try? parseSelector(selector) {
      let matches = select(steps, in: root)
      if matches.count > 1, let at = matches.firstIndex(where: { $0 === n }) {
        // Several answer to it: the position among them makes it this one.
        selector += ":nth(\(at))"
        unique = false
      }
    }
    var entry: [String: Any] = [
      "role": n.role, "selector": selector, "unique": unique, "enabled": n.enabled,
      "rect": [
        "x": r1(n.frame.minX - window.minX), "y": r1(n.frame.minY - window.minY), "w": r1(n.frame.width),
        "h": r1(n.frame.height),
      ],
    ]
    if !n.name.isEmpty { entry["name"] = n.name }
    if !n.id.isEmpty { entry["id"] = n.id }
    out.append(entry)
  }
  return out
}
