import type { HelperErrorCode } from './protocol.js'

/** Codes this package fails with before, or instead of, the helper. */
export type WrapperErrorCode =
  /** Desktop takes are macOS only. */
  | 'unsupported-platform'
  /** The helper needs macOS 14 or later. */
  | 'unsupported-os'
  /** The platform package that carries the helper is not installed. */
  | 'not-installed'
  /** The helper is there and cannot be run. */
  | 'not-executable'
  /** The helper speaks another protocol than this package. */
  | 'protocol-mismatch'
  /** The helper exited without saying why. */
  | 'crashed'

export type DriverErrorCode = HelperErrorCode | WrapperErrorCode

/** Every failure of this package is one of these: read `code`, show `message`. */
export class DriverError extends Error {
  readonly code: DriverErrorCode

  constructor(code: DriverErrorCode, message: string) {
    super(message)
    this.name = 'DriverError'
    this.code = code
  }
}
