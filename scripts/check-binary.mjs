// The platform package's prepack gate: it never goes out without its binary, the binary
// holds both architectures, it is signed, and it says the version the package says.
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const pkgDir = join(root, 'packages', 'driver-darwin')
const binary = join(pkgDir, 'bin', 'vos-driver')
const pkg = JSON.parse(readFileSync(join(pkgDir, 'package.json'), 'utf8'))

const stop = (why) => {
  console.error(`${pkg.name} cannot be packed: ${why}`)
  process.exit(1)
}

if (process.platform !== 'darwin') stop('it is built and packed on macOS.')
if (!existsSync(binary)) stop('bin/vos-driver is missing. Run `pnpm build` first.')

const run = (cmd, args) =>
  execFileSync(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' })

const archs = run('lipo', ['-archs', binary]).trim().split(' ')
for (const arch of ['arm64', 'x86_64']) {
  if (!archs.includes(arch)) stop(`the binary lacks ${arch} (it holds ${archs.join(', ')}).`)
}
try {
  run('codesign', ['--verify', '--strict', binary])
} catch {
  stop('the binary is not signed.')
}
const said = JSON.parse(run(binary, ['version'])).version
if (said !== pkg.version) stop(`the binary says ${said}, the package says ${pkg.version}. Rebuild.`)

console.log(`${pkg.name}@${pkg.version}: binary present, ${archs.join(' + ')}, signed.`)
