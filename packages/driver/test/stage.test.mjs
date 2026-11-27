// A stage: one display with only what the take named in its pixels.
//
// The stage here is two fixture windows of our own (Fixtures/window.swift), each its own
// process, with a third standing over one of them as the app nobody named. Nothing of the
// machine's is recorded: everything that is not a named fixture is kept out, which is the
// thing under test.
//
// It runs where Screen Recording is granted to whatever launched the tests and swiftc is on
// the path; anywhere else the suite says why it is skipped.
import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { after, before, describe, it } from 'node:test'
import { DriverError, check, record, still, windows } from '../dist/index.js'
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

const permissions = onMac ? await check() : { screenRecording: false, accessibility: false }
const granted = permissions.screenRecording
const accessible = permissions.accessibility
const skip = !onMac
  ? 'the helper is macOS only'
  : !granted
    ? 'Screen Recording is not granted to the app that launched these tests'
    : !has('swiftc')
      ? 'swiftc is not on the path, so the fixture windows cannot be built'
      : false

const WAIT = 40_000
setTimeout(() => {
  console.error(
    'This test file was still running after 5 minutes: something it started never ended.',
  )
  process.exit(1)
}, 300_000).unref()
const TEST = { timeout: 120_000 }

const BLUE = [40, 90, 160]
const RED = [170, 50, 40]
const GREEN = [30, 150, 60]
const GROUND = '#c800c8'
const isBlue = ([r, g, b]) => b > 110 && b - r > 60 && b - g > 30
const isRed = ([r, g, b]) => r > 110 && r - g > 60 && r - b > 60
const isGreen = ([r, g, b]) => g > 100 && g - r > 50 && g - b > 40
const isGround = ([r, g, b]) => r > 140 && b > 140 && g < 90

