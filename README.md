# mac-screen-search

![Code Base: AI Vibes](https://img.shields.io/badge/Code%20Base-AI%20Vibes%20%F0%9F%A4%A0-blue)

A macOS CLI tool that captures a screenshot of the entire screen, performs OCR to find all instances of a search term, draws colored rectangles around each match, and opens the annotated image in Preview.

It can also process existing image files in batch using a file glob pattern, making it useful for redacting sensitive text across many screenshots at once.

## AI Disclaimer

This project was vibe-coded with `Claude Opus 4.6`. While it has been tested on the author's system, it interacts directly with macOS screen capture, image processing, and file I/O, the author makes no guarantees and assumes no responsibility for unintended behavior, missed redactions, or any other issues arising from its use. Use at your own risk and always verify redactions before sharing sensitive screenshots.

## Requirements

- macOS (uses ScreenCaptureKit, Vision, and CoreGraphics)
- Screen Recording permission (for screenshot mode)
- Swift compiler

## Building

```sh
swiftc -O -o mac-screen-search mac-screen-search.swift -framework ScreenCaptureKit
```

## Usage

```
mac-screen-search [-r] [-e] [-d <dist>] [-c <color>] [-v] <search-term> [-f <glob>]
```

### Options

| Flag | Description |
|------|-------------|
| `-r` | Redact (fill with solid color) matched regions instead of outlining them |
| `-e` | Enhanced OCR (preprocess image + check multiple candidates) |
| `-d <dist>` | Fuzzy match using Levenshtein distance threshold |
| `-c <color>` | Rectangle color name (default: `red`). Available: black, blue, cyan, gray, green, magenta, orange, pink, purple, red, white, yellow |
| `-f <glob>` | Process image files matching the glob pattern instead of capturing the screen |
| `-v` | Print version and exit |

### Screenshot mode (default)

Capture a screenshot, find all occurrences of the search term, outline them in red (default), and open the result in Preview:

```sh
mac-screen-search "password"
```

There is a 2-second delay before capture so you can arrange your screen.

### Custom color

Use blue rectangles instead of red:

```sh
mac-screen-search -c blue "password"
```

### Redact mode

Fill matched regions with a solid color to obscure the text:

```sh
mac-screen-search -r "SSN"
mac-screen-search -r -c black "SSN"
```

### File glob mode

Process existing image files instead of capturing a screenshot. The glob is expanded by the tool itself (not the shell), so quote the pattern:

```sh
mac-screen-search "secret" -f '*.png'
```

Combine with `-r` to batch-redact sensitive text across many files:

```sh
mac-screen-search -r "api-key" -f '~/Screenshots/*.png'
```

In file mode:
- Files are overwritten in-place with the annotated/redacted version
- The original file modification time (mtime) is preserved
- Supported image formats include PNG, JPEG, TIFF, BMP, GIF, and others supported by `CGImageSource`
- A per-file summary is printed; no files are opened in Preview

### Enhanced OCR mode

Use `-e` to improve OCR accuracy on degraded images (e.g., screenshots taken over Zoom, transparent terminal backgrounds):

```sh
mac-screen-search -e "password"
```

- Composites the image onto a white background, removing transparency artifacts that confuse the OCR engine
- Boosts contrast (1.4x) and sharpens edges to make text crisper
- Checks the top 5 OCR candidates per text region instead of only the top 1, catching cases where the correct reading is a lower-ranked alternative

### Fuzzy matching mode

Use `-d <dist>` to match strings within a Levenshtein (edit) distance of the search term. This catches OCR misreads where characters are substituted (e.g., `Z` read as `2`, `g` as `q`):

```sh
mac-screen-search -d 3 "rBZrS6gq7NsD"
```

- Slides a window across each recognized text line and accepts any substring within the given edit distance
- A distance of 1 allows one character substitution, insertion, or deletion; higher values are more permissive
- Short search terms with high distance values may produce false positives; keep the ratio reasonable

### Combining flags

All flags compose freely. For example, to batch-redact a string across many screenshots with enhanced OCR and fuzzy matching:

```sh
mac-screen-search -r -e -d 3 -c black "api-key" -f '~/Screenshots/*.png'
```

### Example output (file mode)

```
Processing 4 files matching "*.png" for "api-key"
/Users/john/Screenshots/dashboard.png: 2 matches
/Users/john/Screenshots/settings.png: 1 match

2 files updated, 0 errors
```

## How it works

1. **Capture** -- Takes a Retina-resolution screenshot via ScreenCaptureKit (or loads image files in `-f` mode)
2. **OCR** -- Runs Apple Vision's `VNRecognizeTextRequest` with accurate recognition and language correction. With `-e`, the image is preprocessed first and multiple candidates are evaluated
3. **Search** -- Finds all case-insensitive occurrences of the search term, mapping each to pixel-coordinate bounding boxes. With `-d`, uses Levenshtein distance for fuzzy matching
4. **Annotate** -- Draws colored outline rectangles (or solid fill with `-r`) around each match, using the color specified by `-c` (default: red)
5. **Output** -- Saves the result as a timestamped PNG and opens it in Preview (screenshot mode), or overwrites files in-place preserving mtime (file mode)

## Personal Project Disclosure

This program is my own original idea, conceived and developed entirely:

* On my own personal time, outside of work hours
* For my own personal benefit and use
* On my personally owned equipment
* Without using any employer resources, proprietary information, or trade secrets
* Without any connection to my employer's business, products, or services
* Independent of any duties or responsibilities of my employment

This project does not relate to my employer's actual or demonstrably
anticipated research, development, or business activities. No
confidential or proprietary information from any employer was used
in its creation.
