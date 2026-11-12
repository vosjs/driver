import { spawn, type ChildProcess } from 'node:child_process'
import { resolve as resolvePath } from 'node:path'
import { DriverError } from './errors.js'
import { driverPath } from './locate.js'
import {
  PROTOCOL_VERSION,
  type CheckEvent,
  type CheckResult,
  type Command,
  type CommandResult,
  type DriverEvent,
  type DriverWindow,
  type ReadyEvent,
  type RecordRequest,
  type StillEvent,
  type StillResult,
  type StoppedEvent,
  type TreeEvent,
  type TreeResult,
  type WindowEvent,
  type WindowRequest,
} from './protocol.js'

/** How much of the helper's stderr is kept to explain a crash. */
const STDERR_TAIL = 2000

/** Turns the helper's stdout into events: one JSON object per line. */
function eventReader(onEvent: (event: DriverEvent) => void) {
  let buffer = ''
  const read = (line: string) => {
    const text = line.trim()
    if (!text) return
    let value: unknown
    try {
      value = JSON.parse(text)
    } catch {
      return // not a line of the protocol
    }
    if (value && typeof value === 'object' && typeof (value as DriverEvent).event === 'string') {
      onEvent(value as DriverEvent)
    }
  }
  return {
    feed(chunk: string) {
      buffer += chunk
      let at: number
      while ((at = buffer.indexOf('\n')) >= 0) {
        read(buffer.slice(0, at))
        buffer = buffer.slice(at + 1)
      }
    },
    flush() {
      read(buffer)
      buffer = ''
    },
  }
}

function protocolMismatch(said: number): DriverError {
  return new DriverError(
    'protocol-mismatch',
    `The helper speaks protocol ${said} and @vosjs/driver speaks ${PROTOCOL_VERSION}. Install matching versions of @vosjs/driver and its platform package.`,
  )
}

function spawnFailure(error: unknown): DriverError {
  if (error instanceof DriverError) return error
  const why = error instanceof Error ? error.message : String(error)
  return new DriverError('not-executable', `The helper could not be started: ${why}`)
}

function crashed(code: number | null, signal: NodeJS.Signals | null, stderr: string): DriverError {
  const how = code !== null ? `exit code ${code}` : `signal ${signal}`
  const said = stderr.trim()
  return new DriverError(
    'crashed',
    `The helper ended (${how}) without finishing.${said ? ` It said: ${said}` : ''}`,
  )
}

/**
 * The longest a verb that answers once is waited for. The helper's own limits are shorter,
 * so its words arrive first; this is for a helper that says nothing at all.
 */
const ANSWER_MS = 45_000

/** Runs a verb that prints its events and exits. */
function collect(args: string[]): Promise<DriverEvent[]> {
  return new Promise((resolve, reject) => {
    let child: ChildProcess
    try {
      child = spawn(driverPath(), args, { stdio: ['ignore', 'pipe', 'pipe'] })
    } catch (error) {
      reject(spawnFailure(error))
      return
    }
    const events: DriverEvent[] = []
    const reader = eventReader((event) => events.push(event))
    let stderr = ''
    let settled = false
    const settle = (failure?: DriverError) => {
      if (settled) return
      settled = true
      clearTimeout(late)
      if (failure) reject(failure)
      else resolve(events)
    }
    const late = setTimeout(() => {
      child.kill('SIGKILL')
      settle(
        new DriverError(
          'crashed',
          `The helper did not answer \`${args[0]}\` within ${ANSWER_MS / 1000} s, and was ended.`,
        ),
      )
    }, ANSWER_MS)
    child.stdout!.setEncoding('utf8').on('data', reader.feed)
    child.stderr!.setEncoding('utf8').on('data', (chunk: string) => {
      stderr = (stderr + chunk).slice(-STDERR_TAIL)
    })
    child.on('error', (error) => settle(spawnFailure(error)))
    child.on('close', (code, signal) => {
      reader.flush()
      const said = events.find((e) => e.event === 'error')
      if (said && said.event === 'error') settle(new DriverError(said.code, said.message))
      else if (code !== 0) settle(crashed(code, signal, stderr))
      else settle()
    })
  })
}

