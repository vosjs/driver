#!/usr/bin/env node
// Runs the native helper with the arguments it was given: `vos-driver check`,
// `vos-driver windows`, `vos-driver record '<json>'`. Its exit code is the helper's.
import { spawn } from 'node:child_process'
import { DriverError, driverPath } from '../dist/index.js'

let path
try {
  path = driverPath()
} catch (error) {
  console.error(error instanceof DriverError ? error.message : String(error))
  process.exit(1)
}

const child = spawn(path, process.argv.slice(2), { stdio: 'inherit' })

// Ctrl-C reaches the helper too (same process group) and it finishes the take: this
// process must outlive it, so the file is whole before the shell gets its prompt back.
process.on('SIGINT', () => {})
process.on('SIGTERM', () => child.kill('SIGTERM'))

child.on('error', (error) => {
  console.error(`The helper could not be started: ${error.message}`)
  process.exit(1)
})
child.on('exit', (code, signal) => {
  process.exit(code ?? (signal ? 1 : 0))
})
