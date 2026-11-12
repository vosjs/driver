# vos-driver

Records a desktop app's window for a [vos](https://github.com/vosjs/vos) take.

It writes a video of one window with the system pointer left out of the pixels, and the pointer's path beside it, so an editor can draw the pointer itself, zoom to what was pressed and speed through what was not. The take is performed by a person, or scripted: the helper finds the app's controls through accessibility and presses, types and scrolls as a hand would. The work is done by a small native helper with no window of its own, no settings and no state: one process per take.

```bash
npm i @vosjs/driver
```

macOS 14 or later, Node 18 or later. `@vosjs/driver` is the typed API; it brings `@vosjs/driver-darwin`, one universal binary (Apple silicon and Intel), as an optional dependency.

## Status

Early. What that means today:

- **The helper is not signed with a Developer ID or notarised.** It carries an ad-hoc signature, which is enough to run. macOS therefore records its permissions against the app that launched it (your terminal, your editor, your agent's host), not against the helper.
- The Intel half of the binary records real takes in CI, on a hosted Intel runner. It has not been run on a physical Intel Mac.
- No audio, no webcam, no whole-display capture.
- **A scripted take uses the machine's own pointer and keyboard.** The app comes to the front and the real pointer moves, so nobody else can use the machine while it runs. There is no background mode.

## Use it from JavaScript

```js
import { check, record } from '@vosjs/driver'

const { screenRecording } = await check()
if (!screenRecording) throw new Error('Switch on Screen Recording for the app running this.')

const take = record({ app: 'TextEdit', out: './take', frames: true })
await take.ready // the first frame is in the file: the take has its time zero

// ... use the app ...

const stopped = await take.stop()
console.log(stopped.durationMs, stopped.files.recording)
```

| Export                      | What it does                                                                                                                 |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `check()`                   | The helper's version, and whether Screen Recording and Accessibility are granted. Read by a fresh helper process every call. |
| `windows()`                 | The windows on screen that can be recorded: `id`, `app`, `appId`, `titled`, `frame`.                                         |
| `record(request, options?)` | Starts a take and returns at once: `ready`, `done`, `stop()`, `send(command)`, `pid`.                                        |
| `tree(request)`             | The outline of an app's window: each element a script can name, with a selector for it. Needs Accessibility.                 |
| `still(request)`            | One PNG of the window as a take would show it: no pointer, nothing of any other app.                                         |
| `driverPath()`              | Where the helper is on this machine.                                                                                         |
| `DriverError`               | Every failure: read `code`, show `message`.                                                                                  |
| `PROTOCOL_VERSION`          | The wire protocol this package speaks.                                                                                       |

### `record(request)`

| Field        | Default        |                                                                                          |
| ------------ | -------------- | ---------------------------------------------------------------------------------------- |
| `window`     |                | A window id from `windows()`. Wins over `app`.                                           |
| `app`        |                | An application's name or bundle id. Its largest titled window is recorded.               |
| `out`        | required       | A directory. The take's three files are written there.                                   |
| `fps`        | `60`           | The frame-rate ceiling, 1 to 120. Frames are written only when pixels change.            |
| `bitrate`    | `8000000`      | The encoder's average bit rate.                                                          |
| `maxSeconds` | `3600`         | A safety ceiling. Pass your own.                                                         |
| `pointer`    | `true`         | Sample the real pointer into `cursor.json`.                                              |
| `frames`     | `false`        | Read the bounds of what was pressed and typed in. Needs Accessibility.                   |
| `filter`     | `'others-out'` | How the window is scoped. Leave it alone; see [the filter](#the-filter).                 |
| `drive`      | `false`        | A scripted take: bring the app to the front, then take commands. Needs Accessibility.    |
| `size`       |                | `{ w, h }` in points: give the window this size before the capture. Needs Accessibility. |

`options.onEvent` receives every line the helper prints. `options.signal` ends the take as `stop()` does.

A take ends when you call `stop()`, at `maxSeconds`, when the window's capture stops, and when the process that started it goes away. A recorder never outlives what started it.

## Script a take

Look at the window first, then act on it while it is recorded.

```js
import { record, tree } from '@vosjs/driver'

const { elements } = await tree({ app: 'TextEdit' })
// [{ role: 'button', name: 'Save', selector: "button[name='Save']", unique: true, rect, enabled }, ...]

const take = record({ app: 'TextEdit', out: './take', drive: true })
await take.ready

await take.send({ do: 'type', selector: 'textarea', text: 'Hello from a script.' })
await take.send({ do: 'press', keys: 'Meta+S' })
const click = await take.send({ do: 'click', selector: "button[name='Save']" })
// { ok: true, pressed: true, tStart, tEnd, rect }: its extent on the take's clock, and where

await take.stop()
```

A **selector** is a short path of steps. Each step is a role, then what the element is called or its accessibility identifier:

| Selector                         | Names                                                      |
| -------------------------------- | ---------------------------------------------------------- |
| `button[name='Save']`            | A button the interface calls Save.                         |
| `textfield[id='issue-title']`    | The field whose accessibility identifier is `issue-title`. |
| `button[name*='Share']`          | `*=` is contains, without regard to case.                  |
| `toolbar > button[name='Share']` | `>` is a child; a space is any descendant.                 |
| `button[name='Delete']:nth(1)`   | The second match, counted from 0.                          |
| `*[id='sidebar']`                | Any role.                                                  |

A role is the accessibility role in lower case without its `AX` (`button`, `checkbox`, `textfield`, `textarea`, `link`, `menuitem`, `row`, `cell`), with `text` for static text, `radio` for a radio button and `popup` for a pop-up button. `tree` proposes one selector per element, the identifier first because it is the one that survives a redesign, and says whether it names that element alone.

| Command                                                  | What it does                                                                                                 |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `{ do: 'locate', selector }`                             | Finds without acting: `count`, and the first match's `rect`, `name` and `enabled`.                           |
| `{ do: 'click', selector, count?, button?, modifiers? }` | The pointer travels to the element and presses it. A disabled one is reached, not pressed: `pressed: false`. |
| `{ do: 'hover', selector }`                              | The pointer travels there and stays.                                                                         |
| `{ do: 'type', text, selector?, delayMs? }`              | Presses the target if one is given, then types a character at a time.                                        |
| `{ do: 'press', keys }`                                  | A chord (`Meta+S`, `Enter`, `Shift+Tab`) or a list of them.                                                  |
| `{ do: 'scroll', dy?, dx?, selector?, ms? }`             | Turns the wheel, in points, over the target or where the pointer is.                                         |
| `{ do: 'drag', selector, to, ms?, modifiers? }`          | Presses on the target, travels to `to` and lets go.                                                          |
| `{ do: 'move', x, y, ms? }`                              | Moves the pointer and does nothing else.                                                                     |
| `{ do: 'now' }`                                          | Nothing: its `tEnd` is the take's clock.                                                                     |

A target is a `selector`, or `x` and `y` in the window's own points. Commands run one at a time in the order sent, and each answer carries `tStart` and `tEnd` in milliseconds on the take's clock, which is where the act is in the footage. A command that did nothing resolves with `ok: false`, a `code` (`not-found`, `not-in-view`, `not-frontmost`, `bad-request`, `no-tree`) and a `message`; the take goes on and the script decides.

Input is posted where a mouse's and a keyboard's enter the system, so the app sees ordinary input and the pointer's path is sampled exactly as a person's is. Each press in `cursor.json` carries the bounds of the element the script named.

## Use it from a shell

```bash
npx vos-driver check
npx vos-driver windows
npx vos-driver tree '{"app":"TextEdit"}'
npx vos-driver still '{"app":"TextEdit","out":"./look.png"}'
npx vos-driver record '{"app":"TextEdit","out":"./take"}'   # Ctrl-C ends the take
```

The helper prints one JSON object per line. `record` prints `ready`, then `stopped` or `error`, and exits 0 or 1. While it records, a line on its stdin is `stop` or one JSON command, answered with a `result` line.

## The take

```
take/
  recording.mp4   H.264, the window at its pixel size, true frame times, no pointer
  cursor.json     the pointer's path
  meta.json       sizes, scale, duration, the app
```

`cursor.json` is a list of events. Times are milliseconds from the first frame; positions are in the window's own points, origin top-left, and follow the window if it moves.

```json
[
  { "t": 1216.4, "type": "move", "x": 300, "y": 416.3 },
  {
    "t": 2315.9,
    "type": "down",
    "x": 330,
    "y": 78,
    "button": 0,
    "rect": { "x": 16, "y": 60, "w": 320, "h": 28 }
  },
  { "t": 2386.1, "type": "up", "x": 330, "y": 78, "button": 0 },
  { "t": 3012.7, "type": "key", "x": 176, "y": 74 }
]
```

- `move` is written when the pointer moves, never on a timer. A parked pointer writes nothing, and editors read that silence.
- `rect` is the bounds of what was pressed, with `frames: true`.
- `key` says that typing happened and where. It never says what was typed.

`meta.json`:

```json
{
  "captureSurface": "app",
  "producer": "desktop",
  "platform": "mac",
  "app": { "name": "TextEdit", "id": "com.apple.TextEdit" },
  "width": 656,
  "height": 422,
  "captureWidth": 1312,
  "captureHeight": 844,
  "dpr": 2,
  "cornerRadius": 18.2,
  "zoom": 1,
  "fps": 60,
  "t0": 1794475400000,
  "durationMs": 6692
}
```

This is the take the vos CLI reads, from `@vosjs/cli` 0.87.1: `npx vos plan take` writes its `doc.json` with the zooms planned from the track.

## Permissions

| Grant            | Needed for                                                                                                 |
| ---------------- | ---------------------------------------------------------------------------------------------------------- |
| Screen Recording | Everything but `check` and `version`.                                                                      |
| Accessibility    | `tree`, a scripted take (`drive`, `size`, every command), and `frames: true`. A performed take needs none. |

Never Input Monitoring: the helper posts input, it does not listen to it.

macOS grants these to the app that launched the helper. If `check()` says `screenRecording: false`, switch it on for that app in System Settings, Privacy & Security, Screen & System Audio Recording, then start it again.

## What it never does

- **Put the system pointer in the picture.**
- **Learn what was typed.** Typing is the system's count of key presses going up. No key a person presses ever reaches the helper, and there is no keyboard listener in it to receive one. The text a script types is the script's own: it is posted to the app and written nowhere.
- **Read what is in a field.** The value of anything a person types into (a text field, a text area, a search field, a password field) is never read, by any verb. A field is called by its placeholder or its label.
- **Read the interface unless asked.** `tree` and a command's selector read what the interface calls its elements: titles, descriptions, and the words of labels and other static text, which in some apps is content (a message in a list, a file's name). That goes to whoever called the helper and nowhere else. A performed take reads none of it; with `frames: true` it reads where things are, never what they say.
- **Record anything but the one app.** Every window that is not the app's is excluded from the capture, which is cropped to the window and follows it when it moves. A window that opens over it mid-take (a notification, an app you launch) is excluded as soon as it appears, and the frames it could be in are held back, so it is not in the file for even one.
- **Name a window.** `meta.json` holds the app's name and bundle id, never a window title.
- **Send anything anywhere.** The helper has no network code. It writes three files into the directory it was given.
- **Sample on a timer, or keep running** after the process that started it is gone.

## Errors

Every failure is a `DriverError` with a `code`.

| `code`                 | Meaning                                                                   |
| ---------------------- | ------------------------------------------------------------------------- |
| `unsupported-platform` | Not macOS.                                                                |
| `unsupported-os`       | macOS older than 14.                                                      |
| `not-installed`        | The platform package is missing. Install again without `--omit=optional`. |
| `not-executable`       | The helper is there and cannot be run.                                    |
| `protocol-mismatch`    | The helper and this package are different versions.                       |
| `screen-recording`     | Screen Recording is not granted to the app that launched the helper.      |
| `accessibility`        | Accessibility is not granted to the app that launched the helper.         |
| `no-tree`              | The window offers no accessibility tree.                                  |
| `bad-request`          | The request is not what the verb takes.                                   |
| `no-window`            | No window on screen matches the request.                                  |
| `start-failed`         | The capture could not start.                                              |
| `no-frames`            | The take ended before the window drew a frame.                            |
| `write-failed`         | The recording or its files could not be written.                          |
| `crashed`              | The helper ended without saying why.                                      |

## The filter

The capture is the display with every window that is not the app's excluded, cropped to the window (`others-out`). Scope is by exclusion and not by naming the window: on macOS 26, a filter that names the window or its app makes the system draw its sharing control over the window's traffic lights, and that control lands in the recording. The other values (`window`, `app`, `display-window`, `display`) exist to measure other macOS versions.

Outside the window's rounded corners the recording is opaque black. `ready` and `meta.json` say how round they are (`cornerRadius`, in points), so an editor that frames the window can round its frame at least as much.

## Develop

```bash
pnpm install
pnpm build         # the universal helper (needs swiftc), then the wrapper
pnpm test
pnpm pack:verify   # packs both packages and installs them into fresh npm and pnpm projects
```

The recording tests open a small window of their own (`Fixtures/window.swift`) and record that, so nothing of yours is captured. They run where Screen Recording is granted to the app that launched them, and say so when they are skipped. `VOS_DRIVER_PATH` points the wrapper at a helper you built yourself.

Layout:

- `Sources/vos-driver/` the helper, in Swift.
- `packages/driver/` `@vosjs/driver`, the API. `src/protocol.ts` is the contract with the helper.
- `packages/driver-darwin/` `@vosjs/driver-darwin`, which carries the built helper.

The two packages and the helper share one version and release together.

## Release

A release is a tag on `main`. The workflow (`.github/workflows/release.yml`) builds the helper on a Mac, runs the whole gate, and publishes both packages to npm through trusted publishing: there is no npm token anywhere.

```bash
node scripts/set-version.mjs 0.1.1   # both packages and the Swift source
pnpm build && pnpm test
# merge that to main, then, on main:
git tag v0.1.1
git push origin v0.1.1
```

The tag must name the version the tree says and its commit must be on `main`, or the workflow stops before it builds. A release that stopped halfway is finished by running it again: a package already on npm is skipped.

Run by hand from the Actions tab, the same workflow is a rehearsal. It builds, packs and runs both publishes with `--dry-run`, and publishes nothing, from any branch.

## Security

See [SECURITY.md](https://github.com/vosjs/driver/blob/main/SECURITY.md).

## License

MIT