describe('recording a stage', { skip }, () => {
  let blue
  let red
  let stranger
  const listed = {}
  const dirs = []
  const takes = []
  const opened = []

  const out = () => {
    const s = scratch('vos-driver-stage-')
    dirs.push(s)
    return s.dir
  }
  const start = (request, options) => {
    const take = record(request, options)
    takes.push(take)
    return {
      take,
      ready: () => within(take.ready, WAIT, 'ready'),
      stop: () => within(take.stop(), WAIT, 'stop()'),
      done: () => within(take.done, WAIT, 'done'),
    }
  }
  const open = async (options) => {
    const fixture = await openFixture(options)
    opened.push(fixture)
    return fixture
  }
  /** A window as the system lists it, waited for: a new one is listed a moment after it is drawn. */
  const list = async (id) => {
    for (let i = 0; i < 50; i++) {
      const found = (await within(windows(), WAIT, 'windows()')).find((w) => w.id === id)
      if (found) return found
      await sleep(100)
    }
    throw new Error(`The window ${id} was never listed.`)
  }
  /**
   * A patch of a window's flat colour, in the recording's pixels: bottom left of its
   * content, clear of the moving bar and the controls.
   */
  const patch = (ready, frame) => {
    const k = ready.captureWidth / ready.frame.w
    return [
      Math.round((frame.x - ready.frame.x + 40) * k),
      Math.round((frame.y - ready.frame.y + frame.h - 60) * k),
      Math.round(40 * k),
      Math.round(40 * k),
    ]
  }

  before(
    async () => {
      blue = await open({ color: BLUE, title: 'stage blue' })
      red = await open({ color: RED, title: 'stage red' })
      // Apart, so each has pixels of its own.
      await red.place('corner')
      // The app nobody named, standing over the blue window.
      stranger = await open({ color: GREEN, title: 'not on the stage' })
      listed.blue = await list(blue.id)
      listed.red = await list(red.id)
      listed.stranger = await list(stranger.id)
    },
    { timeout: 180_000 },
  )

  after(() => {
    for (const take of takes) killPid(take.pid)
    for (const fixture of opened) fixture.close()
    killStarted()
    for (const s of dirs) s.remove()
  })

  it('records the named apps and nothing else: video, meta and the windows', TEST, async () => {
    const dir = out()
    const t = start({
      pids: [listed.blue.pid, listed.red.pid],
      out: dir,
      pointer: false,
      ground: GROUND,
    })
    const ready = await t.ready()
    assert.equal(ready.filter, 'stage')
    assert.equal(ready.window, 0)
    assert.equal(ready.apps.length >= 1, true)
    assert.deepEqual(ready.desk, [])
    assert.equal(typeof ready.display, 'number')
    assert.equal(ready.cornerRadius, 0)
    // The frame is the display under its menu bar: wider than any window, and holding both.
    for (const w of [listed.blue, listed.red]) {
      assert.ok(
        w.frame.x >= ready.frame.x && w.frame.x + w.frame.w <= ready.frame.x + ready.frame.w,
      )
      assert.ok(
        w.frame.y >= ready.frame.y && w.frame.y + w.frame.h <= ready.frame.y + ready.frame.h,
      )
    }

    await sleep(1200)
    const stopped = await t.stop()
    assert.equal(stopped.reason, 'stop')
    assert.ok(stopped.frames >= 5, `the moving bars made frames (${stopped.frames})`)
    for (const file of Object.values(stopped.files)) assert.ok(existsSync(file), file)

    const meta = readJson(stopped.files.meta)
    assert.equal(meta.captureSurface, 'desktop')
    assert.equal(meta.producer, 'desktop')
    assert.equal('app' in meta, false, 'a stage is several apps: it names none as THE app')
    assert.equal('cornerRadius' in meta, false)
    assert.deepEqual(meta.apps, ready.apps)
    assert.deepEqual(meta.desk, [])
    assert.equal(meta.width, Math.round(ready.frame.w))
    assert.equal(meta.height, Math.round(ready.frame.h))
    assert.equal(meta.captureWidth, ready.captureWidth)

    // where the stage's windows were, front to back, in the frame's own points
    assert.ok(Array.isArray(meta.windows) && meta.windows.length >= 1)
    assert.equal(meta.windows[0].t, 0)
    const first = meta.windows[0].windows
    assert.deepEqual(first.map((w) => w.id).sort(), [blue.id, red.id].sort())
    for (const [key, id] of [
      ['blue', blue.id],
      ['red', red.id],
    ]) {
      const w = first.find((x) => x.id === id)
      assert.equal(w.x, listed[key].frame.x - ready.frame.x)
      assert.equal(w.y, listed[key].frame.y - ready.frame.y)
      assert.equal(w.w, listed[key].frame.w)
      assert.equal(w.h, listed[key].frame.h)
      assert.equal(typeof w.app, 'string')
      assert.equal('title' in w, false, 'a window is never named by its title')
      assert.equal('panel' in w, false, 'a titled window is a window, not a panel of one')
    }

    // The pixels: each named window where the list says, the window over the blue one
    // nowhere, and the ground where the stage holds nothing.
    const [atBlue, atRed, atGround] = probe(
      stopped.files.recording,
      0.5,
      patch(ready, listed.blue.frame),
      patch(ready, listed.red.frame),
      [20, 20, 40, 40],
    )
    assert.ok(isBlue(atBlue), `the blue window, though another stood over it: ${atBlue}`)
    assert.ok(isRed(atRed), `the red window: ${atRed}`)
    assert.ok(isGround(atGround), `the ground: ${atGround}`)
    assert.ok(!isGreen(atBlue), 'the window nobody named is in no pixel')
  })

  it('keeps a window that opens over the stage mid-take out of every frame', TEST, async () => {
    const t = start({
      pids: [listed.blue.pid, listed.red.pid],
      out: out(),
      pointer: false,
      ground: GROUND,
    })
    const ready = await t.ready()
    await sleep(500)
    const late = await open({ color: GREEN, title: 'opened mid-take' })
    await list(late.id)
    await sleep(1200)
    const stopped = await t.stop()
    late.close()
    assert.equal(typeof stopped.heldFrames, 'number')
    const at = patch(ready, listed.blue.frame)
    const seconds = stopped.durationMs / 1000
    for (const when of [0.2, seconds * 0.5, seconds * 0.8, Math.max(0, seconds - 0.1)]) {
      const [color] = probe(stopped.files.recording, when, at)
      assert.ok(isBlue(color), `at ${when.toFixed(2)} s the blue window is what is there: ${color}`)
    }
  })

  it('one app with stage is that app alone', TEST, async () => {
    const t = start({
      pid: listed.red.pid,
      stage: true,
      out: out(),
      pointer: false,
      ground: GROUND,
    })
    const ready = await t.ready()
    await sleep(700)
    const stopped = await t.stop()
    const meta = readJson(stopped.files.meta)
    assert.deepEqual(
      meta.windows[0].windows.map((w) => w.id),
      [red.id],
    )
    const [atBlue, atRed] = probe(
      stopped.files.recording,
      0.3,
      patch(ready, listed.blue.frame),
      patch(ready, listed.red.frame),
    )
    assert.ok(isRed(atRed), `the red window: ${atRed}`)
    assert.ok(isGround(atBlue), `where the blue window is on screen, the ground: ${atBlue}`)
  })

  it('keeps the wallpaper only when asked', TEST, async () => {
    const t = start({
      pids: [listed.blue.pid],
      desk: ['wallpaper'],
      out: out(),
      pointer: false,
      ground: GROUND,
    })
    const ready = await t.ready()
    assert.deepEqual(ready.desk, ['wallpaper'])
    await sleep(700)
    const stopped = await t.stop()
    assert.deepEqual(readJson(stopped.files.meta).desk, ['wallpaper'])
    const [atGround] = probe(stopped.files.recording, 0.3, [20, 20, 40, 40])
    assert.ok(!isGround(atGround), `the desk is there, not the ground: ${atGround}`)
  })

  it('refuses in words what a stage does not do', TEST, async () => {
    const refused = async (request, code, words) => {
      const t = start({ out: out(), pointer: false, ...request })
      await assert.rejects(t.ready(), (error) => {
        assert.ok(error instanceof DriverError)
        assert.equal(error.code, code)
        assert.match(error.message, words)
        return true
      })
    }
    const pids = [listed.blue.pid]
    await refused({ pids, size: { w: 800, h: 600 } }, 'bad-request', /does not size/)
    await refused({ pids, window: listed.blue.id }, 'bad-request', /takes no one window/)
    await refused({ pids, desk: ['sky'] }, 'bad-request', /Unknown part of the desk/)
    await refused({ apps: ['no app is called this'] }, 'no-window', /No running app is named/)
    if (accessible) {
      // An element is some app's: on a stage of several, a mask says whose.
      await refused(
        { pids: [listed.blue.pid, listed.red.pid], mask: [{ selector: "*[id='swatch']" }] },
        'bad-request',
        /says no app/,
      )
    }
  })

  it(
    'takes one picture of the stage, and says where each app’s windows are on it',
    TEST,
    async () => {
      const dir = out()
      const shot = await within(
        still({ pids: [listed.blue.pid, listed.red.pid], ground: GROUND, out: `${dir}/stage.png` }),
        WAIT,
        'still()',
      )
      assert.ok(existsSync(shot.out))
      assert.equal(shot.window, 0)
      assert.ok(shot.frame.w > listed.blue.frame.w)
      assert.deepEqual(shot.windows.map((w) => w.id).sort(), [blue.id, red.id].sort())
      const at = shot.windows.find((w) => w.id === blue.id)
      assert.equal(at.x, listed.blue.frame.x - shot.frame.x)
      assert.equal(at.y, listed.blue.frame.y - shot.frame.y)
      assert.equal(at.pid, listed.blue.pid)
    },
  )

  it(
    'covers what a mask names in an app of the stage, before a frame is encoded',
    {
      ...TEST,
      skip: !accessible && 'Accessibility is not granted to the app that launched these tests',
    },
    async () => {
      // The fixture's swatch is white. Covered, it is the flat colour around it.
      const swatch = (ready, frame) => {
        const k = ready.captureWidth / ready.frame.w
        return [
          Math.round((frame.x - ready.frame.x + 430) * k),
          Math.round((frame.y - ready.frame.y + (frame.h - 320) + 28) * k),
          Math.round(20 * k),
          Math.round(20 * k),
        ]
      }
      const bare = start({ pids: [listed.blue.pid, listed.red.pid], out: out(), pointer: false })
      const bareReady = await bare.ready()
      await sleep(500)
      const bareStopped = await bare.stop()
      const [white] = probe(bareStopped.files.recording, 0.2, swatch(bareReady, listed.blue.frame))
      assert.ok(
        white.every((c) => c > 200),
        `the swatch as it is: ${white}`,
      )

      const t = start({
        pids: [listed.blue.pid, listed.red.pid],
        mask: [{ pid: listed.blue.pid, selector: "*[id='swatch']" }],
        out: out(),
        pointer: false,
      })
      const ready = await t.ready()
      assert.deepEqual(ready.masks, [1])
      await sleep(600)
      const stopped = await t.stop()
      assert.equal(stopped.masks[0].matched, 1)
      assert.ok(stopped.maskedFrames > 0)
      const [covered, other] = probe(
        stopped.files.recording,
        0.3,
        swatch(ready, listed.blue.frame),
        swatch(ready, listed.red.frame),
      )
      assert.ok(isBlue(covered), `the blue window's swatch is covered: ${covered}`)
      assert.ok(
        other.every((c) => c > 200),
        `the red window's is not: nobody named it (${other})`,
      )
    },
  )
})

