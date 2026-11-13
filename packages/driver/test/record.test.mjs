// What needs a screen: recording a real window. The window is a fixture this test
// builds and owns (Fixtures/window.swift), so nothing of the machine's is recorded.
//
// It runs where Screen Recording is granted to whatever launched the tests and swiftc
// is on the path; anywhere else the suite says why it is skipped.
//
// Every wait on a process has a limit and says what it was waiting for: a helper that
// stalls must fail a test in words, never hold the run open.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { closeSync, existsSync, openSync, readSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { after, before, describe, it } from 'node:test'
import { DriverError, check, driverPath, record, windows } from '../dist/index.js'
import {
  has,
  killPid,
  killStarted,
  onMac,
  openFixture,
  probe,
  readJson,
  runHelper,
  scratch,
  sleep,
  within,
} from './helpers.mjs'

const granted = onMac ? (await check()).screenRecording : false
const skip = !onMac
  ? 'the helper is macOS only'
  : !granted
    ? 'Screen Recording is not granted to the app that launched these tests'
    : !has('swiftc')
      ? 'swiftc is not on the path, so the fixture window cannot be built'
      : false

/** Longer than the helper's own limits added up, so the helper's words arrive first. */
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

const even = (n) => n - (n % 2)

/** The fixture window's flat colour, as it comes back out of a recording: blue leads. */
const isFixtureBlue = ([r, g, b]) => b > 120 && b - r > 60 && b - g > 30
// Black to the eye. An encoder bleeds a little of a neighbouring colour into it, the
// software one more than the hardware one, so this is not zero.
const isBlack = ([r, g, b]) => r < 32 && g < 32 && b < 32
/** Two patches of the window's content, clear of the moving bar: bottom left and bottom right. */
const CONTENT = [
  [40, -60, 40, 40],
  [-80, -60, 40, 40],
]

/** The type of a file's first box: an MP4 begins with `ftyp`. */
function boxType(file) {
  const fd = openSync(file, 'r')
  const head = Buffer.alloc(8)
  readSync(fd, head, 0, 8, 0)
  closeSync(fd)
  return head.subarray(4).toString('latin1')
}

