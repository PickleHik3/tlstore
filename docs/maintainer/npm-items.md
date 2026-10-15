# npm items: how opencode, Claude Code and codex are shipped

opencode, Claude Code and codex are not built in this repository and are not release assets. Each
is an npm package that the engine downloads from the npm registry, **on the phone**, when someone
installs or updates it. The catalog says only which package to take and what it needs. This page
follows opencode from its catalog row to a running `opencode` command, because it uses every part
of the mechanism.

Two kinds of catalog row do this:

| Kind | For | What the engine does after the download |
|---|---|---|
| `npm-musl` | An upstream **Linux** binary built against musl (opencode, Claude Code) | Gives it our musl loader and libraries and patches the binary to use them |
| `npm-android` | A package that already ships an **Android** (Bionic) executable (codex, from `@mmmbuto/codex-cli-termux`) | Nothing. It runs as it is: no loader, no libraries, no patchelf |

Why musl and not Termux's glibc-runner is settled in
[ADR 0003](../adr/0003-npm-musl-items-stay-on-the-musl-loader.md). Don't reopen it without the
trigger that ADR names.

## 1. The catalog row

opencode's row in `scripts/items.tsv`, field by field (only the fields that matter here):

| Field | Value | Meaning |
|---|---|---|
| name | `opencode` | |
| kind | `npm-musl` | |
| version | `latest` | Whatever npm's `latest` dist-tag points at when the phone asks. No pin, so a new opencode release needs no change here |
| editions | `com.termux,io.vaj.tl` | Offered in both launcher editions |
| source | `npm:@opencode/cli-linux-arm64-musl#bin/opencode` | npm package `#` path of the executable inside it |
| requires | `musl-loader,musl-libstdcxx,musl-libgcc,ripgrep,launcher-skill` | Installed first, as parts of opencode |
| options | see below | |

The options:

| Option | Effect |
|---|---|
| `env=OPENCODE_DISABLE_AUTOUPDATE=1` | Exported by the wrapper. opencode's own updater stays off; `tlstore update` is the only way it changes |
| `tz=1` | The wrapper sets `TZ` from Android's `persist.sys.timezone` when it is unset. musl has no idea of Android's time-zone setting, so without this the clock reads UTC |
| `build=patchelf` | Termux's `patchelf` must be present |
| `musl-libs=musl-libstdcxx,musl-libgcc` | Extra musl libraries to copy in beside the loader. opencode links `libstdc++` and `libgcc_s`; Claude Code needs neither and has no `musl-libs` |
| `x86_64:source=npm:@opencode/cli-linux-x64-musl#bin/opencode` | The package to use on an x86_64 device (the emulator) |

The npm-specific forms of the source field and the x86_64 override are covered in
[catalog.md](catalog.md).

## 2. The parts it requires, and where they come from

| Part | What it is | Where it comes from |
|---|---|---|
| `musl-loader` | musl 1.2.5's dynamic loader, `ld-musl-<arch>.so.1`, version `1.2.5+tl.<N>`, installed at `~/.local/lib/musl/` | Built by `recipes/cross/build-musl-loader.sh` in `build.yml` and published as a `bins-…` release asset with a pinned digest. There is one asset per edition, because the Termux prefix is compiled into it |
| `musl-libstdcxx`, `musl-libgcc` | GCC 14.2.0's `libstdc++.so.6` and `libgcc_s.so.1`, built against musl | Taken unchanged from Alpine's packages (pinned by sha256) by `recipes/cross/fetch-musl-runtime.sh`, then published as release assets. Termux's own copies are linked against Bionic and the musl loader cannot load them |
| `ripgrep` | Termux's `ripgrep` package (hidden `pkg` item) | With no `rg` on PATH, opencode 2 downloads a *glibc* ripgrep that cannot run here. With this part installed, it uses the `rg` on PATH |
| `launcher-skill` | Hidden bundle that teaches agents to use the launcher's panes, notifications and display | Pinned files in this catalog |

The loader is stock musl with three changes (`build-musl-loader.sh` and its patches):

- `/etc/resolv.conf` and `/etc/hosts` are rewritten to `$PREFIX/etc/...`. Android has no
  `/etc/resolv.conf`, so stock musl's DNS times out.
- `0001-musl-ld-preload-var.patch`: the loader reads `MUSL_LD_PRELOAD` and ignores `LD_PRELOAD`.
  Termux sets `LD_PRELOAD` to termux-exec, which is a Bionic library. A musl process can't load
  it, and unsetting it would break shebang scripts in every child the agent spawns.
- `0002-musl-close-range-enosys.patch`: `syscall(SYS_close_range)` returns `ENOSYS`. Bun (inside
  opencode and Claude Code) calls it at start-up, and the app seccomp filter on Android 12 and
  older kills the process for it. Bun falls back to closing descriptors one at a time.

All three loader assets and the two library assets are hidden items. An `npm-musl` item is
offered only on a processor that has its loader and every library its `musl-libs` names.

## 3. What `tlstore install opencode` does

The engine code is `do_npm_musl` in `engine/tlstore`. After the required parts are installed:

1. **Checks its tools**: `curl`, `tar`, `sha512sum`, `base64`, `od`, plus `patchelf` for
   `npm-musl`, and that a `musl-loader` row exists for this device.
2. **Asks npm** for `https://registry.npmjs.org/@opencode/cli-linux-arm64-musl/latest`, or the
   pinned version if the row has one. `TLSTORE_NPM_REGISTRY` overrides the registry for tests.
   From the answer it reads `version`, `tarball` and `integrity`. If the integrity is missing or
   isn't a `sha512-` value, it stops and installs nothing.
