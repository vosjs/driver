// Packs both packages into build/pack, exactly as they would be published, and lists
// what each tarball holds. `pnpm pack` rewrites `workspace:*` to the exact version, so
// the wrapper pins the helper it was built with.
import { execFileSync } from 'node:child_process'
import { mkdirSync, readdirSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const dest = join(root, 'build', 'pack')
rmSync(dest, { recursive: true, force: true })
mkdirSync(dest, { recursive: true })

for (const name of ['driver-darwin', 'driver']) {
  execFileSync('pnpm', ['pack', '--pack-destination', dest], {
    cwd: join(root, 'packages', name),
    stdio: ['ignore', 'inherit', 'inherit'],
  })
}

for (const tarball of readdirSync(dest).sort()) {
  const files = execFileSync('tar', ['-tzvf', join(dest, tarball)], { encoding: 'utf8' })
  console.log(`\n${tarball}`)
  for (const line of files.trim().split('\n')) {
    const parts = line.trim().split(/\s+/)
    console.log(`  ${parts[0]}  ${parts[4].padStart(8)}  ${parts.at(-1)}`)
  }
}
