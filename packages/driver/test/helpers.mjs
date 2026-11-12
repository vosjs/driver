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
  const said = () =>
    `it said [${events.map((e) => e.event + (e.code ? `:${e.code}` : '')).join(', ')}]` +
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
 * Builds and shows the fixture window (Fixtures/window.swift): a titled window with a
 * moving bar, owned by a process of ours. Resolves with its window id.
 */
export async function openFixture() {
  const { dir, remove } = scratch('vos-driver-fixture-')
  const binary = join(dir, 'vos-driver-fixture')
  execFileSync('swiftc', ['-O', join(root, 'Fixtures', 'window.swift'), '-o', binary], {
    stdio: ['ignore', 'ignore', 'pipe'],
  })
  const child = track(spawn(binary, [], { stdio: ['pipe', 'pipe', 'inherit'] }))
  const id = await within(
    new Promise((resolve, reject) => {
      let buffer = ''
      child.stdout.setEncoding('utf8').on('data', (chunk) => {
        buffer += chunk
        const at = buffer.indexOf('\n')
        if (at >= 0) resolve(JSON.parse(buffer.slice(0, at)).window)
      })
      child.on('error', reject)
      child.on('close', () =>
        reject(new Error('The fixture window closed before it reported its id.')),
      )
    }),
    30_000,
    'the fixture window reporting its id',
  )
  const close = () => {
    child.stdin.end()
    child.kill()
    remove()
  }
  return { id, close }
}