3. **Skips the download** if `~/.local/lib/opencode/` already holds that version with an
   `rpath-first` marker. It only refreshes the loader and library copies (step 7).
4. **Downloads** the tarball into the cache and compares its sha512 with npm's integrity value.
   If they don't match, it deletes the file and installs nothing. This is the only check on the
   download: unlike release assets, npm items aren't pinned by our own digest, and their trust
   is npm's integrity value over TLS.
5. **Unpacks only what it needs** into `~/.local/lib/opencode.new/`: `package/bin/opencode`, any
   `extra=` members, and `LICENSE.md`/`LICENSE`/`NOTICE` when present.
6. **Copies in the musl runtime**: the installed loader becomes `ld-musl-aarch64.so.1` and the
   two libraries become `libstdc++.so.6` and `libgcc_s.so.1`, all beside the binary. If a part
   isn't installed, it is downloaded and checked against its digest.
7. **Patches the binary** with two separate `patchelf` calls:
   1. `--set-rpath ~/.local/lib/opencode`, so libraries are found only in its own directory;
   2. `--set-interpreter ~/.local/lib/opencode/ld-musl-aarch64.so.1`.

   The order matters. Termux's patchelf 0.19.2, given both at once or the interpreter first,
   moves `.dynamic` into a read-only mapping, and the loader segfaults. The `rpath-first` marker
   records a copy patched the safe way; a copy without it is treated as not installed.
8. **Writes `version`**, then swaps the new directory in for the old one in a single rename.
9. **Writes the wrapper** `~/.local/bin/opencode` and records the install in the state file.

On disk afterwards:

```
~/.local/lib/opencode/
├── bin/opencode            the upstream binary, interpreter and rpath patched
├── ld-musl-aarch64.so.1    copy of the musl-loader item
├── libstdc++.so.6          copy of musl-libstdcxx
├── libgcc_s.so.1           copy of musl-libgcc
├── LICENSE…                whatever licence files the package ships
├── version                 the npm version installed
└── rpath-first             marker: patched in the safe order
~/.local/bin/opencode       the wrapper on PATH
```

The wrapper (`wrapper_write`) looks like this:

```sh
#!/data/data/com.termux/files/usr/bin/sh
# written by termux-launcher
export OPENCODE_DISABLE_AUTOUPDATE=1
[ -n "${TZ:-}" ] || TZ=$(getprop persist.sys.timezone 2>/dev/null) && export TZ
exec "/data/data/com.termux/files/home/.local/lib/opencode/bin/opencode" "$@"
```

The wrapper is named after the executable inside the package (`opencode`; for Claude Code,
`claude`) unless the row sets `command=`. An `args=` option is written in front of `"$@"`; codex
uses one to switch off its update check.

## 4. Updates

- **New opencode version.** For a `latest` row, `tlstore update` (and the update check behind the
  store UI's badge) asks the registry what `latest` points at now and plans an install only when
  that differs from the installed `version`. Offline or with npm unreachable, the item is left
  alone. Nothing in this repository changes when opencode publishes a release.
- **Rebuilt loader or libraries.** The copies in opencode's directory are taken at unpack time.
  From tlstore 0.17, an install or update that finds opencode already current still compares
  each copy with the installed part, and replaces any that differ. The replacement is renamed
  into place, never written over, so a running opencode keeps its mapping. A loader fix
  therefore reaches opencode with the next `tlstore update` that installs the new `musl-loader`,
  not with opencode's next release. A rebuilt loader gets a new `1.2.5+tl.<N>` version.
- **What does need a change here**: a musl or GCC bump, a new launcher edition (a new prefix
  means a new loader asset), or a new app that needs more of the musl world (a new `musl-libs`
  entry and its asset).

## 5. Adding another npm item

1. Check the package has a musl build (or an Android one for `npm-android`), and where the
   executable sits inside it: `npm view <package>`, then look inside the tarball.
2. Add the row to `scripts/items.tsv` with `npm:<package>#<path>`. Usually that means version
   `latest`, an `env=` that turns off its own updater, and `tz=1`.
3. Run it on a device. If it fails to load a library, find the musl library it needs, add a
   `musl-libs=` entry, and if that library isn't published yet, add a fetch recipe and asset
   for it.
4. Add `x86_64:source=` only after checking the x64 package exists (`npm view <package> cpu`) and
   keeps the executable at the same path.
5. Rebuild the catalog (`scripts/build-catalog.sh`) and run `bash scripts/test.sh`.

## 6. Troubleshooting

| Symptom | Cause |
|---|---|
| `unexpected e_type: 2` over `ssh termux` | sshd runs in the `runas_app` context, where termux-exec runs everything through `/system/bin/linker64`, which refuses these non-PIE binaries. Run `export TERMUX_EXEC__SYSTEM_LINKER_EXEC__MODE=disable` in that session. From the launcher's own terminal it doesn't happen |
| Killed by SIGSYS at start on Android 12 or older | A loader without the close_range patch. `tlstore update` installs the current `musl-loader` and refreshes opencode's copy |
| DNS lookups time out | A loader built for another prefix: each edition needs its own loader asset |
| Segfault at start | A copy patched in the wrong order (no `rpath-first`). Reinstall: `tlstore install opencode` |
| `opencode has no musl-libstdcxx for this device` | The catalog has no library row for this processor |
| `… does not match its checksum — nothing was installed` | The download didn't match npm's sha512. Nothing was changed; try again |
| opencode searches fail or it tries to download ripgrep | `rg` missing from PATH. Reinstall the `ripgrep` part: `pkg install ripgrep` |
