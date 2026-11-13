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
  Command,
  CommandFailureCode,
  CommandResult,
  CommandTarget,
  DriverEvent,
  DriverWindow,
  ErrorEvent,
  HelperErrorCode,
  MaskReport,
  MaskTarget,
  Modifier,
  NoticeEvent,
  ReadyEvent,
  RecordRequest,
  Rect,
  ResultEvent,
  StillEvent,
  StillResult,
  StopReason,
  StoppedEvent,
  TreeElement,
  TreeEvent,
  TreeResult,
  VersionEvent,
  WindowEvent,
  WindowRequest,
} from './protocol.js'
export { check, record, still, tree, windows } from './run.js'
export { selectorProblem } from './selector.js'
export type { RecordOptions, Recording } from './run.js'
