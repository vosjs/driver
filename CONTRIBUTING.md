# Contributing to vos driver

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
