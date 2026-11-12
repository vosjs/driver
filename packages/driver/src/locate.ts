import { accessSync, constants, existsSync } from 'node:fs'
import { createRequire } from 'node:module'
import { release } from 'node:os'
import { DriverError } from './errors.js'

/** The package that carries the helper, per platform. */
const PLATFORM_PACKAGES: Partial<Record<NodeJS.Platform, string>> = {
  darwin: '@vosjs/driver-darwin',
}

/** macOS 14 is Darwin 23: the helper's floor. */
const DARWIN_FLOOR = 23

const require = createRequire(import.meta.url)

/**
 * The helper's path on this machine.
 *
 * `VOS_DRIVER_PATH` names a helper to use instead of the installed one (a local build).
 * Otherwise it is `bin/vos-driver` in the platform package, an optional dependency of
 * this one that the package manager installs only where it runs.
 *
 * @throws {DriverError} `unsupported-platform`, `unsupported-os`, `not-installed` or
 *   `not-executable`, each with a sentence that says what to do.
 */
export function driverPath(): string {
  const pkg = PLATFORM_PACKAGES[process.platform]
  if (!pkg) {
    throw new DriverError(
      'unsupported-platform',
      `Desktop takes are recorded on macOS. This is ${process.platform}.`,
    )
  }
  if (process.platform === 'darwin') {
    const major = Number(release().split('.')[0])
    if (Number.isFinite(major) && major < DARWIN_FLOOR) {
      throw new DriverError(
        'unsupported-os',
        `Desktop takes need macOS 14 or later. This is Darwin ${release()}.`,
      )
    }
  }

  const override = process.env.VOS_DRIVER_PATH
  let path: string
  if (override) {
    if (!existsSync(override)) {
      throw new DriverError('not-installed', `VOS_DRIVER_PATH names no file: ${override}`)
    }
    path = override
  } else {
    try {
      path = require.resolve(`${pkg}/bin/vos-driver`)
    } catch {
      throw new DriverError(
        'not-installed',
        `${pkg} is not installed. It is an optional dependency of @vosjs/driver: install again without --omit=optional or --no-optional.`,
      )
    }
  }

  try {
    accessSync(path, constants.X_OK)
  } catch {
    throw new DriverError('not-executable', `The helper cannot be run: ${path}`)
  }
  return path
}
