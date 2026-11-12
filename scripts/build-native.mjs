// Builds the helper as one universal binary (arm64 + x86_64, macOS 14 and later) into the
// platform package: packages/driver-darwin/bin/vos-driver.
//
// It needs swiftc (Xcode or the Command Line Tools). On any other host it says so and
// leaves, so the JavaScript still builds.
import { execFileSync } from 'node:child_process'
import { mkdirSync, readdirSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const MACOS_FLOOR = '14.0'
const ARCHS = ['arm64', 'x86_64']
const SIGNING_ID = 'so.vos.driver'

if (process.platform !== 'darwin') {
  console.log('The helper builds on macOS only: skipped.')
  process.exit(0)
}

const run = (cmd, args) =>
  execFileSync(cmd, args, { stdio: ['ignore', 'pipe', 'inherit'], encoding: 'utf8' })

const sourceDir = join(root, 'Sources', 'vos-driver')
const sources = readdirSync(sourceDir)
  .filter((f) => f.endsWith('.swift'))
  .sort()
  .map((f) => join(sourceDir, f))

const buildDir = join(root, 'build')
const out = join(root, 'packages', 'driver-darwin', 'bin', 'vos-driver')
mkdirSync(dirname(out), { recursive: true })
rmSync(out, { force: true })

const slices = ARCHS.map((arch) => {
  const slice = join(buildDir, arch, 'vos-driver')
  mkdirSync(dirname(slice), { recursive: true })
  run('swiftc', [
    '-O',
    '-swift-version',
    '5',
    '-parse-as-library',
    '-target',
    `${arch}-apple-macos${MACOS_FLOOR}`,
    ...sources,
    '-o',
    slice,
  ])
  return slice
})

run('lipo', ['-create', '-output', out, ...slices])
// An ad-hoc signature: Apple silicon refuses to run a binary with none. A Developer ID
// signature and notarisation replace this in the release build.
run('codesign', ['--force', '--sign', '-', '--identifier', SIGNING_ID, out])
run('codesign', ['--verify', '--strict', out])

const archs = run('lipo', ['-archs', out]).trim()
for (const arch of ARCHS) {
  if (!archs.split(' ').includes(arch)) {
    console.error(`The built binary lacks ${arch}: it holds ${archs}.`)
    process.exit(1)
  }
}
const version = JSON.parse(run(out, ['version'])).version
console.log(`vos-driver ${version} (${archs}), macOS ${MACOS_FLOOR} and later: ${out}`)
