// The release workflow's first step: what is being released, and whether it may be.
//
// A release (a pushed tag, EVENT=push) must hold:
//   - the two packages and the Swift source say one version;
//   - the tag is `v<that version>`;
//   - the tagged commit is on main;
//   - that version is not already on npm in full (a release that stopped halfway,
//     with one package out, may be run again to finish).
//
// A rehearsal (EVENT=workflow_dispatch) must be run from main, and publishes nothing.
//
// It writes `version=<version>` to $GITHUB_OUTPUT.
import { execFileSync } from 'node:child_process'
import { appendFileSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const read = (...parts) => readFileSync(join(root, ...parts), 'utf8')

const stop = (why) => {
  console.error(`This cannot be released: ${why}`)
  process.exit(1)
}

const wrapper = JSON.parse(read('packages', 'driver', 'package.json'))
const platform = JSON.parse(read('packages', 'driver-darwin', 'package.json'))
const swift = read('Sources', 'vos-driver', 'Version.swift').match(
  /DRIVER_VERSION = "([^"]+)"/,
)?.[1]
const version = wrapper.version

if (platform.version !== version || swift !== version) {
  stop(
    `the versions disagree: ${wrapper.name} ${version}, ${platform.name} ${platform.version}, Version.swift ${swift}. Set them together with \`node scripts/set-version.mjs <version>\`.`,
  )
}

const event = process.env.EVENT ?? ''
const ref = process.env.REF_NAME ?? ''
const quiet = { stdio: ['ignore', 'pipe', 'ignore'], encoding: 'utf8' }

/** True when `<name>@<version>` is on the registry. */
const published = (name) => {
  try {
    return execFileSync('npm', ['view', `${name}@${version}`, 'version'], quiet).trim() === version
  } catch {
    return false
  }
}

if (event === 'push') {
  if (ref !== `v${version}`) {
    stop(`the tag is ${ref} and the tree says ${version}. The tag for this tree is v${version}.`)
  }
  if (published(wrapper.name) && published(platform.name)) {
    stop(`${version} is already on npm. Set the next version and tag that.`)
  }
  try {
    execFileSync('git', ['merge-base', '--is-ancestor', 'HEAD', 'origin/main'], {
      cwd: root,
      stdio: 'ignore',
    })
  } catch {
    stop(`the commit ${ref} names is not on main. A release is cut from main.`)
  }
  console.log(`Releasing ${version} from ${ref}.`)
} else if (event === 'workflow_dispatch') {
  if (ref !== 'main') stop(`a rehearsal runs from main, and this is ${ref}.`)
  console.log(`Rehearsing the release of ${version}. Nothing is published.`)
} else {
  stop(`it is run by a pushed tag or by hand, and this is "${event}".`)
}

if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `version=${version}\n`)
