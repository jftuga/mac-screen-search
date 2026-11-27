# Usage

[← Repository home](https://github.com/jftuga/mac-screen-search)

**Quick links:** [Options](#options) | [Screenshot mode](#screenshot-mode-default) | [File glob mode](#file-glob-mode) | [Debugging](#debugging-missed-matches) | [Examples](#combining-flags)

```
mac-screen-search [-r] [-b <pct>] [-e] [-d <dist>] [-c <color>] [-T <width>]
                  [-n] [-o <path>] [-m <n|all>] [-M] [-l] [-t <secs>] [-w]
                  [-D <delim>] [-s] [-v] <search-term> [-f <glob>]
```

## Options

| Flag | Description |
|------|-------------|
| `-r` | Redact (fill with solid color) matched regions instead of outlining them |
| `-b <percent>` | Blur matched regions with Gaussian blur (1-100); mutually exclusive with `-r` |
| `-e` | Enhanced OCR (preprocess image + check multiple candidates) |
| `-d <dist>` | Fuzzy match using Levenshtein distance threshold |
| `-c <color>` | Rectangle color name (default: `red`). Available: black, blue, cyan, gray, green, magenta, orange, pink, purple, red, white, yellow |
| `-f <glob>` | Process image files matching the glob pattern instead of capturing the screen |
| `-n` | Do not open the result in Preview (screenshot mode only) |
| `-o <path>` | Output directory or file path for the screenshot PNG (screenshot mode only) |
| `-m <n\|all>` | Capture monitor `n` (1-based, as numbered by `-M`) or `all` monitors (screenshot mode only) |
| `-M` | List connected monitors and exit |
| `-l` | List matches (text and coordinates) without annotating; incompatible with `-r`/`-b` |
| `-t <seconds>` | Capture delay in seconds (default: 2; use 0 for immediate). Screenshot mode only |
| `-w` | Whole-word matching (require word boundaries on both sides of the match) |
| `-D <delim>` | Delimiter for multiple search terms (default: `\|`). The search-term argument is split on this delimiter; each piece is searched independently and all matches are merged |
| `-T <width>` | Line thickness for outline rectangles (default: `4`). Accepts any positive number |
| `-s` | Also save the unannotated image that OCR searched, for debugging (preprocessed version when `-e` is set). Screenshot mode only |
| `-h` | Print help and exit |
| `-v` | Print version and exit |

## Screenshot mode (default)

Capture a screenshot, find all occurrences of the search term, outline them in red (default), and open the result in Preview:

```sh
mac-screen-search "password"
```

There is a 2-second delay before capture so you can arrange your screen. Use `-t` to change it:

```sh
mac-screen-search -t 5 "password"    # 5-second delay
mac-screen-search -t 0 "password"    # immediate capture
```

## Custom color

Use blue rectangles instead of red:

```sh
mac-screen-search -c blue "password"
```

## Redact mode

Fill matched regions with a solid color to obscure the text:

```sh
mac-screen-search -r "my_password"
mac-screen-search -r -c black "my_password"
```

## Blur mode

Apply a Gaussian blur to matched regions instead of filling or outlining them. The percentage controls blur intensity (1 = subtle, 100 = fully obscured):

```sh
mac-screen-search -b 50 "my_password"
mac-screen-search -b 80 "api-key" -f '*.png'
```

The `-b` and `-r` flags are mutually exclusive.

## No-open mode

Save the annotated screenshot without opening it in Preview. Useful for scripting and automation:

```sh
mac-screen-search -n "password"
```

## Output path

Control where the screenshot PNG is saved instead of the current working directory:

```sh
mac-screen-search -o ~/Screenshots "password"          # save to directory
mac-screen-search -o ~/Screenshots/result.png "password"  # save to specific file
```

When used with `-m all`, `-o` must point to a directory.

## Monitor selection

Capture a specific monitor by its 1-based index, or all connected monitors:

```sh
mac-screen-search -m 1 "password"      # first monitor (the default)
mac-screen-search -m 2 "password"      # second monitor
mac-screen-search -m all "password"    # all monitors (one file per display)
```

Use `-M` to list connected monitors with their size in points and pixels, display name, and current refresh rate in Hz:

```sh
mac-screen-search -M
```

Example output:

```
Monitor 1: 2560x1440 pt (2560x1440 px) LG ULTRAGEAR            [refresh: 144]
Monitor 2: 1920x1080 pt (3840x2160 px) DELL U2720Q             [refresh: 60]
Monitor 3: 1512x982  pt (3024x1964 px) Built-in Retina Display [refresh: 60]
```

`pt` is the size in points, the "Looks like" setting in System Settings > Displays. `px` is the size in pixels of the screenshot that is captured and searched, and the space that `-l` coordinates are in. Retina displays usually render at 2x, so each point is 2x2 pixels; a display at 1x shows the same size for both. The `px` size is not necessarily the panel's physical resolution, because macOS resamples scaled modes to fit the panel.

The number after `Monitor` is the value to pass to `-m`; with the output above, `-m 2` captures the DELL U2720Q. Monitor 1 is not necessarily the built-in or main display; it is the display captured when `-m` is omitted. The display name is the one shown in System Settings. Refresh rate prints as `unknown` when the display does not report one.

## List mode

Print match text and pixel coordinates without annotating or saving an image. Matches are written to stdout as tab-separated values with a header row. Status messages (`Searching for:`, `Found N matches`, etc.) go to stderr, so stdout can be piped directly into other tools. Coordinates are rounded to the nearest pixel.

In screenshot mode, the first column is the 1-based monitor number (as used by `-m` and shown by `-M`). Coordinates are relative to that monitor's screenshot:

```sh
mac-screen-search -t 0 -l "test" 2>/dev/null
```

```
monitor text    x       y       width   height
1       test    1766    183     92      42
1       test    1060    1544    136     35
1       test    331     1591    143     38
```

In file glob mode, the first column is the file path instead:

```sh
mac-screen-search -l "test" -f '*.png' 2>/dev/null
```

```
file    text    x       y       width   height
/Users/john/Screenshots/a.png   test    1089    273     149     34
/Users/john/Screenshots/b.png   test    323     315     151     41
```

The `-l` flag is incompatible with `-r` and `-b`.

## Whole-word matching

Only match when the search term has word boundaries on both sides. Reduces false positives for short search terms:

```sh
mac-screen-search -w "is"    # matches "is" but not "this" or "island"
```

Also works with fuzzy matching (`-d`).

## Multi-term search

Search for multiple terms at once by separating them with `|` (the default delimiter). All terms are matched against the same OCR output and results are merged:

```sh
mac-screen-search "password|secret|api-key"
```

Use `-D` to change the delimiter if your search terms contain the `|` character:

```sh
mac-screen-search -D "," "password,secret,api-key"
```

Since the shell interprets `|` as a pipe, the search-term argument must be quoted.

## Debugging missed matches

When nothing matches in screenshot mode, hints are printed to stderr. If more than one monitor is connected and `-m all` was not used, the hint names the monitor that was searched and suggests `-m`, since the text may be on another screen:

```
No matches found for "password"
Hint: searched monitor 1 of 3; use -m <n> or -m all if the text is on another screen.
Hint: use -s to save the searched image and see what OCR actually saw.
```

When a term is not found but should be, use `-s` to save the exact image that was passed to OCR, so you can inspect what was actually searched:

```sh
mac-screen-search -s "password"
mac-screen-search -s -e "password"    # saves the preprocessed (enhanced) image
```

The image is saved as `screenshot--<timestamp>--searched.png` (with `--monitorN` before `--searched` when multiple monitors are captured), in the same directory as the annotated output (`-o` is honored; if `-o` names a file, its parent directory is used). It is written before OCR runs, so it is saved whether or not any matches are found, and it is never opened in Preview. Not supported in file glob mode.

## File glob mode

Process existing image files instead of capturing a screenshot. The glob is expanded by the tool itself (not the shell), so quote the pattern:

```sh
mac-screen-search "secret" -f '*.png'
```

Combine with `-r` or `-b` to batch-redact or blur sensitive text across many files:

```sh
mac-screen-search -r "api-key" -f '~/Screenshots/*.png'
mac-screen-search -b 60 "api-key" -f '~/Screenshots/*.png'
```

In file mode:

- Files are overwritten in-place with the annotated/redacted version
- The original file modification time (mtime) is preserved
- Supported image formats include PNG, JPEG, TIFF, BMP, GIF, and others supported by `CGImageSource`
- A per-file summary is printed; no files are opened in Preview

## Enhanced OCR mode

Use `-e` to improve OCR accuracy on degraded images (e.g., screenshots taken over Zoom, transparent terminal backgrounds):

```sh
mac-screen-search -e "password"
```

- Composites the image onto a white background, removing transparency artifacts that confuse the OCR engine
- Boosts contrast (1.4x) and sharpens edges to make text crisper
- Checks the top 5 OCR candidates per text region instead of only the top 1, catching cases where the correct reading is a lower-ranked alternative

## Fuzzy matching mode

Use `-d <dist>` to match strings within a Levenshtein (edit) distance of the search term. This catches OCR misreads where characters are substituted (e.g., `Z` read as `2`, `g` as `q`), dropped, or added:

```sh
mac-screen-search -d 3 "rBZrS6gq7NsD"
```

- Checks substrings of each recognized text line whose length is within the given distance of the search term's length, and accepts any within the given edit distance. Substrings that begin or end with whitespace are skipped, so a multi-word search term can miss a match whose first or last word is missing entirely
- A distance of 1 allows one character substitution, insertion, or deletion; higher values are more permissive
- Overlapping candidates are reduced to one match per occurrence: the lowest distance wins, then a span aligned to word boundaries, then the length closest to the search term. A lower-ranked candidate is still kept if it shares no characters with a kept match and covers a whitespace-delimited token no kept match covers. Two occurrences inside one unbroken token are reported once
- This consolidation also applies with `-d 0`: repeated exact occurrences within one whitespace-delimited token are reported once. Searching without `-d` retains the existing exact-match behavior
- Common OCR merges and splits, such as `rn` read as `m`, cost 2 (a substitution plus an insertion or deletion)
- Short search terms with high distance values may produce false positives; keep the ratio reasonable

## Combining flags

All flags compose freely. For example, to batch-redact a string across many screenshots with enhanced OCR and fuzzy matching:

```sh
mac-screen-search -r -e -d 3 -c black "api-key" -f '~/Screenshots/*.png'
```

Capture immediately, whole-word match, save to a specific directory without opening Preview:

```sh
mac-screen-search -t 0 -n -w -o ~/Screenshots "password"
```

## Example output (file mode)

```
Processing 4 files matching "*.png" for "api-key"
/Users/john/Screenshots/dashboard.png: 2 matches
/Users/john/Screenshots/settings.png: 1 match

2 files updated, 0 errors
```
