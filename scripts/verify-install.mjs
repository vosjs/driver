// Installs the packed tarballs (build/pack, from scripts/pack.mjs) into a fresh project
// with npm and again with pnpm, and checks what a person would get: the wrapper finds
// the helper, the helper runs, it is still signed and executable, and it says the
// version that was packed.
import { execFileSync } from 'node:child_process'
import {
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const packDir = join(root, 'build', 'pack')
const version = JSON.parse(
  readFileSync(join(root, 'packages', 'driver', 'package.json'), 'utf8'),
).version

if (process.platform !== 'darwin') {
  console.log('The helper installs on macOS only: skipped.')
  process.exit(0)
}

const tarballs = readdirSync(packDir)
const wrapper = join(
  packDir,
  tarballs.find((f) => f === `vosjs-driver-${version}.tgz`) ?? fail('no wrapper tarball'),
)
const platform = join(
  packDir,
  tarballs.find((f) => f === `vosjs-driver-darwin-${version}.tgz`) ?? fail('no platform tarball'),
)

function fail(why) {
  console.error(`verify-install: ${why}`)
  process.exit(1)
}

const run = (cmd, args, cwd) =>
  execFileSync(cmd, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()

// What the packed wrapper asks for: the exact version of the helper it was built with.
const packed = JSON.parse(run('tar', ['-xzOf', wrapper, 'package/package.json']))
const pin = packed.optionalDependencies?.['@vosjs/driver-darwin']
if (pin !== version)
  fail(`the packed wrapper pins @vosjs/driver-darwin at "${pin}", not ${version}`)

// The helper must leave as an executable: a packer that drops the bit ships a file nobody can run.
const mode = run('tar', ['-tzvf', platform])
  .split('\n')
  .find((line) => line.endsWith('package/bin/vos-driver'))
if (!mode?.startsWith('-rwx'))
  fail(`the helper is packed as "${mode?.split(/\s+/)[0]}", not executable`)

const PROBE = `
import { PROTOCOL_VERSION, check, driverPath } from '@vosjs/driver'
const result = await check()
console.log(JSON.stringify({ path: driverPath(), version: result.version, protocol: result.protocol, speaks: PROTOCOL_VERSION }))
`

/** Each manager installs the wrapper by its tarball and finds the helper as its optional dependency. */
const MANAGERS = {
  npm: {
    // Before the packages are on the registry, the helper's tarball is named beside the
    // wrapper's; the wrapper's own pin is then met by it.
    manifest: {
      dependencies: {
        '@vosjs/driver': `file:${wrapper}`,
        '@vosjs/driver-darwin': `file:${platform}`,
      },
    },
    install: ['install', '--no-audit', '--no-fund', '--loglevel=error'],
  },
  pnpm: {
    // The helper arrives only as the wrapper's optional dependency, as it will from the registry.
    manifest: {
      dependencies: { '@vosjs/driver': `file:${wrapper}` },
      pnpm: { overrides: { '@vosjs/driver-darwin': `file:${platform}` } },
    },
    install: ['install', '--reporter=silent'],
  },
}

let failed = false
for (const [manager, { manifest, install }] of Object.entries(MANAGERS)) {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), `vos-driver-install-${manager}-`)))
  try {
    writeFileSync(
      join(dir, 'package.json'),
      JSON.stringify(
        { name: 'verify-install', private: true, type: 'module', ...manifest },
        null,
        2,
      ),
    )
    writeFileSync(join(dir, 'probe.mjs'), PROBE)
    run(manager, install, dir)

    const probe = JSON.parse(run('node', ['probe.mjs'], dir))
    const path = realpathSync(probe.path)
    const checks = {
      'installed under the project': path.startsWith(dir),
      'says the packed version': probe.version === version,
      'speaks the wrapper protocol': probe.protocol === probe.speaks,
      executable: (statSync(path).mode & 0o111) !== 0,
      'both architectures':
        run('lipo', ['-archs', path]).split(' ').sort().join(' ') === 'arm64 x86_64',
      signed: (() => {
        try {
          run('codesign', ['--verify', '--strict', path])
          return true
        } catch {
          return false
        }
      })(),
      'no quarantine attribute': !run('xattr', [path]).includes('com.apple.quarantine'),
      'the bin runs':
        JSON.parse(run(join(dir, 'node_modules', '.bin', 'vos-driver'), ['version'], dir))
          .version === version,
    }
    console.log(`\n${manager}: ${path.slice(dir.length + 1)}`)
    for (const [name, ok] of Object.entries(checks)) {
      console.log(`  ${ok ? 'ok  ' : 'FAIL'}  ${name}`)
      if (!ok) failed = true
    }
  } catch (error) {
    failed = true
    console.error(`\n${manager}: ${error.stderr?.toString().trim() || error.message}`)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

process.exit(failed ? 1 : 0)