/**
 * What the helper may do on this machine: its version, and whether Screen Recording and
 * Accessibility are granted to the app that launched it.
 *
 * macOS records a grant against the app that started the process (the terminal, the
 * editor, the agent's host), so the answer is that app's, and it is read by a fresh
 * helper process every call.
 */
export async function check(): Promise<CheckResult> {
  const events = await collect(['check'])
  const found = events.find((e): e is CheckEvent => e.event === 'check')
  if (!found) throw new DriverError('crashed', 'The helper answered `check` with nothing.')
  if (found.protocol !== PROTOCOL_VERSION) throw protocolMismatch(found.protocol)
  return {
    version: found.version,
    protocol: found.protocol,
    screenRecording: found.screenRecording,
    accessibility: found.accessibility,
    path: found.path,
    bundleId: found.bundleId,
    os: found.os,
  }
}

/**
 * The windows on screen that can be recorded. Needs Screen Recording.
 *
 * @throws {DriverError} `screen-recording` when it is not granted.
 */
export async function windows(): Promise<DriverWindow[]> {
  const events = await collect(['windows'])
  return events
    .filter((e): e is WindowEvent => e.event === 'window')
    .map((w) => ({ id: w.id, app: w.app, appId: w.appId, titled: w.titled, frame: w.frame }))
}

/**
 * The outline of an app's window: each element a script can name, with a selector for it.
 * Needs Accessibility. What a person typed into a field is never read.
 *
 * @throws {DriverError} `accessibility` when it is not granted, `no-window`, `no-tree`.
 */
export async function tree(request: WindowRequest): Promise<TreeResult> {
  const events = await collect(['tree', JSON.stringify(request)])
  const found = events.find((e): e is TreeEvent => e.event === 'tree')
  if (!found) throw new DriverError('crashed', 'The helper answered `tree` with nothing.')
  return { app: found.app, window: found.window, elements: found.elements }
}

/**
 * One picture of an app's window, as a take would show it: a PNG at the window's pixel
 * size, with no pointer and nothing of any other app. Needs Screen Recording.
 */
export async function still(request: WindowRequest & { out: string }): Promise<StillResult> {
  const wire = { ...request, out: resolvePath(request.out) }
  const events = await collect(['still', JSON.stringify(wire)])
  const found = events.find((e): e is StillEvent => e.event === 'still')
  if (!found) throw new DriverError('crashed', 'The helper answered `still` with nothing.')
  const { event: _event, ...result } = found
  return result
}

export interface RecordOptions {
  /** Every line the helper prints, as it arrives. */
  onEvent?: (event: DriverEvent) => void
  /** Aborting ends the take as `stop()` does: its files are still written. */
  signal?: AbortSignal
}

/** A take being recorded. */
export interface Recording {
  /** The helper's process id. */
  readonly pid: number | undefined
  /**
   * Settles when the first frame is in the file: the take has its time zero. Rejects with
   * a `DriverError` if it never gets there.
   */
  readonly ready: Promise<ReadyEvent>
  /**
   * Settles when the take is written, whatever ended it. Rejects with a `DriverError`
   * if the take failed.
   */
  readonly done: Promise<StoppedEvent>
  /** Ends the take; resolves as `done` does. Calling it again is the same stop. */
  stop(): Promise<StoppedEvent>
  /**
   * Does one act of a script and resolves with its answer. Commands run one at a time, in
   * the order sent. A command that did nothing (`not-found`, a disabled control) resolves
   * with `ok: false` or `pressed: false`: the script decides what that means. It rejects
   * only when the take ended before the command was answered.
   *
   * The take is recorded with `drive: true`, and commands belong after `ready`.
   */
  send(command: Command): Promise<CommandResult>
}

/**
 * Records one application window into `request.out`: `recording.mp4` (H.264, the window
 * at its pixel size, no system pointer in the pixels), `cursor.json` (the pointer's path
 * in the window's own points) and `meta.json`.
 *
 * It returns at once. Await `ready` to know the take has begun, then `stop()` to end the
 * take. The take also ends at `maxSeconds`, when the window's capture stops, and when
 * this process goes away: a recorder never outlives what started it.
 */
