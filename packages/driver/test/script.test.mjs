// A scripted take: looking at a window (`tree`, `still`) and acting on it while it is
// recorded (`record` with `drive`, then `send`). The window is the fixture this test builds
// and owns, whose controls count what was done to them.
//
// It needs Screen Recording and Accessibility granted to whatever launched the tests, and
// swiftc. Anywhere else the suite says why it is skipped. It moves the real pointer.
import assert from 'node:assert/strict'
import { existsSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { after, before, describe, it } from 'node:test'
import { check, record, still, tree, windows } from '../dist/index.js'
import {
  has,
  killPid,
  killStarted,
  onMac,
  openFixture,
  probe,
  readJson,
  scratch,
  sleep,
  within,
} from './helpers.mjs'

const may = onMac ? await check() : null
const skip = !onMac
  ? 'the helper is macOS only'
  : !may.screenRecording
    ? 'Screen Recording is not granted to the app that launched these tests'
    : !may.accessibility
      ? 'Accessibility is not granted to the app that launched these tests'
      : !has('swiftc')
        ? 'swiftc is not on the path, so the fixture window cannot be built'
        : false

const WAIT = 40_000

// The whole file has a limit too. Whatever holds this process open past it (a helper that
// never exits, a window that never closes) fails the run here, in words, with the output
// above it, and not at the job's timeout with none.
setTimeout(() => {
  console.error(
    'This test file was still running after 5 minutes: something it started never ended.',
  )
  process.exit(1)
}, 300_000).unref()
const TEST = { timeout: 120_000 }

describe('scripting a window', { skip }, () => {
  let fixture
  const dirs = []
  const takes = []

  const out = () => {
    const s = scratch('vos-driver-script-')
    dirs.push(s)
    return s.dir
  }
  /**
   * The fixture's state once it is what is expected. A command answers when its input is
   * posted; the app acts on it a moment later.
   */
  const stateWhen = async (test) => {
    let state
    for (let i = 0; i < 40; i++) {
      state = await fixture.state()
      if (test(state)) break
      await sleep(50)
    }
    return state
  }

  /** A take that takes commands, begun. */
  const drive = async (request = {}) => {
    const dir = out()
    const take = record({ window: fixture.id, out: dir, drive: true, maxSeconds: 60, ...request })
    takes.push(take)
    const ready = await within(take.ready, WAIT, 'ready')
    return {
      dir,
      ready,
      send: (command) => within(take.send(command), WAIT, `the answer to ${command.do}`),
      stop: () => within(take.stop(), WAIT, 'stop()'),
    }
  }

  before(
    async () => {
      fixture = await openFixture()
      let listed
      for (let i = 0; i < 50 && !listed; i++) {
        listed = (await within(windows(), WAIT, 'windows()')).find((w) => w.id === fixture.id)
        if (!listed) await sleep(100)
      }
    },
    { timeout: 180_000 },
  )

  after(() => {
    for (const take of takes) killPid(take.pid)
    killStarted()
    fixture?.close()
    for (const s of dirs) s.remove()
  })

  it(
    'outlines the window: each control with a selector, and whether it is the only one',
    TEST,
    async () => {
      const outline = await within(tree({ window: fixture.id }), WAIT, 'tree()')
      assert.equal(outline.window.w, 480)
      const by = (selector) => outline.elements.find((e) => e.selector === selector)

      const save = by("button[id='save']")
      assert.ok(save, 'the Save button is named by its identifier')
      assert.equal(save.name, 'Save')
      assert.equal(save.unique, true)
      assert.equal(save.enabled, true)
      assert.ok(save.rect.x >= 0 && save.rect.y > 0 && save.rect.w > 40, JSON.stringify(save.rect))

      // Two buttons with one name and no identifier: each is named by its position.
      const again = outline.elements.filter((e) => e.name === 'Again')
      assert.deepEqual(
        again.map((e) => [e.selector, e.unique]),
        [
          ["button[name='Again']:nth(0)", false],
          ["button[name='Again']:nth(1)", false],
        ],
      )
      assert.ok(again[0].rect.x < again[1].rect.x, 'in reading order')

      // The window's own close, minimise and zoom buttons are not offered: pressing one ends the take.
      assert.deepEqual(
        outline.elements.filter((e) => e.role === 'button').map((e) => e.name),
        ['Save', 'Again', 'Again'],
      )
    },
  )

  it('never reads what was typed into a field', TEST, async () => {
    const t = await drive()
    const typed = await t.send({
      do: 'type',
      selector: "textfield[id='title']",
      text: 'a private thing',
    })
    assert.equal(typed.ok, true)
    assert.equal((await stateWhen((s) => s.typed === 15)).typed, 15)
    const located = await t.send({ do: 'locate', selector: "textfield[id='title']" })
    assert.equal(located.name, 'Title', 'a field is called by its placeholder')
    await t.stop()

    const outline = await within(tree({ window: fixture.id }), WAIT, 'tree()')
    assert.ok(
      !JSON.stringify(outline).includes('a private thing'),
      'the outline holds no typed text',
    )
    for (const file of ['cursor.json', 'meta.json']) {
      assert.ok(
        !JSON.stringify(readJson(t.dir, file)).includes('private'),
        `${file} holds no typed text`,
      )
    }
    // Leave the field as it was found.
    const t2 = await drive()
    await t2.send({ do: 'press', keys: ['Meta+A', 'Backspace'] })
    assert.equal((await stateWhen((s) => s.typed === 0)).typed, 0)
    await t2.stop()
  })

  it('takes a picture of the window as a take would show it', TEST, async () => {
    const dir = out()
    const shot = await within(
      still({ window: fixture.id, out: join(dir, 'look.png') }),
      WAIT,
      'still()',
    )
    assert.equal(shot.window, fixture.id)
    assert.equal(shot.width, Math.round(shot.frame.w * shot.scale))
    assert.ok(existsSync(shot.out) && statSync(shot.out).size > 1000, 'a PNG is written')
  })

  it('presses what a selector names, and the take carries the press', TEST, async () => {
    const before = await fixture.state()
    const t = await drive()
    assert.equal(t.ready.frame.w, 480)

    const found = await t.send({ do: 'locate', selector: "button[id='save']" })
    assert.equal(found.ok, true)
    assert.equal(found.count, 1)
    assert.equal(found.name, 'Save')

    const click = await t.send({ do: 'click', selector: "button[id='save']" })
    assert.equal(click.ok, true)
    assert.equal(click.pressed, true)
    assert.ok(click.tEnd > click.tStart, 'the click has an extent on the take clock')
    assert.deepEqual(click.rect, found.rect)

    const second = await t.send({ do: 'click', selector: "button[name='Again']:nth(1)" })
    assert.equal(second.ok, true)
    const check = await t.send({ do: 'click', selector: "checkbox[id='remember']" })
    assert.equal(check.ok, true)

    const state = await stateWhen((s) => s.remember !== before.remember)
    assert.equal(state.clicks, before.clicks + 1, 'Save was pressed once')
    assert.equal(state.again, before.again + 1, 'the second Again was pressed')
    assert.equal(state.remember, !before.remember, 'the checkbox was toggled')

    await sleep(300)
    const stopped = await t.stop()
    assert.equal(stopped.reason, 'stop')

    // The track: the pointer travelled, and each press is where the element is, with its bounds.
    const track = readJson(t.dir, 'cursor.json')
    const downs = track.filter((e) => e.type === 'down')
    assert.equal(downs.length, 3)
    assert.deepEqual(
      downs[0].rect,
      click.rect,
      'the press carries the bounds of what the script named',
    )
    assert.ok(
      downs[0].t >= click.tStart && downs[0].t <= click.tEnd,
      `the press (${downs[0].t}) is inside the command's extent (${click.tStart} to ${click.tEnd})`,
    )
    const inside = (e, r) => e.x >= r.x && e.x <= r.x + r.w && e.y >= r.y && e.y <= r.y + r.h
    assert.ok(inside(downs[0], click.rect), 'the press is inside the element')
    assert.ok(
      track.filter((e) => e.type === 'move').length > 10,
      'the pointer glided, it did not jump',
    )

    // The picture: the swatch turns green when Save is pressed, and the footage shows it.
    const scale = t.ready.scale
    const swatch = (await within(tree({ window: fixture.id }), WAIT, 'tree()')).elements.find(
      (e) => e.id === 'swatch',
    )
    const patch = [
      Math.round((swatch.rect.x + 10) * scale),
      Math.round((swatch.rect.y + 10) * scale),
      Math.round(20 * scale),
      Math.round(20 * scale),
    ]
    const [[r, g, b]] = probe(join(t.dir, 'recording.mp4'), stopped.durationMs / 1000 - 0.1, patch)
    assert.ok(g > 140 && g - r > 60 && g - b > 60, `the swatch is green at the end (${[r, g, b]})`)
  })

  it('finds the window by its process, and says what the app is made of', TEST, async () => {
    const mine = (await within(windows(), WAIT, 'windows()')).find((w) => w.id === fixture.id)
    assert.ok(mine.pid > 0, 'a window says whose it is')
    // Two instances of one app share a name; a process id is the one that is this window's.
    const outline = await within(tree({ pid: mine.pid }), WAIT, 'tree({ pid })')
    assert.equal(outline.kind, 'native')
    assert.equal(outline.built, true)
    assert.ok(outline.elements.some((e) => e.selector === "button[id='save']"))
    const shot = await within(
      still({ pid: mine.pid, out: join(out(), 'by-pid.png') }),
      WAIT,
      'still({ pid })',
    )
    assert.equal(shot.window, fixture.id)
    const t = await drive({ window: undefined, pid: mine.pid })
    assert.equal(t.ready.window, fixture.id)
    await t.stop()
  })

  it(
    'waits for a window that is not on screen yet, and says no-window when none comes',
    TEST,
    async () => {
      const started = Date.now()
      await assert.rejects(
        within(tree({ pid: 1 }), WAIT, 'tree of a process with no window'),
        (error) => error.code === 'no-window',
      )
      assert.ok(Date.now() - started > 2500, 'it waited before saying so')
    },
  )

  it('says what a key would go to, and types a new line as the Return key', TEST, async () => {
    const t = await drive()
    await t.send({ do: 'click', selector: "textfield[id='title']" })
    await sleep(250)
    const on = await t.send({ do: 'focused' })
    assert.equal(on.ok, true)
    assert.equal(on.frontmost, true)
    // A focused field is edited by a field editor: either is something typed into.
    assert.ok(
      ['textfield', 'textarea'].includes(on.focused.role),
      `focus is on a ${on.focused.role}`,
    )
    assert.ok(!JSON.stringify(on).includes('value'), 'it never says what the field holds')

    // Return in a one-line field ends the edit and selects what is there, so the "c" that
    // follows replaces "ab": the new line was the Return key, not a character.
    await t.send({ do: 'type', text: 'ab\nc' })
    assert.equal((await stateWhen((s) => s.typed === 1)).typed, 1)
    await t.send({ do: 'click', selector: "textfield[id='title']" })
    await t.send({ do: 'press', keys: ['Meta+A', 'Backspace'] })
    assert.equal((await stateWhen((s) => s.typed === 0)).typed, 0)

    // After a press on a button, the keyboard is not in a field.
    await t.send({ do: 'click', selector: "checkbox[id='remember']" })
    await t.send({ do: 'click', selector: "checkbox[id='remember']" })
    await t.stop()
  })

  it('lets go of every modifier a chord or a click held', TEST, async () => {
    // A posted event that only claims a modifier leaves the system believing it is held:
    // the next click, a person's or a script's, is then a Control-click.
    const before = await fixture.state()
    assert.equal(before.held, '', 'nothing is held before the take')
    const t = await drive()
    for (const keys of ['Shift+F12', 'Control+F12', 'Meta+Alt+F12']) {
      assert.equal((await t.send({ do: 'press', keys })).ok, true)
      assert.equal((await fixture.state()).held, '', `nothing is held after ${keys}`)
    }
    // A click made with a modifier lets it go too, and the next plain click is a plain click.
    const shifted = await t.send({
      do: 'click',
      selector: "button[name='Again']:nth(0)",
      modifiers: ['Shift'],
    })
    assert.equal(shifted.ok, true)
    assert.equal((await fixture.state()).held, '', 'nothing is held after a shift-click')
    await t.send({ do: 'press', keys: 'Control+F12' })
    await t.send({ do: 'click', selector: "button[id='save']" })
    const after = await stateWhen((s) => s.clicks === before.clicks + 1)
    assert.equal(
      after.clicks,
      before.clicks + 1,
      'a click after a Control chord is a click, not a context menu',
    )
    await t.stop()
    assert.equal((await fixture.state()).held, '', 'nothing is held after the take')
  })

  it('says what it could not do, and the take goes on', TEST, async () => {
    const t = await drive()
    const none = await t.send({ do: 'locate', selector: "button[name='Nope']" })
    assert.equal(none.ok, true)
    assert.equal(none.count, 0)

    const miss = await t.send({ do: 'click', selector: "button[name='Nope']" })
    assert.equal(miss.ok, false)
    assert.equal(miss.code, 'not-found')

    const bad = await t.send({ do: 'click', selector: 'button[[' })
    assert.equal(bad.ok, false)
    assert.equal(bad.code, 'bad-request')
    assert.match(bad.message, /at character/)

    const unknown = await t.send({ do: 'dance' })
    assert.equal(unknown.ok, false)
    assert.equal(unknown.code, 'bad-request')

    // The fixture's title bar has a disabled zoom button: reached, and not pressed.
    const off = await t.send({ do: 'click', selector: 'button:nth(4)' })
    assert.equal(off.ok, true)
    assert.equal(off.enabled, false)
    assert.equal(off.pressed, false)

    const now = await t.send({ do: 'now' })
    assert.equal(now.ok, true)
    assert.ok(now.tEnd > 0)
    const stopped = await t.stop()
    assert.equal(stopped.reason, 'stop')
    await assert.rejects(t.send({ do: 'now' }), /ended/)
  })

  it('answers a command on a take that was not asked to drive', TEST, async () => {
    // Without `drive` the app is not brought forward before the capture; a command still answers.
    const dir = out()
    const take = record({ window: fixture.id, out: dir, maxSeconds: 30 })
    takes.push(take)
    await within(take.ready, WAIT, 'ready')
    const now = await within(take.send({ do: 'now' }), WAIT, 'now')
    assert.equal(now.ok, true)
    await within(take.stop(), WAIT, 'stop()')
  })
})
