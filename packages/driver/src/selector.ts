/**
 * The selector grammar, read without the helper.
 *
 * A script names its elements long before a take runs them, and a take presses the real
 * app: a selector that is not one should be refused when the script is read, not at the
 * step that uses it, after the steps before it have run. This is the helper's parser
 * (Sources/vos-driver/Accessibility.swift, `parseSelector`), step for step, with its
 * words; the tests hold the two to each other.
 *
 *   button[name='Save']                 a role and its name, exactly
 *   textfield[id='title']               an accessibility identifier
 *   button[name*='save']                the name contains this, in any case
 *   group[name='Sidebar'] > button      a child; a space is any descendant
 *   button[name='Delete']:nth(1)        the second match, counted from 0
 */

const LETTER = /^\p{L}$/u
const NUMBER = /^\p{N}$/u

/** Why a selector is not one, in the helper's words, or null when it is. */
export function selectorProblem(text: string): string | null {
  const chars = Array.from(text)
  let i = 0
  let steps = 0
  const bad = (why: string) => `The selector "${text}" is not one: ${why} (at character ${i + 1}).`
  const skipSpaces = () => {
    const from = i
    while (i < chars.length && chars[i] === ' ') i++
    return i > from
  }
  skipSpaces()
  while (i < chars.length) {
    // the role
    let role = ''
    while (
      i < chars.length &&
      (LETTER.test(chars[i]) || NUMBER.test(chars[i]) || chars[i] === '*' || chars[i] === '-')
    ) {
      role += chars[i]
      i++
    }
    if (!role && (i >= chars.length || chars[i] !== '[')) return bad('a role or * is expected')
    // [name='…'] [id='…']
    while (i < chars.length && chars[i] === '[') {
      i++
      let key = ''
      while (i < chars.length && LETTER.test(chars[i])) {
        key += chars[i]
        i++
      }
      if (key !== 'name' && key !== 'id') return bad('a test is on name or id')
      if (i < chars.length && chars[i] === '*') i++
      if (!(i < chars.length && chars[i] === '=')) return bad('= or *= is expected')
      i++
      if (!(i < chars.length && (chars[i] === "'" || chars[i] === '"'))) {
        return bad('a quoted value is expected')
      }
      const quote = chars[i]
      i++
      let closed = false
      while (i < chars.length) {
        if (chars[i] === '\\' && i + 1 < chars.length) {
          i += 2
          continue
        }
        if (chars[i] === quote) {
          closed = true
          i++
          break
        }
        i++
      }
      if (!closed) return bad('the quoted value does not end')
      if (!(i < chars.length && chars[i] === ']')) return bad('] is expected')
      i++
    }
    // :nth(n)
    if (i < chars.length && chars[i] === ':') {
      if (!chars.slice(i).join('').startsWith(':nth(')) return bad(':nth(n) is the one suffix')
      i += 5
      let digits = ''
      while (i < chars.length && NUMBER.test(chars[i])) {
        digits += chars[i]
        i++
      }
      if (!/^[0-9]+$/.test(digits) || !(i < chars.length && chars[i] === ')')) {
        return bad(':nth(n) takes a number')
      }
      i++
    }
    steps++
    // what joins it to the next step
    const spaced = skipSpaces()
    if (i >= chars.length) break
    if (chars[i] === '>') {
      i++
      skipSpaces()
      if (i >= chars.length) return bad('a step is expected after >')
    } else if (!spaced) {
      return bad('a space or > is expected between steps')
    }
  }
  return steps === 0 ? 'The selector is empty.' : null
}