export function record(request: RecordRequest, options: RecordOptions = {}): Recording {
  let resolveReady!: (event: ReadyEvent) => void
  let rejectReady!: (error: DriverError) => void
  let resolveDone!: (event: StoppedEvent) => void
  let rejectDone!: (error: DriverError) => void
  const ready = new Promise<ReadyEvent>((resolve, reject) => {
    resolveReady = resolve
    rejectReady = reject
  })
  const done = new Promise<StoppedEvent>((resolve, reject) => {
    resolveDone = resolve
    rejectDone = reject
  })
  // A caller may await only one of the two; the other must not become an unhandled rejection.
  ready.catch(() => {})
  done.catch(() => {})

  let child: ChildProcess
  try {
    const wire = { ...request, out: resolvePath(request.out) }
    child = spawn(driverPath(), ['record', JSON.stringify(wire)], {
      stdio: ['pipe', 'pipe', 'pipe'],
    })
  } catch (error) {
    const failure = spawnFailure(error)
    rejectReady(failure)
    rejectDone(failure)
    return { pid: undefined, ready, done, stop: () => done, send: () => Promise.reject(failure) }
  }

  let isReady = false
  let stopped: StoppedEvent | undefined
  let failure: DriverError | undefined
  let stderr = ''
  let asked = false
  let finished = false
  let nextId = 0
  const waiting = new Map<
    number,
    { resolve: (r: CommandResult) => void; reject: (e: DriverError) => void }
  >()

  const send = (command: Command): Promise<CommandResult> => {
    if (finished || asked || !child.stdin?.writable) {
      return Promise.reject(
        new DriverError('crashed', 'The take has ended: it takes no more commands.'),
      )
    }
    const id = ++nextId
    return new Promise<CommandResult>((resolve, reject) => {
      waiting.set(id, { resolve, reject })
      child.stdin!.write(JSON.stringify({ id, ...command }) + '\n')
    })
  }

  const stop = (): Promise<StoppedEvent> => {
    if (!asked && child.stdin?.writable) {
      asked = true
      child.stdin.write('stop\n')
    }
    return done
  }

  const finish = () => {
    if (finished) return
    finished = true
    for (const { reject } of waiting.values()) {
      reject(
        failure ?? new DriverError('crashed', 'The take ended before the command was answered.'),
      )
    }
    waiting.clear()
    if (failure) {
      if (!isReady) rejectReady(failure)
      rejectDone(failure)
    } else {
      resolveDone(stopped!)
    }
  }

  const reader = eventReader((event) => {
    if (event.event === 'ready') {
      if (event.protocol !== PROTOCOL_VERSION) {
        failure ??= protocolMismatch(event.protocol)
        void stop()
      } else {
        isReady = true
        resolveReady(event)
      }
    } else if (event.event === 'result') {
      const { event: _event, id, ...result } = event
      if (id !== undefined) {
        waiting.get(id)?.resolve(result as CommandResult)
        waiting.delete(id)
      }
    } else if (event.event === 'stopped') {
      stopped = event
    } else if (event.event === 'error') {
      failure ??= new DriverError(event.code, event.message)
    }
    options.onEvent?.(event)
  })

  child.stdout!.setEncoding('utf8').on('data', reader.feed)
  child.stderr!.setEncoding('utf8').on('data', (chunk: string) => {
    stderr = (stderr + chunk).slice(-STDERR_TAIL)
  })
  // The helper may be gone before `stop` is written.
  child.stdin!.on('error', () => {})
  child.on('error', (error) => {
    failure ??= spawnFailure(error)
    finish()
  })
  child.on('close', (code, signal) => {
    reader.flush()
    if (!failure && !stopped) failure = crashed(code, signal, stderr)
    finish()
  })

  const { signal } = options
  if (signal) {
    if (signal.aborted) {
      void stop()
    } else {
      const onAbort = () => void stop()
      signal.addEventListener('abort', onAbort, { once: true })
      const forget = () => signal.removeEventListener('abort', onAbort)
      done.then(forget, forget)
    }
  }

  return {
    get pid() {
      return child.pid
    },
    ready,
    done,
    stop,
    send,
  }
}
