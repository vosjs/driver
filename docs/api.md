# vos driver reference

Everything `@vosjs/driver` does, in detail. The [README](../README.md) is the short version.

- [Use it from JavaScript](#use-it-from-javascript)
- [Script a take](#script-a-take)
- [Use it from a shell](#use-it-from-a-shell)
- [The take](#the-take)
- [Permissions](#permissions)
- [What it never does](#what-it-never-does)
- [Errors](#errors)
- [The filter](#the-filter)

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

| Export                      | What it does                                                                                                                                                                                 |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `check()`                   | The helper's version, and whether Screen Recording and Accessibility are granted. Read by a fresh helper process every call.                                                                 |
| `windows()`                 | The windows on screen that can be recorded: `id`, `app`, `appId`, `pid`, `titled`, `frame`.                                                                                                  |
| `record(request, options?)` | Starts a take and returns at once: `ready`, `done`, `stop()`, `send(command)`, `pid`.                                                                                                        |
| `tree(request)`             | The outline of an app's window: each element a script can name, with a selector for it, plus what the app is made of (`kind`) and whether its tree was there (`built`). Needs Accessibility. |
| `still(request)`            | One PNG of the window as a take would show it: no pointer, nothing of any other app.                                                                                                         |
| `driverPath()`              | Where the helper is on this machine.                                                                                                                                                         |
| `DriverError`               | Every failure: read `code`, show `message`.                                                                                                                                                  |
| `PROTOCOL_VERSION`          | The wire protocol this package speaks.                                                                                                                                                       |

### `record(request)`

| Field        | Default        |                                                                                                                  |
| ------------ | -------------- | ---------------------------------------------------------------------------------------------------------------- |
| `window`     |                | A window id from `windows()`. Wins over `pid` and `app`.                                                         |
| `pid`        |                | A process id: its largest titled window. Two instances of one app share a name and differ here. Wins over `app`. |
| `app`        |                | An application's name or bundle id. Its largest titled window is recorded.                                       |
| `out`        | required       | A directory. The take's three files are written there.                                                           |
| `fps`        | `60`           | The frame-rate ceiling, 1 to 120. Frames are written only when pixels change.                                    |
| `bitrate`    | `8000000`      | The encoder's average bit rate.                                                                                  |
| `maxSeconds` | `3600`         | A safety ceiling. Pass your own.                                                                                 |
| `pointer`    | `true`         | Sample the real pointer into `cursor.json`.                                                                      |
| `frames`     | `false`        | Read the bounds of what was pressed and typed in. Needs Accessibility.                                           |
| `filter`     | `'others-out'` | How the window is scoped. Leave it alone; see [the filter](#the-filter).                                         |
| `drive`      | `false`        | A scripted take: bring the app to the front, then take commands. Needs Accessibility.                            |
| `size`       |                | `{ w, h }` in points: give the window this size before the capture. Needs Accessibility.                         |
| `mask`       |                | What the take keeps out of its pixels: `{ selector }` or `{ x, y, w, h }`. See [masks](#masks).                  |

A window that would not fit on its screen at the size asked for is moved first, up and left by what would hang over: the system clips a window to its screen, and the take would come out smaller than it was asked to be.

### A stage

A stage is one display with only what the request names in its pixels: every window of the named apps, where it is and in its real order.

```ts
record({
  apps: ['Linear', 'com.apple.Terminal'], // names or bundle ids
  out: 'take',
})
```

| Field     | Default |                                                                                                 |
| --------- | ------- | ----------------------------------------------------------------------------------------------- |
| `apps`    |         | The apps on the stage, each by name or bundle id. Every running instance of a name is on it.    |
| `pids`    |         | The processes on the stage. A process id tells two instances of one app apart.                  |
| `stage`   | `false` | With `app` or `pid`: a stage of that one app's every window, not a take of its largest.         |
| `desk`    | `[]`    | Parts of the desk to keep: `'menubar'`, `'dock'`, `'wallpaper'`.                                |
| `display` |         | A display id. Default the display that holds most of the named apps' windows.                   |
| `ground`  |         | `#rrggbb`, painted where the stage holds nothing. Default a neutral of the system's appearance. |

`out`, `fps`, `bitrate`, `maxSeconds`, `pointer` and `frames` mean what they do for a window.

- **Nothing that was not named is encoded.** Not another app, not the wallpaper, not desktop icons, not the Dock, not the menu bar. A window of another app that opens over the stage mid-take is in no frame: frames it could be in are held back until it is excluded, as for a window.
- **A named window covered on screen is recorded whole.** Whoever is at the machine can work in another app in front of the stage; the take does not show it.
- **A panel another process draws for a named app is not that app's.** An Open or Save panel, a system prompt and a password sheet belong to their own processes and stay out.
- **The frame is the display**, less the menu bar's strip when the bar is not kept, encoded at its pixel size up to 3840 wide. The pointer's track is in that frame's points.
- **The pointer counts only on the stage.** While it is over a window of an app the take did not name, the track is silent. A press that began on the stage ends in the track wherever it is let go. The ground between the stage's windows is the stage's.
- **Typing is counted only while a named app has the keyboard.**
- **The desk's parts are found by their window level**, the system's own constants, never by who owns them or what they are called: both have changed between macOS versions.
- **`meta.json`** says `captureSurface: "desktop"`, `apps` (name and bundle id of each), `desk`, and `windows`: `{ t, windows: [{ id, app, x, y, w, h }] }`, front to back, at the first frame and every time that changed. A window is never named by its title.

A stage is performed. `drive`, `mask`, `size`, `window` and `filter` are refused with it, in words.

A live capture of a display makes the system show its own sharing indicator in the menu bar. A stage that keeps the bar (`desk: ['menubar']`) has it in its pixels.

### Masks

```ts
record({
  pid,
  out: 'take',
  mask: [
    { selector: "popup[name*='Account']" }, // an element: every match of the selector
    { x: 0, y: 760, w: 280, h: 40 }, // a rectangle of the window, in points
  ],
})
```

Each frame is covered where a mask is BEFORE it is encoded, so what was under a mask is in no file: not `recording.mp4`, not anything made from it. A cover is one flat colour, taken from the edge of what it covers, so it reads as an empty part of the interface and carries nothing of what was there.

`ready.masks` says how many elements each mask covers as the take begins (a 0 also arrives as a `mask-unmatched` notice), and `stopped.masks` and `meta.json` say the most each covered at once. A selector needs Accessibility; a rectangle does not.

**What a mask cannot promise.** An element is found by reading the app's accessibility tree, and its bounds are read again about thirty times a second. Something that appears or moves mid-take is covered from the next reading, so a frame or two can show it first. A place stays covered for a quarter of a second after its element leaves it. What must never show is on screen before the take begins, or is given as a rectangle.

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

**A window that is not on screen yet is waited for**, four seconds: an app launched a moment ago has a process before it has a window.

**Electron and other Chromium apps build their tree only when asked, and not at once.** `tree` asks, waits up to ten seconds, and answers with `kind` (`native`, `electron`, `chromium`) and `built`. When `built` is false the outline is a few empty groups: ask again in a moment, or launch the app with `--force-renderer-accessibility`, which builds it from the start. Asking switches accessibility on inside that app until it quits.

A **selector** is a short path of steps. Each step is a role, then what the element is called or its accessibility identifier:

| Selector                         | Names                                                      |
| -------------------------------- | ---------------------------------------------------------- |
| `button[name='Save']`            | A button the interface calls Save.                         |
| `textfield[id='issue-title']`    | The field whose accessibility identifier is `issue-title`. |
| `button[name*='Share']`          | `*=` is contains, without regard to case.                  |
| `toolbar > button[name='Share']` | `>` is a child; a space is any descendant.                 |
| `button[name='Delete']:nth(1)`   | The second match, counted from 0.                          |
| `*[id='sidebar']`                | Any role.                                                  |

`selectorProblem(text)` says why a selector is not one, in the helper's own words, or `null`. It runs without the helper, so a script's selectors can be checked when the script is read and not at the step that uses one.

A role is the accessibility role in lower case without its `AX` (`button`, `checkbox`, `textfield`, `textarea`, `link`, `menuitem`, `row`, `cell`), with `text` for static text, `radio` for a radio button and `popup` for a pop-up button. `tree` proposes one selector per element, the identifier first because it is the one that survives a redesign, and says whether it names that element alone. It leaves out the window's own close, minimise and zoom buttons: pressing one ends the take.

| Command                                                  | What it does                                                                                                                                                                                            |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `{ do: 'locate', selector }`                             | Finds without acting: `count`, and the first match's `rect`, `name` and `enabled`.                                                                                                                      |
| `{ do: 'click', selector, count?, button?, modifiers? }` | The pointer travels to the element and presses it. A disabled one is reached, not pressed: `pressed: false`.                                                                                            |
| `{ do: 'hover', selector }`                              | The pointer travels there and stays.                                                                                                                                                                    |
| `{ do: 'type', text, selector?, delayMs? }`              | Presses the target if one is given, then types a character at a time. A new line in `text` is the Return key and a tab is the Tab key.                                                                  |
| `{ do: 'press', keys }`                                  | A chord (`Meta+S`, `Enter`, `Shift+Tab`) or a list of them.                                                                                                                                             |
| `{ do: 'scroll', dy?, dx?, selector?, ms? }`             | Turns the wheel, in points, over the target or where the pointer is.                                                                                                                                    |
| `{ do: 'drag', selector, to, ms?, modifiers? }`          | Presses on the target, travels to `to` and lets go.                                                                                                                                                     |
| `{ do: 'move', x, y, ms? }`                              | Moves the pointer and does nothing else.                                                                                                                                                                |
| `{ do: 'now' }`                                          | Nothing: its `tEnd` is the take's clock.                                                                                                                                                                |
| `{ do: 'focused' }`                                      | Nothing: says what a key would go to (`focused`: its role and bounds, and its name when it is not something typed into) and whether the app has the keyboard (`frontmost`). Ask it before typing blind. |

A target is a `selector`, or `x` and `y` in the window's own points. Commands run one at a time in the order sent, and each answer carries `tStart` and `tEnd` in milliseconds on the take's clock, which is where the act is in the footage. A command that did nothing resolves with `ok: false`, a `code` (`not-found`, `not-in-view`, `not-frontmost`, `bad-request`, `no-tree`) and a `message`; the take goes on and the script decides.

Input is posted where a mouse's and a keyboard's enter the system, so the app sees ordinary input and the pointer's path is sampled exactly as a person's is. Before every key, the helper asks the system which app has the keyboard: if another app took it, typing stops there with `not-frontmost`, so a script's text never lands in another app. Each press in `cursor.json` carries the bounds of the element the script named.

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
  "appearance": "light",
  "zoom": 1,
  "fps": 60,
  "t0": 1794475400000,
  "durationMs": 6692
}
```

`appearance` is the system's as the take began (`light` or `dark`), which apps follow: takes made under both do not cut into one film that matches itself.

**A take keeps the display awake.** From its first frame to its last the helper holds the assertion `caffeinate -d` takes, so a take that waits (a build, a render, an agent working) does not let the display sleep and the screen lock under it. `ready.awake` says it is held. Behind a locked screen nothing can be brought forward: a request that drives the app fails with `screen-locked` and says so.

This is the take the vos CLI reads, from `@vosjs/cli` 0.87.1: `npx vos plan take` writes its `doc.json` with the zooms planned from the track.

## Permissions

| Grant            | Needed for                                                                                                                       |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Screen Recording | Everything but `check` and `version`.                                                                                            |
| Accessibility    | `tree`, a scripted take (`drive`, `size`, every command), a `mask` by selector, and `frames: true`. A performed take needs none. |

Never Input Monitoring: the helper posts input, it does not listen to it.

macOS grants these to the app that launched the helper. If `check()` says `screenRecording: false`, switch it on for that app in System Settings, Privacy & Security, Screen & System Audio Recording, then start it again.

## What it never does

- **Put the system pointer in the picture.**
- **Learn what was typed.** Typing is the system's count of key presses going up. No key a person presses ever reaches the helper, and there is no keyboard listener in it to receive one. The text a script types is the script's own: it is posted to the app and written nowhere.
- **Read what is in a field.** The value of anything a person types into (a text field, a text area, a search field, a password field) is never read, by any verb. A field is called by its placeholder or its label.
- **Read the interface unless asked.** `tree` and a command's selector read what the interface calls its elements: titles, descriptions, and the words of labels and other static text, which in some apps is content (a message in a list, a file's name). That goes to whoever called the helper and nowhere else. A performed take reads none of it; with `frames: true` it reads where things are, never what they say.
- **Record what was not named.** A take of a window excludes every window that is not the app's, and is cropped to the window and follows it when it moves. A stage excludes every window that is not a named app's, and the desk with them. Neither can record a display as it is. A window that opens over it mid-take (a notification, an app you launch) is excluded as soon as it appears, and the frames it could be in are held back, so it is not in the file for even one.
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
| `screen-locked`        | The screen is locked, and the request drives the app. Unlock it.          |
| `no-frames`            | The take ended before the window drew a frame.                            |
| `write-failed`         | The recording or its files could not be written.                          |
| `crashed`              | The helper ended without saying why.                                      |

## The filter

The capture is the display with every window that is not the app's excluded, cropped to the window (`others-out`). Scope is by exclusion and not by naming the window: on macOS 26, a filter that names the window or its app makes the system draw its sharing control over the window's traffic lights, and that control lands in the recording. The other values (`window`, `app`, `display-window`, `display`) exist to measure other macOS versions.

Outside the window's rounded corners the recording is opaque black. `ready` and `meta.json` say how round they are (`cornerRadius`, in points), so an editor that frames the window can round its frame at least as much.