// A scripted stage presses the real apps with the machine's own pointer and keyboard, as a
// scripted take of one window does.
describe(
  'scripting a stage',
  {
    skip:
      skip || (!accessible && 'Accessibility is not granted to the app that launched these tests'),
  },
  () => {
    let blue
    let red
    const listed = {}
    const dirs = []
    const takes = []
    const opened = []
    const out = () => {
      const s = scratch('vos-driver-stage-script-')
      dirs.push(s)
      return s.dir
    }

    before(
      async () => {
        blue = await openFixture({ color: BLUE, title: 'stage blue' })
        red = await openFixture({ color: RED, title: 'stage red' })
        opened.push(blue, red)
        await red.place('corner')
        const find = async (id) => {
          for (let i = 0; i < 50; i++) {
            const found = (await within(windows(), WAIT, 'windows()')).find((w) => w.id === id)
            if (found) return found
            await sleep(100)
          }
          throw new Error(`The window ${id} was never listed.`)
        }
        listed.blue = await find(blue.id)
        listed.red = await find(red.id)
      },
      { timeout: 180_000 },
    )

    after(() => {
      for (const take of takes) killPid(take.pid)
      for (const fixture of opened) fixture.close()
      killStarted()
      for (const s of dirs) s.remove()
    })

    it(
      'each command acts on the app it names, and answers in the stage’s points',
      TEST,
      async () => {
        const take = record({ pids: [listed.blue.pid, listed.red.pid], out: out(), drive: true })
        takes.push(take)
        const ready = await within(take.ready, WAIT, 'ready')
        const send = (command) => within(take.send(command), WAIT, `the answer to ${command.do}`)

        // Nothing says which app yet, and there are two.
        const unnamed = await send({ do: 'click', selector: "button[id='save']" })
        assert.equal(unnamed.ok, false)
        assert.equal(unnamed.code, 'bad-request')
        assert.match(unnamed.message, /says which it acts on/)

        const pressed = await send({
          do: 'click',
          pid: listed.blue.pid,
          selector: "button[id='save']",
        })
        assert.equal(pressed.ok, true, JSON.stringify(pressed))
        assert.equal(pressed.pressed, true)
        // The button's bounds, in the stage's points: inside the blue window as the stage has it.
        const win = {
          x: listed.blue.frame.x - ready.frame.x,
          y: listed.blue.frame.y - ready.frame.y,
          w: listed.blue.frame.w,
          h: listed.blue.frame.h,
        }
        assert.ok(
          pressed.rect.x >= win.x && pressed.rect.x + pressed.rect.w <= win.x + win.w,
          JSON.stringify(pressed.rect),
        )
        assert.ok(
          pressed.rect.y >= win.y && pressed.rect.y + pressed.rect.h <= win.y + win.h,
          JSON.stringify(pressed.rect),
        )
        assert.ok(
          Math.abs(pressed.rect.x - win.x - 16) <= 3,
          `the button, 16 points in: ${pressed.rect.x - win.x}`,
        )

        // The other app, by name of its process; then a command that names none stays with it.
        const typed = await send({
          do: 'type',
          pid: listed.red.pid,
          selector: "textfield[id='title']",
          text: 'stage',
        })
        assert.equal(typed.ok, true, JSON.stringify(typed))
        const again = await send({ do: 'click', selector: "button[id='save']" })
        assert.equal(again.ok, true, JSON.stringify(again))

        const stranger = await send({ do: 'click', pid: 1, selector: "button[id='save']" })
        assert.equal(stranger.ok, false)
        assert.match(stranger.message, /is not on the stage/)

        const stopped = await within(take.stop(), WAIT, 'stop()')
        assert.deepEqual(
          {
            blue: (await blue.state()).clicks,
            red: (await red.state()).clicks,
            typed: (await red.state()).typed,
          },
          { blue: 1, red: 1, typed: 5 },
        )

        // The track is the stage's: the press carries the element's bounds, where the answer said.
        const track = readJson(stopped.files.cursor)
        const downs = track.filter((e) => e.type === 'down')
        assert.ok(downs.length >= 3, `${downs.length} presses`)
        assert.deepEqual(downs[0].rect, pressed.rect)
        for (const e of track) {
          assert.ok(
            e.x >= 0 && e.x <= ready.frame.w && e.y >= 0 && e.y <= ready.frame.h,
            JSON.stringify(e),
          )
        }
        const meta = readJson(stopped.files.meta)
        assert.equal(meta.captureSurface, 'desktop')
      },
    )

    it('a performed stage answers a command in words', TEST, async () => {
      const take = record({ pids: [listed.blue.pid], out: out(), pointer: false })
      takes.push(take)
      await within(take.ready, WAIT, 'ready')
      const answer = await within(take.send({ do: 'now' }), WAIT, 'the answer')
      assert.equal(answer.ok, false)
      assert.match(answer.message, /Record it with drive/)
      await within(take.stop(), WAIT, 'stop()')
    })
  },
)
