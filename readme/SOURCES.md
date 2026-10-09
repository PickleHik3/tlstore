# README sources

Each `readme/<name>.md` is the upstream project's README, fetched verbatim at the commit this
repository's tag pins, with one line prepended: `<!-- tlstore: pinned from <owner/repo>@<sha> -->`.
The store's Item page renders it as-is; relative image and link paths inside the file (for
example dawn's `assets/Kitty.gif` or fastfetch's `screenshots/example1.png`) are **left verbatim**
— the rendering engine resolves them against `https://raw.githubusercontent.com/<owner/repo>/<sha>/`
so they still point at the exact pinned commit, not upstream HEAD.

| File | Source URL | Commit | License | Fetched with |
|---|---|---|---|---|
| `dawn.md` | https://github.com/andrewmd5/dawn/blob/0e9587477463ece157ef7eea66c9e34bc5c7737a/README.md | `0e9587477463ece157ef7eea66c9e34bc5c7737a` | MIT (per catalog) | `gh api "repos/andrewmd5/dawn/contents/README.md?ref=<sha>"` → `download_url` → `curl` |
| `fastfetch.md` | https://github.com/fastfetch-cli/fastfetch/blob/56da8f811068289f6352db8881418aa6e0f994e8/README.md | `56da8f811068289f6352db8881418aa6e0f994e8` (tag `2.67.0`, no `v` prefix upstream) | MIT (per catalog) | `gh api "repos/fastfetch-cli/fastfetch/contents/README.md?ref=<sha>"` → `download_url` → `curl` |
| `kitty.md` | https://github.com/kovidgoyal/kitty/blob/7c79ed2b22091d6147630ff874fa265d944bb63d/README.asciidoc | `7c79ed2b22091d6147630ff874fa265d944bb63d` (tag `v0.48.2`) | GPL-3.0 (per catalog) | kitty's root README is `README.asciidoc`, not `.md` — content fetched via `gh api repos/kovidgoyal/kitty/contents/README.asciidoc?ref=<sha>` (base64), saved verbatim as `kitty.md`. It is genuinely short: upstream's real docs live at sw.kovidgoyal.net. |
| `sigye.md` | https://github.com/am2rican5/sigye/blob/f1a43ccdf621382fb1a4e652999ef7143c415b3f/README.md | `f1a43ccdf621382fb1a4e652999ef7143c415b3f` (tag `v0.6.0`) | MIT (per catalog) | plain `raw.githubusercontent.com` fetch 404'd for this repo; used `gh api repos/am2rican5/sigye/contents/README.md?ref=<sha>` base64 content instead |
| `claude-code.md` | https://github.com/anthropics/claude-code/blob/d78be9481b889e11186ec4578b4f5e9301396e25/README.md | `d78be9481b889e11186ec4578b4f5e9301396e25` (default branch `main` HEAD, resolved 2026-09-24) | Proprietary (per catalog) | `gh api "repos/anthropics/claude-code/contents/README.md?ref=<sha>"` → `download_url` → `curl` |
| `opencode.md` | https://github.com/anomalyco/opencode/blob/0f549842ee746e400b1f72516b0b2e292e267e2c/README.md | `0f549842ee746e400b1f72516b0b2e292e267e2c` (default branch `dev` HEAD, resolved 2026-09-24) | MIT (per catalog) | `gh api "repos/anomalyco/opencode/contents/README.md?ref=<sha>"` → `download_url` → `curl` |
| `btop.md` | https://github.com/aristocratos/btop/blob/6e39144aaf5a6bc01b9f795010b0914431067183/README.md | `6e39144aaf5a6bc01b9f795010b0914431067183` (tag v1.4.7) | Apache-2.0 (per catalog) | `curl https://raw.githubusercontent.com/aristocratos/btop/6e39144aaf5a6bc01b9f795010b0914431067183/README.md` |

Notes:
- `claude-code` and `opencode` have no release tags to pin against, so this pins their default
  branch's HEAD commit as of 2026-09-24 (`main` and `dev` respectively). A future re-pin needs a
  fresh resolve of that HEAD, since it moves.
- `kovidgoyal/kitty` and `am2rican5/sigye` returned HTTP 404 from plain `curl` against
  `raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>` in this environment even though the
  `download_url` GitHub's contents API returned was that exact URL; fetching the same content
  through `gh api .../contents/<path>?ref=<sha>` (base64-decoded) worked for both. Cause not
  diagnosed — noted here in case it recurs for a future re-pin.
- `herdr.md` is not a copy of upstream's README either: that one is a short feature list for a
  desktop install (badges, a video, install commands). It is written for this store from that
  list and herdr's quick-start docs (`herdrdev/herdr@7b116c05bfda646af39d2524c54e70c751f57ee8`,
  tag `v0.9.3`, Apache-2.0), with what was verified on a phone, so it has no pinned line either.
- `termux-api-shims.md` is not fetched from upstream: it is written for this store, so it has no
  `<!-- tlstore: pinned from ... -->` line and no relative images to resolve.
