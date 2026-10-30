# Grapefruit

<p align="center"><img src="docs/demo.gif" width="800" alt="Dragging a HEIC photo, tapping Shift, and dropping it on the JPG petal of the Grapefruit wheel"></p>

A menu bar app for macOS. Pick up a file, tap a key, and a wheel of things you can do with it opens right under your cursor. Drop the file on one.

Turning a HEIC into a JPG, trimming a voice memo or grabbing a still from a video takes one drag. Converted files land next to the original.

## How it works

1. Drag a file from Finder or your desktop.
2. While you're still dragging, tap a modifier key. A wheel opens under the cursor.
3. Drop on a petal.

Each key opens a different wheel:

| Key | Wheel | What's on it |
| --- | --- | --- |
| ⇧ Shift | Convert | Every format the file can become |
| ⌘ Command | Tools | Quick edits for that kind of file |
| ⌃ Control | Actions | Things to do with the file itself |

Don't like these keys? Change them in Settings (click the menu bar icon).

## What it can do

**Convert**

- Images: JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP and PDF (SVG works as input)
- Audio: MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA
- Video: MP4, MOV, MKV, WebM, AVI, WMV, plus GIF and MP3 out
- Documents: DOCX, Pages, PDF, Markdown, HTML, EPUB, TXT, RTF
- Spreadsheets: XLSX, XLS, ODS, CSV, TSV
- Subtitles: SRT and VTT
- Archives: ZIP, TAR, GZ (RAR works as input)

**Tools**

- Photos: edit, crop, annotate, redact, add a background, make a collage, compress, strip metadata
- Video: trim, crop, split, join, change speed, remove audio, redact, take snapshots
- Audio: trim, normalize volume, bleep, change channels, turn into a visualizer video
- PDF: merge, split, organize pages, create from images
- Archives: extract

**Actions**

- AirDrop
- Float: park files on a small shelf that stays above every window
- Copy or move to a folder
- Copy the file's path
- Open a Terminal (or iTerm2) window in the file's folder

Everything runs on your Mac. Grapefruit makes no network requests.

## Requirements

- macOS 26 or later
- [ffmpeg](https://ffmpeg.org) for audio and video: `brew install ffmpeg`
- Optional: Microsoft PowerPoint or Keynote for `.ppt` and `.pptx`, Excel for `.xls`, Pages for `.pages`

Settings shows which of these Grapefruit found.

## Build from source

You need Xcode 26 or a Swift 6.1 toolchain.

```bash
git clone https://github.com/jorgeplza/grapefruit.git
cd grapefruit
scripts/build.sh --run
```

This builds the app, installs it in `/Applications` and opens it. Grapefruit lives in the menu bar. Run `scripts/build.sh` without `--run` to just build `build/Grapefruit.app`.

## License

MIT. See [LICENSE](LICENSE).
