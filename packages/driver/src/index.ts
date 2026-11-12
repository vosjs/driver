/**
 * @vosjs/driver: records a desktop app's window for a vos take.
 *
 * The work is done by a small native helper (`vos-driver`) that this package finds and
 * runs. The helper has no window, no settings and no state: one process per take.
 */
export { DriverError } from './errors.js'
export type { DriverErrorCode, WrapperErrorCode } from './errors.js'
export { driverPath } from './locate.js'
export { PROTOCOL_VERSION } from './protocol.js'
export type {
  CaptureFilter,
  CheckEvent,
  CheckResult,
  DriverEvent,
  DriverWindow,
  ErrorEvent,
  HelperErrorCode,
  NoticeEvent,
  ReadyEvent,
  RecordRequest,
  Rect,
  StopReason,
  StoppedEvent,
  VersionEvent,
  WindowEvent,
} from './protocol.js'
export { check, record, windows } from './run.js'
export type { RecordOptions, Recording } from './run.js'
