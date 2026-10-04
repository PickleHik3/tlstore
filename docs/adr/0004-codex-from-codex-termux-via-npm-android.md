---
status: accepted
date: 2026-10-04
---

# Codex comes from codex-termux's Android build, on the device, through an npm-android kind

The `codex` item installs [DioNanos/codex-termux](https://github.com/DioNanos/codex-termux)'s
Android build of OpenAI Codex (Apache-2.0, Davide A. Guglielmi's port of openai/codex), published
on npm as `@mmmbuto/codex-cli-termux`. A new engine kind, `npm-android`, does the work: it is
`npm-musl` minus the musl loader, the musl libraries and `patchelf`, because the package's
executables are Bionic PIE binaries that run as they are. The engine asks the registry for
`latest`, checks npm's sha512, unpacks `bin/codex.bin` and, through `extra=`, its required
neighbour `bin/codex-code-mode-host` (Codex's code mode, on by default, needs it in the same
directory), and writes a `codex` wrapper (`command=`) that passes
`-c check_for_update_on_startup=false` (`args=`), the only way to switch off Codex's own update
check. About 275 MB on disk.

Alternatives rejected:
- **Upstream `@openai/codex`.** A static musl binary that reads a hard-coded `/etc/resolv.conf`,
  absent on Android, so it cannot resolve names, and a static binary cannot use our patched musl
  loader.
- **Mirroring the codex-termux binary as a `bins-` asset.** Works, but costs a rebuild and a
  release for every upstream version, and this repository would be redistributing a 200 MB binary
  that is not ours.
- **TUR's `codex` package.** A third-party repository, stale at 0.122.0 when checked, and built
  for the `com.termux` prefix only.
- **Telling users to run `npm install -g`.** It needs Node, lands in `$PREFIX` where a bootstrap
  repair wipes it, runs a postinstall script, cannot be tracked or updated by tlstore, and the
  store UI has no copy-a-command action.

Nothing here is redistributed: the phone fetches the tarball from the author's npm release.
