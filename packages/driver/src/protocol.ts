/**
 * The helper's wire protocol, as types. The helper prints one JSON object per line on
 * stdout; every object has an `event`. This file is the contract: the Swift source
 * (Sources/vos-driver/main.swift) is held to it by the tests.
 */

/**
 * The protocol this package speaks. It moves when a request field or an event changes
 * meaning, and a helper that says another number is refused.
 */
export const PROTOCOL_VERSION = 1

/** A rectangle in points. */
export interface Rect {
  x: number
  y: number
  w: number
  h: number
}

/**
 * How the window is scoped.
 *
 * `others-out` (the default) is the display with every window that is not the app's
 * excluded, cropped to the window. The rest name the window or its app, and on macOS 26 that makes
 * the system draw its sharing control over the window's traffic lights, where it lands
 * in the pixels. They are kept for measuring other macOS versions.
 */
export type CaptureFilter = 'others-out' | 'window' | 'app' | 'display-window' | 'display'

/** What `record` is asked for. Give `window` or `app`. */
export interface RecordRequest {
  /** A window id from `windows()`. Wins over `app`. */
  window?: number
  /** An application's name or bundle id: its largest titled window is recorded. */
  app?: string
  /** A directory. `recording.mp4`, `cursor.json` and `meta.json` are written there. */
  out: string
  /** The frame-rate ceiling, 1 to 120. Default 60. Frames arrive only when pixels change. */
  fps?: number
  /** The encoder's average bit rate. Default 8,000,000. */
  bitrate?: number
  /** A safety ceiling in seconds. Default 3600. Pass your own. */
  maxSeconds?: number
  /** Sample the real pointer into `cursor.json` (a performed take). Default true. */
  pointer?: boolean
  /** Read the bounds of what was pressed and typed in. Needs Accessibility. Default false. */
  frames?: boolean
  /** Default `others-out`. */
  filter?: CaptureFilter
  /**
   * A scripted take: the app is brought to the front before the capture, and the take
   * accepts commands (`Recording.send`). Needs Accessibility. Default false.
   */
  drive?: boolean
  /**
   * Give the window this size, in points, before the capture. Needs Accessibility. An app
   * may refuse a size (its minimum, its screen); `ready.frame` says what the take is.
   */
  size?: { w: number; h: number }
}

/** What `tree` and `still` are asked about. Give `window` or `app`. */
export interface WindowRequest {
  /** A window id from `windows()`. Wins over `app`. */
  window?: number
  /** An application's name or bundle id: its main window. */
  app?: string
}

/** One element of a window that a script can name. */
export interface TreeElement {
  /** `button`, `textfield`, `checkbox`, `text`, `link`, `menuitem`, and so on. */
  role: string
  /** A selector that names this element. Pass it to a command as it is. */
  selector: string
  /** False when the selector needed `:nth(n)` to be this element: it names by position. */
  unique: boolean
  enabled: boolean
  /** In the window's own points. */
  rect: Rect
  /** What the interface calls it: a title, a label's words, a field's placeholder. */
  name?: string
  /** The accessibility identifier, when the app's maker set one. */
  id?: string
}

/**
 * The outline of a window: each element worth naming. The contents of anything a person
 * types into are never in it.
 */
export interface TreeResult {
  app: string
  /** The window's size in points. */
  window: { w: number; h: number }
  elements: TreeElement[]
}

export interface TreeEvent extends TreeResult {
  event: 'tree'
}

/** One picture of a window, as a take would show it. */
export interface StillResult {
  /** The PNG's absolute path. */
  out: string
  app: string
  window: number
  /** The picture's size in pixels. */
  width: number
  height: number
  /** Pixels per point. */
  scale: number
  /** The window's frame in global points. */
  frame: Rect
}

export interface StillEvent extends StillResult {
  event: 'still'
}

/** What a command acts on: an element by selector, or a point in the window's own points. */
export type CommandTarget = { selector: string } | { x: number; y: number }

/**
 * One act of a scripted take. The pointer travels to its target as a hand does, and what
 * it does is in the take's cursor track like any person's.
 *
 * A selector is a short path: `button[name='Save']`, `textfield[id='title']`,
 * `toolbar > button[name*='Share']`, `button[name='Delete']:nth(1)`, `*[id='sidebar']`.
 */
export type Command =
  /** Finds without acting: how many match, and where the first is. */
  | ({ do: 'locate' } & CommandTarget)
  | ({
      do: 'click'
      count?: number
      button?: 'left' | 'right'
      modifiers?: Modifier[]
    } & CommandTarget)
  | ({ do: 'hover' } & CommandTarget)
  /** Types text, a character at a time. With a target, presses it first. */
  | ({ do: 'type'; text: string; delayMs?: number } & Partial<CommandTarget>)
  /** A chord like `Meta+S` or `Enter`, or several in order. */
  | { do: 'press'; keys: string | string[] }
  /** Turns the wheel, in points; positive `dy` scrolls down. With a target, over it. */
  | ({ do: 'scroll'; dy?: number; dx?: number; ms?: number } & Partial<CommandTarget>)
  | ({ do: 'drag'; to: CommandTarget; ms?: number; modifiers?: Modifier[] } & CommandTarget)
  /** Moves the pointer and does nothing else. */
  | ({ do: 'move'; ms?: number } & CommandTarget)
  /** Does nothing: its answer's `tEnd` is the take's clock, now. */
  | { do: 'now' }

/** A key held through a click or a drag. */
export type Modifier = 'Meta' | 'Control' | 'Alt' | 'Shift'

