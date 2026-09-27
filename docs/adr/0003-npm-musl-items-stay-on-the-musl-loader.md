---
status: accepted
date: 2026-09-27
---

# npm-musl items stay on our own musl loader, not Termux's glibc-runner

Claude Code and opencode are upstream Linux binaries. The engine fetches each one's musl build
from npm, checks npm's sha512, copies in our patched musl 1.2.5 loader (`build-musl-loader.sh`:
Termux-prefix resolv.conf and hosts, `MUSL_LD_PRELOAD`) plus, for opencode, Alpine's musl
`libstdc++`/`libgcc_s`, and points the binary at them with `patchelf`. We asked whether Termux's
glibc-packages (`glibc-runner`/`grun`) would serve better, tested it on a device on 2026-09-26/27,
and decided to keep the musl loader.

What was checked:
- Correctness: an on-device run of opencode 2.0.18 covered spawning Termux programs and shebang
  scripts (termux-exec still reaches children), PTYs, inotify, DNS/TLS/IPv6, non-ASCII paths,
  parallel tools and its bundled native `.so`/`.node` addons. Nothing failed because of musl or
  the loader. Of 1548 ELF files on the device, none asked for the glibc loader.
- The one glibc gap: with no `rg` on PATH, opencode 2 downloads ripgrep 15.1.0 for
  `aarch64-unknown-linux-gnu`, a glibc build. Fixed on our side: opencode requires a hidden
  `ripgrep` pkg item, and opencode prefers the `rg` on PATH.
- Performance: no case for glibc. Both apps are Bun binaries that bring their own allocator, and
  the heavy work runs in Termux's own (Bionic) programs. Nothing was benchmarked.
- Disk: the musl parts are about 3.8 MB on disk. `glibc-runner` and what it requires come to
  41 packages, about 72 MB to download and about 407 MB installed (Termux glibc repository index,
  2026-09-27).
- Upkeep: upstream app updates need no recipe change (the catalog pins `latest` and patches on the
  device). Recipes change only for a musl/GCC bump, a new edition prefix, or a new app that needs
  more of musl (`musl-libs=`). glibc-runner would not remove the per-app catalog work.
- Editions and trust: glibc-packages is built for the `com.termux` prefix only, and a third-party
  repository that updates on its own schedule would sit outside our digest-pinned, signed catalog.

Not an argument either way: over `ssh termux` (sshd in the `runas_app` SELinux context)
termux-exec runs everything through `/system/bin/linker64`, which refuses these non-PIE binaries
(`unexpected e_type: 2`). `export TERMUX_EXEC__SYSTEM_LINKER_EXEC__MODE=disable` fixes it for that
session. A glibc binary patched the same way would fail the same way.

Revisit only if a tool we want ships a glibc build and no musl build, or if an app starts
downloading glibc helpers at run time. opencode's language-server downloads were not exercised:
language servers are off by default in opencode 2, and `opencode run` started none even with
`"lsp": true`.
