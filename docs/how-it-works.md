# How it works

[← Repository home](https://github.com/jftuga/mac-screen-search)

1. **Capture** -- Takes a screenshot at the display's native pixel resolution (2x on Retina, 1x on standard displays) via ScreenCaptureKit (or loads image files in `-f` mode). Supports selecting a specific monitor (`-m`) and configurable delay (`-t`)
2. **OCR** -- Runs Apple Vision's `VNRecognizeTextRequest` with accurate recognition and language correction. With `-e`, the image is preprocessed first and multiple candidates are evaluated
3. **Search** -- Finds all case-insensitive occurrences of each search term (split by `-D` delimiter, default `|`), mapping each to pixel-coordinate bounding boxes. With `-d`, uses Levenshtein distance for fuzzy matching. With `-w`, requires word boundaries
4. **Annotate** -- Draws colored outline rectangles (or solid fill with `-r`, or Gaussian blur with `-b`) around each match, using the color specified by `-c` (default: red). Skipped in list mode (`-l`)
5. **Output** -- Saves the result as a timestamped PNG and opens it in Preview (screenshot mode), or overwrites files in-place preserving mtime (file mode). Use `-o` to set the output path and `-n` to skip Preview. Use `-s` to also save the unannotated image that OCR searched
