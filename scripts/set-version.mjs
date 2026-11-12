// Sets the one version in its three places: both packages and the Swift source.
//
//   node scripts/set-version.mjs 0.1.1
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const version = process.argv[2]

if (!/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(version ?? '')) {
  console.error('usage: node scripts/set-version.mjs <version>, for example 0.1.1')
  process.exit(2)
}

for (const name of ['driver', 'driver-darwin']) {
  const file = join(root, 'packages', name, 'package.json')
  const pkg = JSON.parse(readFileSync(file, 'utf8'))
  pkg.version = version
  writeFileSync(file, JSON.stringify(pkg, null, 2) + '\n')
}

const swiftFile = join(root, 'Sources', 'vos-driver', 'Version.swift')
const swift = readFileSync(swiftFile, 'utf8')
const next = swift.replace(/DRIVER_VERSION = "[^"]+"/, `DRIVER_VERSION = "${version}"`)
if (next === swift && !swift.includes(`"${version}"`)) {
  console.error(`${swiftFile} has no DRIVER_VERSION to set.`)
  process.exit(1)
}
writeFileSync(swiftFile, next)

console.log(`Version ${version}. Rebuild (\`pnpm build\`), merge to main, then tag it: v${version}`)
