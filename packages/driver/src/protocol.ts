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
}

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
  VersionEvent | CheckEvent | WindowEvent | ReadyEvent | StoppedEvent | NoticeEvent | ErrorEvent
