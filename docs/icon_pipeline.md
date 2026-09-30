# Icon pipeline: PNG (ChatGPT/DALL-E output) → correctly-sized DDS

**Status:** confirmed via our own testing (2026-09-30) - every command below was
actually run against the real tool install on this machine, not guessed from
`-help` text alone. Real output sizes quoted are from those runs.

The recurring workflow: you generate/throw a PNG at me (often ChatGPT image
output, non-standard size, sometimes non-square), I resize it to whatever this
mod's icon slot actually needs and run it through GIANTS' own textureTool to
get a `.dds` the game will load without a quality warning. Two separate tools,
two separate jobs - see the gotcha below for why they can't be swapped.

## Where the tool actually lives (right now)

```bash
ls "/mnt/c/Users/Startklar/Documents/fs25_resources/texture_tool/textureTool_9.0.1_win64/textureTool.exe"
```

`AI_DEV_GUIDE.md` §2 documents an older path
(`.../Documents/My FS 25 Mods/texture_tool/...`) that no longer exists on this
machine - it moved into `fs25_resources` (the "dev tools/references" folder
`AI_DEV_GUIDE.md` §1 already describes), consistent with everything else kept
there (decompilers, PDFs). Confirmed via `find`, not assumed.

## Step 1 - resize/crop to the target's exact square size

This mod ships two icon sizes, both already established by what's actually
committed in the repo (checked with `identify`, not guessed):

| Slot | Size | Real example already in the repo |
|---|---|---|
| Store/mod icon (`icon.png` / `icon.dds`) | 512×512 | `assets/icon.png` |
| HUD tab icon (`gui/icons/*.dds`) | 128×128 | `gui/icons/field.dds` |

ChatGPT output is frequently square already (1024×1024 is common), but don't
assume it - a non-square source resized with plain `-resize WxH` will NOT
come out square (ImageMagick fits *within* the box, aspect ratio preserved,
so the short side wins). Cover-then-crop instead, confirmed on a real 768×768
test source:

```bash
magick source.png -resize 512x512^ -gravity center -extent 512x512 icon_512.png
identify icon_512.png   # sanity check: must read exactly "512x512" before step 2
```

The `^` makes `-resize` fill (cover) the target box instead of fit inside it;
`-gravity center -extent 512x512` then crops the overflow down to an exact
square, centered. For the small HUD tab icons, same command, `128x128`
instead of `512x512`.

## Step 2 - convert to DDS with textureTool, not ImageMagick

```bash
# textureTool.exe is a native Windows binary - if your PNG lives on the WSL
# side (e.g. under ~/my_mods/...), convert its path to a UNC path first so
# the Windows process can actually see it:
wslpath -w /path/to/icon_512.png
# -> \\wsl.localhost\<distro>\path\to\icon_512.png

cd "/mnt/c/Users/Startklar/Documents/fs25_resources/texture_tool/textureTool_9.0.1_win64"
./textureTool.exe -inputs '\\wsl.localhost\Ubuntu-26.04\path\to\icon_512.png' \
    -format bc7 -colorSpace srgb -textureType 2d -ignoreTimestamp
```

Confirmed real output for a 512×512 RGBA source: **349,668 bytes**, BC7,
`Operation completed with no errors.` - matches the byte size of this repo's
own already-shipped `icon.dds` and `assets/testrig_store.dds` exactly, so
this is provably the same recipe that produced what's already committed.

The `.dds` lands next to the source PNG with the same basename - move/rename
it into place (`icon.dds` at repo root, or `gui/icons/<name>.dds`) same as
any other build output.

## Gotchas

### Never use ImageMagick for the actual PNG→DDS conversion

ImageMagick is only for step 1 (resizing/cropping a PNG to another PNG).
`AI_DEV_GUIDE.md` §2 already covers this in detail (confirmed via direct
testing: an ImageMagick-built DDS loads but triggers an in-game quality
warning, because the engine checks for the tool's own generation marker, not
just pixel format) - repeating the short version here since it's the exact
mistake this pipeline exists to avoid: resize with `magick`, convert with
`textureTool.exe`, never the other way around, never skip straight to
ImageMagick for the final file.

### `-colorSpace srgb` is not optional for a plain icon

`template.gim` (next to the exe) documents the tool's own default: `srgb`
defaults to `true` only for files whose name ends in `_diffuse`, and `false`
otherwise. A file named `icon.png` doesn't match that suffix, so **leaving
`-colorSpace` off builds a linear-interpreted DDS for what is actually sRGB
color content** - no error, no warning, just a washed-out-looking icon in the
game's UI. Always pass `-colorSpace srgb` explicitly for icons; don't rely on
the filename-based default.

### Format also has a real default, but it's the right one for icons

Also per `template.gim`: with no `-format` given, the tool picks `bc7` for a
4-channel (RGBA) source and `bc1` for 3-channel (RGB) - so `-format bc7` is
redundant for an RGBA icon, but still worth passing explicitly rather than
relying on the source PNG happening to have an alpha channel. Cheap
insurance against a future source PNG accidentally getting flattened to RGB
somewhere in the resize step.

### WSL↔Windows path crossing

`textureTool.exe` is a native Windows process; it cannot read a bare Linux
path like `/home/mirzuf/...`. Always run the input path through
`wslpath -w` first (confirmed working: produces a
`\\wsl.localhost\<distro>\...` UNC path the tool reads directly, no copying
the file to `/mnt/c` needed).

## References

- `AI_DEV_GUIDE.md` §2 - the original textureTool usage note and the
  ImageMagick-quality-warning finding this page builds on
- `<textureTool dir>/textureTool.xml`, `-help` output, `template.gim` - the
  tool's own real, complete flag/metadata documentation (quoted from
  directly, not paraphrased from memory)
- `assets/testrig_store.png` / `.gim` / `.dds` - a real, already-converted
  worked example left in the repo specifically as a reference case
