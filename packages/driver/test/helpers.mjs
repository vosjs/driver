import { execFileSync, spawn } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const here = dirname(fileURLToPath(import.meta.url))
export const root = join(here, '..', '..', '..')
export const onMac = process.platform === 'darwin'

export const readJson = (...parts) => JSON.parse(readFileSync(join(...parts), 'utf8'))

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

export function has(command) {
  try {
    execFileSync('which', [command], { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

/** A directory that is gone when the returned function is called. */
export function scratch(prefix = 'vos-driver-test-') {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  return { dir, remove: () => rmSync(dir, { recursive: true, force: true }) }
}

/** Every process a test started, so none is left holding the test run open. */
const started = new Set()
const track = (child) => {
  started.add(child)
  child.on('close', () => started.delete(child))
  return child
}
export function killStarted() {
  for (const child of started) child.kill('SIGKILL')
  started.clear()
}
/** Ends a process by id if it still runs. For helpers started through the wrapper. */
export function killPid(pid) {
  if (!pid) return
  try {
    process.kill(pid, 'SIGKILL')
  } catch {
    // already gone
  }
}

/**
 * Settles as `promise` does, or rejects after `ms` with what was being waited for.
 * A test that waits on a process must fail in words, never wait for good.
 */
export function within(promise, ms, what) {
  let timer
  const late = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what}: nothing within ${ms / 1000} s`)), ms)
  })
  return Promise.race([promise, late]).finally(() => clearTimeout(timer))
}

/**
 * Runs the helper directly, with the stdin the test chooses, and gathers what it said.
 * `stdin: 'ignore'` is /dev/null; `'pipe'` is a pipe this process holds.
 */
export function runHelper(path, args, { stdin = 'ignore' } = {}) {
  const child = track(spawn(path, args, { stdio: [stdin, 'pipe', 'pipe'] }))
  const events = []
  let buffer = ''
  let stderr = ''
  let ended = false
  const waiters = []
  const wake = () => {
    for (const w of waiters.splice(0)) w()
  }
  child.stdout.setEncoding('utf8').on('data', (chunk) => {
    buffer += chunk
    let at
    while ((at = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, at).trim()
      buffer = buffer.slice(at + 1)
      if (line) events.push(JSON.parse(line))
    }
    wake()
  })
  child.stderr.setEncoding('utf8').on('data', (chunk) => (stderr += chunk))
  const exit = new Promise((resolve) => {
    child.on('close', (code, signal) => {
      ended = true
      wake()
      resolve({ code, signal })
    })
  })
  // A line with no `event` is not a line of the protocol: show it whole, it is the finding.
  const said = () =>
    `it said [${events.map((e) => (typeof e.event === 'string' ? e.event + (e.code ? `:${e.code}` : '') : JSON.stringify(e))).join(', ')}]` +
    (stderr.trim() ? ` and wrote to stderr: ${stderr.trim()}` : '')

  /**
   * Resolves with the first event of that name. Rejects, saying everything the helper
   * said, if the helper ends first or the event does not come in time.
   */
  const event = async (name, ms = 30_000) => {
    const deadline = Date.now() + ms
    for (;;) {
      const found = events.find((e) => e.event === name)
      if (found) return found
      if (ended) throw new Error(`The helper ended without "${name}": ${said()}`)
      const left = deadline - Date.now()
      if (left <= 0) {
        child.kill('SIGKILL')
        throw new Error(`No "${name}" from the helper within ${ms / 1000} s: ${said()}`)
      }
      await Promise.race([new Promise((resolve) => waiters.push(resolve)), sleep(left)])
    }
  }
  return { child, events, exit, event, said }
}

/**
 * The test tools in Fixtures/, built once per run: `window` (a window to record) and
 * `probe` (reads pixels out of a recording).
 */
let tools
function builtTools() {
  if (!tools) {
    const { dir, remove } = scratch('vos-driver-tools-')
    process.on('exit', remove)
    for (const name of ['window', 'probe']) {
      execFileSync(
        'swiftc',
        ['-O', join(root, 'Fixtures', `${name}.swift`), '-o', join(dir, name)],
        {
          stdio: ['ignore', 'ignore', 'pipe'],
        },
      )
    }
    tools = { window: join(dir, 'window'), probe: join(dir, 'probe') }
  }
  return tools
}

/**
 * Shows a fixture window (Fixtures/window.swift): titled, one flat colour, with a moving
 * bar, owned by a process of ours. Resolves once it is on screen.
 *
 * `move(dx, dy)` moves it by that many points, right and down.
 */
export async function openFixture({ color, title } = {}) {
  const args = []
  if (color) args.push('--color', color.join(','))
  if (title) args.push('--title', title)
  const child = track(spawn(builtTools().window, args, { stdio: ['pipe', 'pipe', 'inherit'] }))
  const said = []
  const waiters = []
  let ended = false
  let buffer = ''
  child.stdout.setEncoding('utf8').on('data', (chunk) => {
    buffer += chunk
    let at
    while ((at = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, at).trim()
      buffer = buffer.slice(at + 1)
      if (line) said.push(JSON.parse(line))
    }
    for (const w of waiters.splice(0)) w()
  })
  child.on('close', () => {
    ended = true
    for (const w of waiters.splice(0)) w()
  })
  /** The next thing the window says that has this key. */
  const next = (key) =>
    within(
      (async () => {
        for (;;) {
          const at = said.findIndex((line) => key in line)
          if (at >= 0) return said.splice(at, 1)[0]
          if (ended) throw new Error(`The fixture window closed before it said "${key}".`)
          await new Promise((resolve) => waiters.push(resolve))
        }
      })(),
      30_000,
      `the fixture window saying "${key}"`,
    )
  const id = (await next('window')).window
  return {
    id,
    async move(dx, dy) {
      child.stdin.write(`move ${dx} ${dy}\n`)
      await next('moved')
    },
    close() {
      child.stdin.end()
      child.kill()
    },
  }
}

/**
 * The mean colour of rectangles of one frame of a recording (Fixtures/probe.swift).
 * A rectangle is `[x, y, w, h]` in the recording's pixels; a negative x or y counts from
 * the right or the bottom edge. Returns `[r, g, b]` per rectangle, 0 to 255.
 */
export function probe(recording, seconds, ...rects) {
  const out = execFileSync(
    builtTools().probe,
    [recording, String(seconds), ...rects.map((r) => r.join(','))],
    { encoding: 'utf8' },
  )
  return JSON.parse(out).colors
}
