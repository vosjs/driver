// The wrapper package's prepack gate: it never goes out unbuilt, and it never goes out
// at a version its helper does not share.
// It also brings the repository's README into the package for the tarball.
import { copyFileSync, existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (...parts) => readFileSync(join(root, ...parts), 'utf8')
const pkg = JSON.parse(read('packages', 'driver', 'package.json'))
const platform = JSON.parse(read('packages', 'driver-darwin', 'package.json'))

const stop = (why) => {
  console.error(`${pkg.name} cannot be packed: ${why}`)
  process.exit(1)
}

for (const file of ['index.js', 'index.d.ts']) {
  if (!existsSync(join(root, 'packages', 'driver', 'dist', file))) {
    stop(`dist/${file} is missing. Run \`pnpm build\` first.`)
  }
}
if (platform.version !== pkg.version) {
  stop(`it is ${pkg.version} and ${platform.name} is ${platform.version}. They release together.`)
}
const swift = read('Sources', 'vos-driver', 'Version.swift').match(
  /DRIVER_VERSION = "([^"]+)"/,
)?.[1]
if (swift !== pkg.version) {
  stop(`it is ${pkg.version} and Sources/vos-driver/Version.swift says ${swift}.`)
}

// The repository's README is the package's: copied in for the tarball, removed by postpack.
copyFileSync(join(root, 'README.md'), join(root, 'packages', 'driver', 'README.md'))

console.log(`${pkg.name}@${pkg.version}: built, and one version with its helper.`)