/** Why a command did nothing. */
export type CommandFailureCode =
  | 'bad-request'
  /** Nothing in the window matches the selector. */
  | 'not-found'
  /** The element is there, outside the window's visible area. */
  | 'not-in-view'
  /** The app could not be brought to the front, so input would go to another one. */
  | 'not-frontmost'
  /** The take has not begun: wait for `ready`. */
  | 'not-ready'
  | 'accessibility'
  | 'no-window'
  /** The window offers no accessibility tree. */
  | 'no-tree'
  | 'failed'

/** A command's answer. Times are milliseconds on the take's clock: its extent in the footage. */
export type CommandResult =
  | {
      ok: true
      tStart: number
      tEnd: number
      /** How many elements the selector matches. The first is the one acted on. */
      count?: number
      enabled?: boolean
      /** `locate` only: what the interface calls the element. Never what was typed into it. */
      name?: string
      /** The element's bounds, in the window's own points. */
      rect?: Rect
      /** `click` only: false when the element is disabled, so it was reached and not pressed. */
      pressed?: boolean
    }
  | { ok: false; code: CommandFailureCode; message: string }

export type ResultEvent = { event: 'result'; id?: number } & CommandResult

/** What the helper may do, and what it is. */
export interface CheckResult {
  /** The helper's version: the version of this package. */
  version: string
  protocol: number
  /** Screen Recording is granted to the app that launched the helper. */
  screenRecording: boolean
  /** Accessibility is granted to the app that launched the helper. */
  accessibility: boolean
  /** The helper's own path. */
  path: string
  /** The helper's bundle id, or empty for a bare binary. */
  bundleId: string
  /** The system's version string. */
  os: string
}

/** A window that can be recorded. */
export interface DriverWindow {
  /** Pass this as `RecordRequest.window`. */
  id: number
  /** The owning application's name. */
  app: string
  /** The owning application's bundle id, or empty. */
  appId: string
  /** False for an alert or a panel with no title. */
  titled: boolean
  /** The window's frame in global points, origin top-left. */
  frame: Rect
}

/**
 * The take has begun: the first frame is in the file, so the take has its time zero.
 * Anything a caller does to the app belongs after this.
 */
export interface ReadyEvent {
  event: 'ready'
  protocol: number
  window: number
  app: string
  frame: Rect
  /** Pixels per point. */
  scale: number
  captureWidth: number
  captureHeight: number
  filter: CaptureFilter
  accessibility: boolean
  /**
   * The radius of the window's own rounded corners, in points; 0 when they are square or
   * could not be read. Outside them the recording is opaque black, so anything that frames
   * the recording should be at least this round. It is also in `meta.json`.
   */
  cornerRadius: number
}

/** Why a take ended. */
export type StopReason =
  /** `stop` on stdin: the caller asked. */
  | 'stop'
  /** `maxSeconds` was reached. */
  | 'cap'
  /** SIGINT. */
  | 'interrupt'
  /** SIGTERM. */
  | 'terminated'
  /** Stdin was a pipe and it closed: the process that started the helper is gone. */
  | 'parent-gone'
  /** The capture stream stopped by itself, for example because the window closed. */
  | 'stream-stopped'

/** The take is written. */
export interface StoppedEvent {
  event: 'stopped'
  reason: StopReason
  /** The recording's length: the last frame's time. */
  durationMs: number
  frames: number
  /** Frames the system reported with nothing changed. They are not in the file. */
  idleFrames: number
  droppedFrames: number
  /** The recording's size. */
  bytes: number
  /** Events in `cursor.json`. */
  events: number
  windowMoved: boolean
  resized: boolean
  /** Times the capture was moved to stay on the window. */
  sourceUpdates: number
  /** Times the list of excluded windows was brought up to date. */
  filterRefreshes: number
  /**
   * Frames held back because a window of something else was over this one and not yet
   * excluded. They are not in the file: the picture keeps its last clean frame.
   */
  heldFrames: number
  /** Absolute paths of what was written. */
  files: { recording: string; cursor: string; meta: string }
  /** Clock diagnostics: the host time of the first frame, and how late frames arrived. */
  clock: { t0Host: number; arrivalLagMsMean: number; arrivalLagMsMax: number }
}

/**
 * Something worth knowing that did not end the take by itself. Codes so far:
 * `stream-stopped` (the capture ended by itself), `slow-stop` (the capture took too long to
 * stop; the take is written anyway), `not-excludable` (a window over this one could not be
 * kept out of the capture).
 */
export interface NoticeEvent {
  event: 'notice'
  code: string
  message: string
}

/** Codes the helper fails with. */
export type HelperErrorCode =
  /** The request is not what `RecordRequest` describes. */
  | 'bad-request'
  /** Screen Recording is not granted to the app that launched the helper. */
  | 'screen-recording'
  /** No window on screen matches the request. */
  | 'no-window'
  /** The capture could not start, or the system did not answer in time. */
  | 'start-failed'
  /** The take ended before the window produced a frame. */
  | 'no-frames'
  /** The recording or its files could not be written. */
  | 'write-failed'
  /** Accessibility is not granted to the app that launched the helper, and the request needs it. */
  | 'accessibility'
  /** The window offers no accessibility tree. */
  | 'no-tree'

export interface ErrorEvent {
  event: 'error'
  code: HelperErrorCode
  message: string
}

export interface VersionEvent {
  event: 'version'
  version: string
  protocol: number
}

export interface CheckEvent extends CheckResult {
  event: 'check'
}

export interface WindowEvent extends DriverWindow {
  event: 'window'
}

/** Every line the helper prints. */
export type DriverEvent =
  | VersionEvent
  | CheckEvent
  | WindowEvent
  | TreeEvent
  | StillEvent
  | ReadyEvent
  | ResultEvent
  | StoppedEvent
  | NoticeEvent
  | ErrorEvent
