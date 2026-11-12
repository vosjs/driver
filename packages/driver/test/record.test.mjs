// What needs a screen: recording a real window. The window is a fixture this test
// builds and owns (Fixtures/window.swift), so nothing of the machine's is recorded.
//
// It runs where Screen Recording is granted to whatever launched the tests and swiftc
// is on the path; anywhere else the suite says why it is skipped.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync, openSync, readSync, closeSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { after, before, describe, it } from 'node:test'
import { DriverError, check, driverPath, record, windows } from '../dist/index.js'
import { has, onMac, openFixture, readJson, runHelper, scratch, sleep } from './helpers.mjs'

const granted = onMac ? (await check()).screenRecording : false
const skip = !onMac
  ? 'the helper is macOS only'
  : !granted
    ? 'Screen Recording is not granted to the app that launched these tests'
    : !has('swiftc')
      ? 'swiftc is not on the path, so the fixture window cannot be built'
      : false

const even = (n) => n - (n % 2)

/** The first eight bytes of a file: an MP4 begins with a box whose type is `ftyp`. */
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
  const out = () => {
    const s = scratch('vos-driver-take-')
    dirs.push(s)
    return s.dir
  }

  before(async () => {
    fixture = await openFixture()
    // The window server lists a new window a moment after it is drawn.
    for (let i = 0; i < 50 && !listed; i++) {
      listed = (await windows()).find((w) => w.id === fixture.id)
      if (!listed) await sleep(100)
    }
  })

  after(() => {
    fixture?.close()
    for (const s of dirs) s.remove()
  })

  it('lists the fixture window, titled, with its frame', () => {
    assert.ok(listed, 'the fixture window is among windows()')
    assert.equal(listed.titled, true)
    assert.equal(listed.frame.w, 480)
    assert.ok(listed.frame.h >= 320, 'the frame holds the title bar above 320 points of content')
    assert.equal(typeof listed.app, 'string')
  })

  it('records it into a take: video, track and meta', async () => {
    const dir = out()
    const seen = []
    const take = record(
      { window: fixture.id, out: dir, pointer: false },
      { onEvent: (event) => seen.push(event.event) },
    )
    const ready = await take.ready
    assert.equal(ready.window, fixture.id)
    assert.equal(ready.filter, 'others-out')
    assert.equal(ready.frame.w, listed.frame.w)
    assert.equal(ready.captureWidth, even(Math.round(listed.frame.w * ready.scale)))
    assert.equal(ready.captureHeight, even(Math.round(listed.frame.h * ready.scale)))
    assert.equal(typeof take.pid, 'number')

    await sleep(1200)
    const stopped = await take.stop()
    assert.equal(stopped.reason, 'stop')
    assert.ok(stopped.frames >= 5, `the moving bar made frames (${stopped.frames})`)
    assert.ok(stopped.durationMs > 500 && stopped.durationMs < 6000, `${stopped.durationMs} ms`)
    assert.equal(stopped.droppedFrames, 0)
    assert.deepEqual(seen, ['ready', 'stopped'])
    assert.equal(await take.done, stopped)

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
    { skip: !has('ffprobe') && 'ffprobe is not installed' },
    async () => {
      const dir = out()
      const take = record({ window: fixture.id, out: dir, pointer: false })
      const ready = await take.ready
      await sleep(700)
      const stopped = await take.stop()
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

  it('samples the pointer when asked, as events in the window space', async () => {
    const dir = out()
    const take = record({ window: fixture.id, out: dir, pointer: true })
    await take.ready
    await sleep(500)
    const stopped = await take.stop()
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

  it('finds the window by its app name, the titled one', { skip: false }, async (t) => {
    if (!listed.app) return t.skip('the fixture process has no application name here')
    const dir = out()
    const take = record({ app: listed.app, out: dir, pointer: false })
    const ready = await take.ready
    assert.equal(ready.window, fixture.id)
    await sleep(300)
    assert.equal((await take.stop()).reason, 'stop')
  })

  it('ready means the first frame is written: a stop right after it is still a take', async () => {
    const take = record({ window: fixture.id, out: out(), pointer: false })
    await take.ready
    const stopped = await take.stop()
    assert.ok(stopped.frames >= 1)
    assert.equal(boxType(stopped.files.recording), 'ftyp')
    assert.equal(readJson(stopped.files.meta).durationMs, stopped.durationMs)
  })

  it('stop() twice is one stop', async () => {
    const take = record({ window: fixture.id, out: out(), pointer: false })
    await take.ready
    await sleep(400)
    const [a, b] = await Promise.all([take.stop(), take.stop()])
    assert.equal(a, b)
    assert.equal(a.reason, 'stop')
  })

  it('an aborted signal ends the take and its files are written', async () => {
    const controller = new AbortController()
    const take = record(
      { window: fixture.id, out: out(), pointer: false },
      { signal: controller.signal },
    )
    await take.ready
    await sleep(400)
    controller.abort()
    const stopped = await take.done
    assert.equal(stopped.reason, 'stop')
    assert.ok(existsSync(stopped.files.meta))
  })

  it('ends at maxSeconds with nothing on stdin', async () => {
    const dir = out()
    const request = { window: fixture.id, out: dir, pointer: false, maxSeconds: 1 }
    // /dev/null on stdin reads as end of input at once, and that must end nothing.
    const run = runHelper(driverPath(), ['record', JSON.stringify(request)], { stdin: 'ignore' })
    const started = Date.now()
    const stopped = await run.event('stopped')
    assert.ok(stopped, run.stderr())
    assert.equal(stopped.reason, 'cap')
    assert.ok(Date.now() - started >= 900, 'it ran to its ceiling')
    assert.deepEqual(await run.exit, { code: 0, signal: null })
  })

  it('ends when the process holding its stdin lets go', async () => {
    const request = { window: fixture.id, out: out(), pointer: false }
    const run = runHelper(driverPath(), ['record', JSON.stringify(request)], { stdin: 'pipe' })
    assert.ok(await run.event('ready'), run.stderr())
    await sleep(400)
    run.child.stdin.end() // what the helper sees when its parent is gone
    const stopped = await run.event('stopped')
    assert.equal(stopped.reason, 'parent-gone')
    assert.ok(existsSync(stopped.files.recording))
    assert.deepEqual(await run.exit, { code: 0, signal: null })
  })

  it('ends on SIGTERM and still writes the take', async () => {
    const request = { window: fixture.id, out: out(), pointer: false }
    const run = runHelper(driverPath(), ['record', JSON.stringify(request)], { stdin: 'ignore' })
    assert.ok(await run.event('ready'), run.stderr())
    await sleep(400)
    run.child.kill('SIGTERM')
    const stopped = await run.event('stopped')
    assert.equal(stopped.reason, 'terminated')
    assert.equal(boxType(stopped.files.recording), 'ftyp')
    assert.deepEqual(await run.exit, { code: 0, signal: null })
  })

  it('says no-window for a target that is not on screen', async () => {
    const byId = record({ window: 1, out: out() })
    await assert.rejects(byId.done, (e) => e instanceof DriverError && e.code === 'no-window')
    const byApp = record({ app: 'no.such.app.vos-driver-test', out: out() })
    await assert.rejects(byApp.ready, (e) => e instanceof DriverError && e.code === 'no-window')
  })
})
