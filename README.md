# vos-capture

A headless capture helper for [vos](https://github.com/vosjs/vos) takes of desktop apps. One process per take, no window, no settings, no state.

It records one application's window with the system pointer left out of the pixels, and writes the pointer's path beside the video, so an editor can draw the pointer, zoom to what was pressed and speed through what was not.

Status: a spike. macOS 14 or later; built and run so far on Apple silicon, macOS 26 only. Not signed or notarised yet, so it runs under the permissions of whatever launched it.

## Build

```bash
swiftc -O -swift-version 5 -parse-as-library Sources/vos-capture/main.swift -o build/vos-capture
```

## Use

```bash
vos-capture check                       # permissions, as JSON
vos-capture windows                     # windows that can be captured, one JSON object per line
vos-capture record '{"app":"TextEdit","out":"./take"}'
```

`record` prints `ready`, then `stopped`, as JSON lines on stdout. It ends on `stop` and a newline on stdin, on Ctrl-C, or at `maxSeconds`. The `out` directory then holds:

- `recording.mp4`: H.264, the window at its pixel size, true frame times
- `cursor.json`: `move`, `down`, `up` and `key` events, in milliseconds from the first frame, in the window's own points
- `meta.json`: sizes, scale, duration, the app's name

Request fields: `app` or `window` (an id from `windows`), `out`, `filter` (default `others-out`), `fps` (60), `bitrate` (8000000), `maxSeconds` (1800), `pointer` (true), `frames` (false; element frames at a press, needs Accessibility), `surface` (`app`).

## What it will not do

- Put the system pointer in the picture.
- Learn what was typed. Typing is the system's count of key presses going up; no key ever reaches this process.
- Capture a whole display. The filter is the display with every other application excluded, cropped to the window.
- Sample on a timer. A parked pointer writes nothing.

## Permissions

Screen Recording, always. Accessibility, only for element frames. Never Input Monitoring.

## License

MIT
