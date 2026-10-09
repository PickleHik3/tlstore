# tlstore item pictures — sources

Each picture is the upstream project's own README hero image or a screenshot from its docs,
converted to JPEG (about 832 px wide, quality 80) and signed with the catalog like any other
`launcher:` source. Re-run the conversion the same way if a picture is ever replaced:

```sh
magick <original> -background "#1e1e1e" -flatten -resize 832x -quality 80 <item>.jpg
```

(`-background`/`-flatten` only matters for a source with transparency; it fills it so the JPEG
does not print black. `[0]` on the source file selects a GIF's first frame.)

| file | source | licence note |
| --- | --- | --- |
| `claude-code.jpg` | first frame of `demo.gif` in [anthropics/claude-code](https://github.com/anthropics/claude-code) | the repository's own terms (see its `LICENSE.md`); used here only to show the tool, not redistributed on its own |
| `dawn.jpg` | `assets/hero.png` in [andrewmd5/dawn](https://github.com/andrewmd5/dawn) | dawn is MIT licensed |
| `fastfetch.jpg` | `screenshots/example1.png` in [fastfetch-cli/fastfetch](https://github.com/fastfetch-cli/fastfetch) | fastfetch is MIT licensed |
| `kitten.jpg` | `docs/screenshots/diff.png` in [kovidgoyal/kitty](https://github.com/kovidgoyal/kitty) (the `kitten diff` screenshot, which shows an image diff — the closest upstream image to what this item does) | kitty is GPL-3.0 licensed |
| `opencode.jpg` | `packages/web/src/assets/lander/screenshot.png` in [anomalyco/opencode](https://github.com/anomalyco/opencode) | opencode is MIT licensed |
| `sigye.jpg` | first frame of `assets/demo.gif` in [am2rican5/sigye](https://github.com/am2rican5/sigye) | sigye is MIT licensed |
| `btop.jpg` | a frame of the same screen recording as `hero/btop.png`: this build of btop running on a phone through the privileged lane | btop is Apache-2.0 licensed; the screenshot is this repository's own |
| `herdr.jpg` | `assets/screenshot.png` in [herdrdev/herdr](https://github.com/herdrdev/herdr) at `7b116c05bfda646af39d2524c54e70c751f57ee8` (tag `v0.9.3`), cropped to the terminal window (`-crop 1566x980+177+48` on the 1920x1080 original) before the usual conversion, since the desktop around it is wasted width on a phone | herdr is Apache-2.0 licensed |

`fish-shell` has no picture: it is the launcher's own setup, not one upstream project, so there is
no single README to take a hero image from.
