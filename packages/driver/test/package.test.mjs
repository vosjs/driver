// What holds without a screen: versions, where the helper is found, and what it says
// about itself and about a request it refuses.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, it } from 'node:test'
import { DriverError, PROTOCOL_VERSION, check, driverPath, record } from '../dist/index.js'
import { here, onMac, readJson, root, scratch } from './helpers.mjs'

const pkg = readJson(here, '..', 'package.json')
const platformPkg = readJson(root, 'packages', 'driver-darwin', 'package.json')
const macOnly = onMac ? false : 'the helper is macOS only'

/** Runs `body` with `process.platform` reading as `platform`. */
function asPlatform(platform, body) {
  const real = Object.getOwnPropertyDescriptor(process, 'platform')
  Object.defineProperty(process, 'platform', { value: platform })
  try {
    return body()
  } finally {
    Object.defineProperty(process, 'platform', real)
  }
}

/** Runs `body` with VOS_DRIVER_PATH set to `value`, then puts it back. */
function withOverride(value, body) {
  const before = process.env.VOS_DRIVER_PATH
  process.env.VOS_DRIVER_PATH = value
  try {
    return body()
  } finally {
    if (before === undefined) delete process.env.VOS_DRIVER_PATH
    else process.env.VOS_DRIVER_PATH = before
  }
}

const codeOf = (body) => {
  try {
    body()
  } catch (error) {
    assert.ok(error instanceof DriverError, `expected a DriverError, got ${error}`)
    return error.code
  }
  return undefined
}

describe('one version', () => {
  it('the wrapper, the platform package and the Swift source say the same', () => {
    const swift = readFileSync(join(root, 'Sources', 'vos-driver', 'Version.swift'), 'utf8')
    assert.equal(platformPkg.version, pkg.version)
    assert.equal(swift.match(/DRIVER_VERSION = "([^"]+)"/)?.[1], pkg.version)
  })

  it('the wrapper pins the platform package through the workspace, exactly', () => {
    // `workspace:*` is rewritten to the exact version when packed (scripts/pack.mjs).
    assert.equal(pkg.optionalDependencies['@vosjs/driver-darwin'], 'workspace:*')
  })

  it('the built helper says it too', { skip: macOnly }, () => {
    const said = JSON.parse(execFileSync(driverPath(), ['version'], { encoding: 'utf8' }))
    assert.deepEqual(said, { event: 'version', version: pkg.version, protocol: PROTOCOL_VERSION })
  })
})

describe('driverPath', () => {
  it('finds the helper in the platform package', { skip: macOnly }, () => {
    const path = driverPath()
    assert.match(path, /driver-darwin\/bin\/vos-driver$/)
  })

  it('says a platform it does not run on', () => {
    assert.equal(
      asPlatform('linux', () => codeOf(() => driverPath())),
      'unsupported-platform',
    )
    assert.equal(
      asPlatform('win32', () => codeOf(() => driverPath())),
      'unsupported-platform',
    )
  })

  it('takes VOS_DRIVER_PATH over the installed helper', { skip: macOnly }, () => {
    const real = driverPath()
    assert.equal(
      withOverride(real, () => driverPath()),
      real,
    )
  })

  it('refuses a VOS_DRIVER_PATH that names nothing', { skip: macOnly }, () => {
    const code = withOverride('/nonexistent/vos-driver', () => codeOf(() => driverPath()))
    assert.equal(code, 'not-installed')
  })

  it('refuses a helper that cannot be run', { skip: macOnly }, () => {
    const { dir, remove } = scratch()
    try {
      const notExecutable = join(dir, 'package.json')
      execFileSync('cp', [join(here, '..', 'package.json'), notExecutable])
      execFileSync('chmod', ['644', notExecutable])
      assert.equal(
        withOverride(notExecutable, () => codeOf(() => driverPath())),
        'not-executable',
      )
    } finally {
      remove()
    }
  })
})

describe('the helper', { skip: macOnly }, () => {
  it('holds both architectures and a signature', () => {
    const path = driverPath()
    const archs = execFileSync('lipo', ['-archs', path], { encoding: 'utf8' }).trim().split(' ')
    assert.deepEqual(archs.sort(), ['arm64', 'x86_64'])
    execFileSync('codesign', ['--verify', '--strict', path])
  })

  it('prints its usage and exits 2 on a verb it does not know', () => {
    const run = spawnSync(driverPath(), ['frobnicate'], { encoding: 'utf8' })
    assert.equal(run.status, 2)
    assert.match(
      run.stderr,
      /^usage: vos-driver version \| check \| windows \| tree '<json>' \| still '<json>' \| record/,
    )
    assert.equal(run.stdout, '')
  })

  it('check() answers with the version, the protocol and two grants', async () => {
    const result = await check()
    assert.equal(result.version, pkg.version)
    assert.equal(result.protocol, PROTOCOL_VERSION)
    assert.equal(typeof result.screenRecording, 'boolean')
    assert.equal(typeof result.accessibility, 'boolean')
    assert.equal(typeof result.os, 'string')
    assert.deepEqual(Object.keys(result).sort(), [
      'accessibility',
      'bundleId',
      'os',
      'path',
      'protocol',
      'screenRecording',
      'version',
    ])
  })
})

// A request is judged before the screen is touched, so these hold with no grant.
describe('a request the helper refuses', { skip: macOnly }, () => {
  const refused = async (request) => {
    const take = record({ out: '/tmp/vos-driver-never-written', ...request })
    const [ready, done] = await Promise.allSettled([take.ready, take.done])
    assert.equal(ready.status, 'rejected')
    assert.equal(done.status, 'rejected')
    assert.ok(done.reason instanceof DriverError)
    assert.equal(ready.reason, done.reason)
    return done.reason
  }

  it('no target', async () => {
    const error = await refused({})
    assert.equal(error.code, 'bad-request')
    assert.match(error.message, /names no target/)
  })

  it('an unknown filter', async () => {
    const error = await refused({ app: 'Finder', filter: 'everything' })
    assert.equal(error.code, 'bad-request')
    assert.match(error.message, /Unknown filter "everything"/)
  })

  it('a frame rate outside 1 to 120', async () => {
    assert.equal((await refused({ app: 'Finder', fps: 0 })).code, 'bad-request')
    assert.equal((await refused({ app: 'Finder', fps: 240 })).code, 'bad-request')
  })

  it('a ceiling of no time', async () => {
    assert.equal((await refused({ app: 'Finder', maxSeconds: 0 })).code, 'bad-request')
  })

  it('stop() on a refused take rejects as done does, and does not throw', async () => {
    const take = record({ out: '/tmp/vos-driver-never-written' })
    await assert.rejects(take.stop(), (error) => error.code === 'bad-request')
  })
})