describe('recording a window', { skip }, () => {
  let fixture
  let listed
  const dirs = []
  const takes = []

  const out = () => {
    const s = scratch('vos-driver-take-')
    dirs.push(s)
    return s.dir
  }
  /** `record`, with its waits limited and its helper ended when the suite is. */
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

  before(
    async () => {
      fixture = await openFixture()
      // The window server lists a new window a moment after it is drawn.
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

  it('lists the fixture window, titled, with its frame', TEST, () => {
    assert.ok(listed, 'the fixture window is among windows()')
    assert.equal(listed.titled, true)
    assert.ok(Number.isInteger(listed.pid) && listed.pid > 0, 'a window says which process owns it')
    assert.equal(listed.frame.w, 480)
    assert.ok(listed.frame.h >= 320, 'the frame holds the title bar above 320 points of content')
    assert.equal(typeof listed.app, 'string')
  })

  it('records it into a take: video, track and meta', TEST, async () => {
    const dir = out()
    const seen = []
    const t = start(
      { window: fixture.id, out: dir, pointer: false },
      { onEvent: (event) => seen.push(event.event) },
    )
    const ready = await t.ready()
    assert.equal(ready.window, fixture.id)
    assert.equal(ready.filter, 'others-out')
    assert.equal(ready.frame.w, listed.frame.w)
    assert.equal(ready.captureWidth, even(Math.round(listed.frame.w * ready.scale)))
    assert.equal(ready.captureHeight, even(Math.round(listed.frame.h * ready.scale)))
    assert.equal(typeof t.take.pid, 'number')

    await sleep(1200)
    const stopped = await t.stop()
    assert.equal(stopped.reason, 'stop')
    assert.ok(stopped.frames >= 5, `the moving bar made frames (${stopped.frames})`)
    assert.ok(stopped.durationMs > 500 && stopped.durationMs < 6000, `${stopped.durationMs} ms`)
    // An encoder still warming up may let a frame go; most reach the file.
    assert.ok(
      stopped.droppedFrames < stopped.frames,
      `${stopped.droppedFrames} dropped of ${stopped.frames} written`,
    )
    assert.deepEqual(
      seen.filter((e) => e !== 'notice'),
      ['ready', 'stopped'],
    )
    assert.equal(await t.done(), stopped)

    // the files, where the helper says they are
    assert.equal(stopped.files.recording, join(dir, 'recording.mp4'))
    for (const file of Object.values(stopped.files)) assert.ok(existsSync(file), file)
    assert.equal(boxType(stopped.files.recording), 'ftyp')
    assert.equal(statSync(stopped.files.recording).size, stopped.bytes)
    assert.ok(stopped.bytes > 1000)

    // meta.json is the shape studio-core reads as an 'app' take
    const meta = readJson(stopped.files.meta)
    assert.equal(meta.captureSurface, 'app')
    assert.equal(meta.producer, 'desktop')
    assert.equal(meta.platform, 'mac')
    assert.equal(meta.width, Math.round(listed.frame.w))
    assert.equal(meta.height, Math.round(listed.frame.h))
    assert.equal(meta.captureWidth, ready.captureWidth)
    assert.equal(meta.captureHeight, ready.captureHeight)
    assert.equal(meta.dpr, ready.scale)
    assert.equal(meta.durationMs, stopped.durationMs)
    assert.equal(meta.app.name, listed.app)
    assert.ok(Math.abs(meta.t0 - Date.now()) < 60_000, 't0 is the wall clock at the first frame')
    assert.equal('pageUrl' in meta, false)

    // no pointer was asked for
    assert.deepEqual(readJson(stopped.files.cursor), [])
    assert.equal(stopped.events, 0)
  })

  it(
    'the recording is H.264 at the window pixel size',
    { ...TEST, skip: !has('ffprobe') && 'ffprobe is not installed' },
    async () => {
      const t = start({ window: fixture.id, out: out(), pointer: false })
      const ready = await t.ready()
      await sleep(700)
      const stopped = await t.stop()
      const probe = JSON.parse(
        execFileSync(
          'ffprobe',
          [
            '-v',
            'error',
            '-select_streams',
            'v:0',
            '-show_entries',
            'stream=codec_name,width,height,pix_fmt',
            '-of',
            'json',
            stopped.files.recording,
          ],
          { encoding: 'utf8' },
        ),
      ).streams[0]
      assert.equal(probe.codec_name, 'h264')
      assert.equal(probe.pix_fmt, 'yuv420p')
      assert.equal(probe.width, ready.captureWidth)
      assert.equal(probe.height, ready.captureHeight)
    },
  )

  it('says how round the window is, and the take keeps it', TEST, async () => {
    const t = start({ window: fixture.id, out: out(), pointer: false })
    const ready = await t.ready()
    // A titled window's corners are rounded: a handful of points, never a third of the window.
    assert.ok(ready.cornerRadius > 3 && ready.cornerRadius < 40, `${ready.cornerRadius} points`)
    await sleep(300)
    const stopped = await t.stop()
    assert.equal(readJson(stopped.files.meta).cornerRadius, ready.cornerRadius)
  })

  it(
    'the picture is the window: its own colour inside, black outside its corners',
    TEST,
    async () => {
      const t = start({ window: fixture.id, out: out(), pointer: false })
      await t.ready()
      await sleep(700)
      const stopped = await t.stop()
      const at = stopped.durationMs / 1000 / 2
      const corners = probe(
        stopped.files.recording,
        at,
        [0, 0, 3, 3],
        [-3, 0, 3, 3],
        [0, -3, 3, 3],
        [-3, -3, 3, 3],
      )
      for (const corner of corners) assert.ok(isBlack(corner), `a corner is ${corner}`)
      for (const patch of probe(stopped.files.recording, at, ...CONTENT)) {
        assert.ok(isFixtureBlue(patch), `the content is ${patch}`)
      }
    },
  )

  it('follows the window when it moves: the picture stays the window', TEST, async () => {
    const t = start({ window: fixture.id, out: out(), pointer: false })
    await t.ready()
    await sleep(400)
    // Far enough that a capture left where the window was would show none of it there.
    await fixture.move(180, 120)
    try {
      await sleep(1200)
      const stopped = await t.stop()
      assert.equal(stopped.windowMoved, true)
      assert.ok(stopped.sourceUpdates >= 1, `${stopped.sourceUpdates} updates of the capture`)
      const late = stopped.durationMs / 1000 - 0.15
      for (const patch of probe(stopped.files.recording, late, ...CONTENT)) {
        assert.ok(isFixtureBlue(patch), `after the move the content is ${patch}`)
      }
    } finally {
      await fixture.move(-180, -120)
      await sleep(300)
    }
  })

  it("another app's window over it is never in the picture, not for a frame", TEST, async () => {
    const notices = []
    const t = start(
      { window: fixture.id, out: out(), pointer: false },
      { onEvent: (e) => e.event === 'notice' && notices.push(`${e.code}: ${e.message}`) },
    )
    await t.ready()
    await sleep(400)
    // Another application opens a red window exactly over this one, mid-take.
    const other = await openFixture({ color: [200, 40, 40], title: 'another app' })
    try {
      await sleep(1500)
      const stopped = await t.stop()
      // What the helper did about it, for a failure to say more than a colour.
      const did = `${stopped.filterRefreshes} refreshes, ${stopped.heldFrames} frames held, ${stopped.frames} written; notices: ${notices.join(' | ') || 'none'}`
      assert.ok(
        stopped.filterRefreshes >= 1,
        `the capture learned of the other application (${did})`,
      )
      assert.ok(stopped.frames >= 5, `the take went on (${did})`)
      // Every twentieth of a second, from before the other window opened to the end.
      const end = stopped.durationMs / 1000 - 0.05
      const seen = []
      for (let at = 0.1; at < end; at += 0.05) {
        const [patch] = probe(stopped.files.recording, at, CONTENT[0])
        seen.push({ at: at.toFixed(2), patch })
      }
      const wrong = seen.filter((s) => !isFixtureBlue(s.patch))
      // On failure, when the other window showed and for how long says what went wrong:
      // the whole run of samples, by their red channel.
      assert.equal(
        wrong.length,
        0,
        `the other window is in ${wrong.length} of ${seen.length} samples, first at ${wrong[0]?.at} s as ${wrong[0]?.patch}; ` +
          `red over time: ${seen.map((s) => s.patch[0]).join(' ')} (${did})`,
      )
    } finally {
      other.close()
      await sleep(300)
    }
  })

  it('samples the pointer when asked, as events in the window space', TEST, async () => {
    const t = start({ window: fixture.id, out: out(), pointer: true })
    await t.ready()
    await sleep(500)
    const stopped = await t.stop()
    const track = readJson(stopped.files.cursor)
    assert.ok(Array.isArray(track))
    assert.equal(track.length, stopped.events)
    // The test never moves the pointer, so the track holds only what the person did:
    // whatever is there is inside the window and inside the take.
    for (const e of track) {
      assert.ok(['move', 'down', 'up', 'key'].includes(e.type), e.type)
      assert.ok(e.t >= 0 && e.t <= stopped.durationMs + 50)
      assert.ok(e.x >= 0 && e.x <= listed.frame.w)
      assert.ok(e.y >= 0 && e.y <= listed.frame.h)
      assert.equal('key' in e, false, 'no key identity, at any layer')
    }
  })

  it('finds the window by its app name, the titled one', TEST, async (ctx) => {
    if (!listed.app) return ctx.skip('the fixture process has no application name here')
    const t = start({ app: listed.app, out: out(), pointer: false })
    const ready = await t.ready()
    assert.equal(ready.window, fixture.id)
    await sleep(300)
    assert.equal((await t.stop()).reason, 'stop')
  })

  it(
    'ready means the first frame is written: a stop right after it is still a take',
    TEST,
    async () => {
      const t = start({ window: fixture.id, out: out(), pointer: false })
      await t.ready()
      const stopped = await t.stop()
      assert.ok(stopped.frames >= 1)
      assert.equal(boxType(stopped.files.recording), 'ftyp')
      assert.equal(readJson(stopped.files.meta).durationMs, stopped.durationMs)
    },
  )

  it('stop() twice is one stop', TEST, async () => {
    const t = start({ window: fixture.id, out: out(), pointer: false })
    await t.ready()
    await sleep(400)
    const [a, b] = await Promise.all([t.stop(), t.stop()])
    assert.equal(a, b)
    assert.equal(a.reason, 'stop')
  })

  it('an aborted signal ends the take and its files are written', TEST, async () => {
    const controller = new AbortController()
    const t = start(
      { window: fixture.id, out: out(), pointer: false },
      { signal: controller.signal },
    )
    await t.ready()
    await sleep(400)
    controller.abort()
    const stopped = await t.done()
    assert.equal(stopped.reason, 'stop')
    assert.ok(existsSync(stopped.files.meta))
  })

  it('ends at maxSeconds with nothing on stdin', TEST, async () => {
    const request = { window: fixture.id, out: out(), pointer: false, maxSeconds: 1 }
    // /dev/null on stdin reads as end of input at once, and that must end nothing.
    const run = runHelper(driverPath(), ['record', JSON.stringify(request)], { stdin: 'ignore' })
    const begun = Date.now()
    const stopped = await run.event('stopped')
    assert.equal(stopped.reason, 'cap')
    // every line the helper prints is an event of the protocol, and these are all of them
    assert.deepEqual(
      run.events.map((e) => e.event),
      ['ready', 'stopped'],
    )
    assert.ok(Date.now() - begun >= 900, 'it ran to its ceiling')
    assert.deepEqual(await within(run.exit, WAIT, 'the helper exiting'), { code: 0, signal: null })
  })

  it('ends when the process holding its stdin lets go', TEST, async () => {
    const request = { window: fixture.id, out: out(), pointer: false }
    const run = runHelper(driverPath(), ['record', JSON.stringify(request)], { stdin: 'pipe' })
    await run.event('ready')
    await sleep(400)
    run.child.stdin.end() // what the helper sees when its parent is gone
    const stopped = await run.event('stopped')
    assert.equal(stopped.reason, 'parent-gone')
    assert.deepEqual(
      run.events.map((e) => e.event),
      ['ready', 'stopped'],
    )
    assert.ok(existsSync(stopped.files.recording))
    assert.deepEqual(await within(run.exit, WAIT, 'the helper exiting'), { code: 0, signal: null })
  })

  it('ends on SIGTERM and still writes the take', TEST, async () => {
    const request = { window: fixture.id, out: out(), pointer: false }
    const run = runHelper(driverPath(), ['record', JSON.stringify(request)], { stdin: 'ignore' })
    await run.event('ready')
    await sleep(400)
    run.child.kill('SIGTERM')
    const stopped = await run.event('stopped')
    assert.equal(stopped.reason, 'terminated')
    assert.deepEqual(
      run.events.map((e) => e.event),
      ['ready', 'stopped'],
    )
    assert.equal(boxType(stopped.files.recording), 'ftyp')
    assert.deepEqual(await within(run.exit, WAIT, 'the helper exiting'), { code: 0, signal: null })
  })

  it('says no-window for a target that is not on screen', TEST, async () => {
    const byId = start({ window: 1, out: out() })
    await assert.rejects(byId.done(), (e) => e instanceof DriverError && e.code === 'no-window')
    const byApp = start({ app: 'no.such.app.vos-driver-test', out: out() })
    await assert.rejects(byApp.ready(), (e) => e instanceof DriverError && e.code === 'no-window')
  })
})
