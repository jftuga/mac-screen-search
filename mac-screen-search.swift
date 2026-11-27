// mac-screen-search: A macOS CLI tool for finding and highlighting text on screen
// or in existing image files via OCR.
//
// Modes:
//   - Screenshot mode (default): captures the screen after a configurable delay (-t,
//     default 2s), performs OCR, draws colored rectangles around matches, saves a
//     timestamped PNG, and opens it in Preview. Requires Screen Recording permission.
//   - File glob mode (-f): processes existing image files matching a glob pattern,
//     annotating or redacting matches in-place while preserving modification times.
//
// Features:
//   - Case-insensitive exact matching or fuzzy matching via Levenshtein distance (-d)
//   - Whole-word matching (-w) using word boundary detection
//   - Enhanced OCR mode (-e): preprocesses images (white background compositing,
//     contrast boost, sharpening) and evaluates multiple OCR candidates
//   - Redaction mode (-r): fills matched regions with a solid color
//   - Blur mode (-b): applies Gaussian blur to matched regions at a given intensity
//   - Configurable annotation color (-c) from a set of named colors
//   - Configurable line thickness (-T) for outline rectangles
//   - Monitor selection (-m) and listing (-M) for multi-display setups
//   - List mode (-l): prints match text and coordinates as TSV on stdout without
//     annotation (status messages go to stderr)
//   - Multi-term search via configurable delimiter (-D, default: |)
//   - Output path control (-o), no-preview mode (-n), configurable delay (-t)
//   - Debug save (-s): writes the exact unannotated image passed to OCR
//   - No-match hints suggesting -m (unsearched monitors) and -s
//   - Help (-h) and version (-v) flags

import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: - Screenshot

/// Return the displays to capture based on the monitor selection flag, each paired
/// with its 1-based monitor number (as used by -m and -M), along with the total
/// number of connected displays.
func getDisplays(selection: String?) async throws -> (selected: [(number: Int, display: SCDisplay)], total: Int) {
    let content = try await SCShareableContent.current
    let allDisplays = content.displays
    guard !allDisplays.isEmpty else {
        throw NSError(domain: "mac-screen-search", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "No display found"])
    }

    guard let sel = selection else {
        return ([(1, allDisplays[0])], allDisplays.count)
    }

    if sel == "all" {
        return (allDisplays.enumerated().map { ($0.offset + 1, $0.element) }, allDisplays.count)
    }

    guard let index = Int(sel), index >= 1, index <= allDisplays.count else {
        throw NSError(domain: "mac-screen-search", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Monitor index \(sel) out of range (1-\(allDisplays.count) available)"])
    }
    return ([(index, allDisplays[index - 1])], allDisplays.count)
}

/// Return the native pixel dimensions of a display using its actual point-to-pixel
/// scale (e.g. 2 on Retina, 1 on standard displays) instead of assuming Retina.
func nativePixelSize(of display: SCDisplay) -> (width: Int, height: Int) {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let scale = Double(SCShareableContent.info(for: filter).pointPixelScale)
    return (Int((Double(display.width) * scale).rounded()),
            Int((Double(display.height) * scale).rounded()))
}

/// Capture a screenshot of the given display at its native pixel resolution.
func captureScreenshot(display: SCDisplay) async throws -> CGImage {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let size = nativePixelSize(of: display)
    let config = SCStreamConfiguration()
    config.width = size.width
    config.height = size.height
    config.showsCursor = false

    return try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
}

// MARK: - Levenshtein Distance

/// Compute the Levenshtein (edit) distance between `pattern` and every prefix of
/// `text` in a single dynamic-programming pass.  Element `j` of the result is the
/// distance between `pattern` and the first `j` characters of `text`.
func prefixEditDistances(_ pattern: [Character], _ text: ArraySlice<Character>) -> [Int] {
    let b = Array(text)
    let n = b.count

    var prev = Array(0...n)
    var curr = Array(repeating: 0, count: n + 1)

    for (i, ch) in pattern.enumerated() {
        curr[0] = i + 1
        for j in stride(from: 1, through: n, by: 1) {
            if ch == b[j-1] {
                curr[j] = prev[j-1]
            } else {
                curr[j] = 1 + min(prev[j], curr[j-1], prev[j-1])
            }
        }
        swap(&prev, &curr)
    }
    return prev
}

/// Find spans of `text` within `maxDistance` edits of `pattern`, returned as
/// character-offset ranges in text order.  Substrings whose length is within
/// `maxDistance` of the pattern's length are considered, so insertions and deletions
/// match as well as substitutions.  Spans that begin or end with whitespace are
/// skipped by policy; for patterns without internal whitespace this never loses a
/// match, but a multi-word pattern can miss one whose outer word is absent at a
/// span edge.  Overlaps are resolved with whitespace-delimited tokens as an
/// approximation of Vision's word-level bounding boxes: candidates are ranked by
/// distance, then by whether the span is aligned to word boundaries, then by length
/// closest to the pattern, then by position.  A candidate is kept only if it shares
/// no characters with an already-kept span and touches at least one token that no
/// kept span touches.
func fuzzyMatchSpans(in text: [Character], pattern: [Character], maxDistance: Int, wholeWord: Bool) -> [Range<Int>] {
    let m = pattern.count
    let n = text.count
    let minLen = max(1, m - maxDistance)
    let maxLen = m + maxDistance

    // Index of the whitespace-delimited token containing each character (-1 for whitespace)
    var wordIndex = Array(repeating: -1, count: n)
    var word = -1
    for i in 0..<n where !text[i].isWhitespace {
        if i == 0 || text[i-1].isWhitespace { word += 1 }
        wordIndex[i] = word
    }

    let isWord: (Character?) -> Bool = { c in guard let c = c else { return false }; return c.isLetter || c.isNumber || c == "_" }
    var candidates: [(range: Range<Int>, distance: Int, misaligned: Int)] = []

    for start in 0..<n where !text[start].isWhitespace {
        let end = min(n, start + maxLen)
        guard end - start >= minLen else { continue }
        let distances = prefixEditDistances(pattern, text[start..<end])

        for len in minLen...(end - start) where distances[len] <= maxDistance {
            let range = start..<(start + len)
            if text[range.upperBound - 1].isWhitespace { continue }
            let before = start > 0 ? text[start - 1] : nil
            let after = range.upperBound < n ? text[range.upperBound] : nil
            let aligned = !isWord(before) && !isWord(after)
            if wholeWord && !aligned { continue }
            candidates.append((range, distances[len], aligned ? 0 : 1))
        }
    }

    candidates.sort {
        ($0.distance, $0.misaligned, abs($0.range.count - m), $0.range.lowerBound) <
        ($1.distance, $1.misaligned, abs($1.range.count - m), $1.range.lowerBound)
    }

    var kept: [Range<Int>] = []
    var claimedWords = Set<Int>()
    for candidate in candidates {
        let words = wordIndex[candidate.range.lowerBound]...wordIndex[candidate.range.upperBound - 1]
        if kept.contains(where: { $0.overlaps(candidate.range) }) || words.allSatisfy(claimedWords.contains) { continue }
        claimedWords.formUnion(words)
        kept.append(candidate.range)
    }
    return kept.sorted { $0.lowerBound < $1.lowerBound }
}

// MARK: - Image Preprocessing

/// Preprocess an image to improve OCR accuracy: composite onto a white background
/// to eliminate transparency, boost contrast, and sharpen edges.
func preprocessImage(_ image: CGImage) -> CGImage {
    let ciImage = CIImage(cgImage: image)
    let context = CIContext()

    // Composite onto white background to eliminate transparency artifacts
    let white = CIImage(color: CIColor.white).cropped(to: ciImage.extent)
    var result = ciImage.composited(over: white)

    // Boost contrast
    if let filter = CIFilter(name: "CIColorControls") {
        filter.setValue(result, forKey: kCIInputImageKey)
        filter.setValue(1.4, forKey: kCIInputContrastKey)
        if let output = filter.outputImage {
            result = output
        }
    }

    // Sharpen
    if let filter = CIFilter(name: "CISharpenLuminance") {
        filter.setValue(result, forKey: kCIInputImageKey)
        filter.setValue(0.5, forKey: kCIInputSharpnessKey)
        if let output = filter.outputImage {
            result = output
        }
    }

    return context.createCGImage(result, from: result.extent) ?? image
}

/// Return the image that OCR should run on: the preprocessed image when
/// `enhanced` is true, otherwise the original.
func ocrInput(_ image: CGImage, enhanced: Bool) -> CGImage {
    return enhanced ? preprocessImage(image) : image
}

// MARK: - OCR

/// A single match with its bounding box in image pixel coordinates.
struct TextMatch {
    let text: String
    let rect: CGRect
}

/// Perform OCR on the image and return bounding rects for all occurrences of the
/// search terms (case-insensitive).  OCR runs once; each term is matched against
/// the same recognized text.  Callers are responsible for preprocessing (see
/// `ocrInput`).  When `enhanced` is true, multiple OCR candidates are checked.
/// When `maxDistance` is set, fuzzy matching via Levenshtein distance is used
/// instead of exact matching.
func findMatches(in image: CGImage, searchTerms: [String], enhanced: Bool = false, maxDistance: Int? = nil, wholeWord: Bool = false) throws -> [TextMatch] {
    let handler = VNImageRequestHandler(cgImage: image)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    try handler.perform([request])

    guard let observations = request.results else { return [] }

    let imageWidth = CGFloat(image.width)
    let imageHeight = CGFloat(image.height)
    let candidateCount = enhanced ? 5 : 1
    var matches: [TextMatch] = []

    for searchTerm in searchTerms {
        let lowerSearch = searchTerm.lowercased()

        for observation in observations {
            let candidates = observation.topCandidates(candidateCount)
            var observationMatched = false

            for candidate in candidates {
                let fullString = candidate.string
                let lowerFull = fullString.lowercased()

                if let maxDist = maxDistance {
                    let spans = fuzzyMatchSpans(in: Array(lowerFull), pattern: Array(lowerSearch),
                                                maxDistance: maxDist, wholeWord: wholeWord)

                    for span in spans {
                        let origStart = fullString.index(fullString.startIndex, offsetBy: span.lowerBound)
                        let origEnd = fullString.index(origStart, offsetBy: span.count)
                        let originalRange = origStart..<origEnd

                        if let box = try? candidate.boundingBox(for: originalRange) {
                            let normRect = box.boundingBox
                            let pixelRect = CGRect(
                                x: normRect.origin.x * imageWidth,
                                y: (1.0 - normRect.origin.y - normRect.size.height) * imageHeight,
                                width: normRect.size.width * imageWidth,
                                height: normRect.size.height * imageHeight
                            )
                            matches.append(TextMatch(text: String(fullString[originalRange]), rect: pixelRect))
                            observationMatched = true
                        }
                    }
                } else if wholeWord {
                    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: lowerSearch))\\b"
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                    let nsRange = NSRange(fullString.startIndex..., in: fullString)
                    for result in regex.matches(in: fullString, range: nsRange) {
                        guard let swiftRange = Range(result.range, in: fullString) else { continue }
                        if let box = try? candidate.boundingBox(for: swiftRange) {
                            let normRect = box.boundingBox
                            let pixelRect = CGRect(
                                x: normRect.origin.x * imageWidth,
                                y: (1.0 - normRect.origin.y - normRect.size.height) * imageHeight,
                                width: normRect.size.width * imageWidth,
                                height: normRect.size.height * imageHeight
                            )
                            matches.append(TextMatch(text: String(fullString[swiftRange]), rect: pixelRect))
                            observationMatched = true
                        }
                    }
                } else {
                    var searchStart = lowerFull.startIndex
                    while let range = lowerFull.range(of: lowerSearch, range: searchStart..<lowerFull.endIndex) {
                        let lowerOffset = lowerFull.distance(from: lowerFull.startIndex, to: range.lowerBound)
                        let upperOffset = lowerFull.distance(from: lowerFull.startIndex, to: range.upperBound)
                        let origStart = fullString.index(fullString.startIndex, offsetBy: lowerOffset)
                        let origEnd = fullString.index(fullString.startIndex, offsetBy: upperOffset)
                        let originalRange = origStart..<origEnd

                        if let box = try? candidate.boundingBox(for: originalRange) {
                            let normRect = box.boundingBox
                            let pixelRect = CGRect(
                                x: normRect.origin.x * imageWidth,
                                y: (1.0 - normRect.origin.y - normRect.size.height) * imageHeight,
                                width: normRect.size.width * imageWidth,
                                height: normRect.size.height * imageHeight
                            )
                            matches.append(TextMatch(text: String(fullString[originalRange]), rect: pixelRect))
                            observationMatched = true
                        }

                        searchStart = range.upperBound
                    }
                }

                if observationMatched { break }
            }
        }
    }

    return matches
}

// MARK: - Color Mapping

/// Map simple color names to CGColor values.
let namedColors: [String: CGColor] = [
    "red":     CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0),
    "green":   CGColor(red: 0.0, green: 0.8, blue: 0.0, alpha: 1.0),
    "blue":    CGColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0),
    "yellow":  CGColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0),
    "orange":  CGColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0),
    "purple":  CGColor(red: 0.5, green: 0.0, blue: 0.5, alpha: 1.0),
    "cyan":    CGColor(red: 0.0, green: 1.0, blue: 1.0, alpha: 1.0),
    "magenta": CGColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1.0),
    "white":   CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
    "black":   CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
    "gray":    CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0),
    "pink":    CGColor(red: 1.0, green: 0.4, blue: 0.7, alpha: 1.0),
]

/// Resolve a color name to a CGColor, or nil if unrecognized.
func resolveColor(_ name: String) -> CGColor? {
    return namedColors[name.lowercased()]
}

// MARK: - Annotation

/// Draw colored rectangles around each match on a copy of the image.
/// When `redact` is true, the rectangles are filled with a solid color to obscure
/// the matched text; when `blurPercent` is set, the matched regions are Gaussian-blurred;
/// otherwise, only an outline is drawn.
func annotateImage(_ image: CGImage, matches: [TextMatch], redact: Bool = false, blurPercent: Int? = nil,
                   color: CGColor = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0), lineThickness: CGFloat = 4.0) -> CGImage? {
    let width = image.width
    let height = image.height

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Draw original image
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Pre-blur the entire image once if blur mode is active
    var blurredImage: CGImage? = nil
    if let bp = blurPercent {
        let ci = CIImage(cgImage: image)
        let radius = Double(bp) / 2.0
        if let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            if let output = filter.outputImage?.cropped(to: ci.extent) {
                blurredImage = CIContext().createCGImage(output, from: ci.extent)
            }
        }
    }

    // Draw rectangles in the specified color
    context.setStrokeColor(color)
    context.setLineWidth(lineThickness)

    for match in matches {
        // CGContext origin is bottom-left, but our rects were computed with
        // top-left origin. Flip Y back.
        let flippedRect = CGRect(
            x: match.rect.origin.x,
            y: CGFloat(height) - match.rect.origin.y - match.rect.height,
            width: match.rect.width,
            height: match.rect.height
        )
        let boxRect = flippedRect.insetBy(dx: -3, dy: -3)
        if let blurred = blurredImage {
            context.saveGState()
            context.clip(to: boxRect)
            context.draw(blurred, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.restoreGState()
        } else if redact {
            context.setFillColor(color)
            context.fill(boxRect)
        } else {
            context.stroke(boxRect)
        }
    }

    return context.makeImage()
}

// MARK: - Save and Open

/// Resolve the output URL for a screenshot PNG given the -o flag value.
func resolveOutputURL(outputPath: String?, defaultFilename: String) -> URL {
    guard let path = outputPath else {
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(defaultFilename)
    }
    let expanded = NSString(string: path).expandingTildeInPath
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
        return URL(fileURLWithPath: expanded).appendingPathComponent(defaultFilename)
    }
    return URL(fileURLWithPath: expanded)
}

/// Resolve the output URL for the debug (-s) image: always `defaultFilename`,
/// placed in the same directory the annotated PNG would be written to.
func resolveDebugOutputURL(outputPath: String?, defaultFilename: String) -> URL {
    return resolveOutputURL(outputPath: outputPath, defaultFilename: defaultFilename)
        .deletingLastPathComponent()
        .appendingPathComponent(defaultFilename)
}

/// Save a CGImage as PNG to the given URL and return it.
func savePNG(_ image: CGImage, to url: URL) throws -> URL {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "mac-screen-search", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
    }

    CGImageDestinationAddImage(dest, image, nil)

    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "mac-screen-search", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Failed to write PNG"])
    }

    return url
}

/// Detect the UTType of an image file from its content, falling back to the file extension.
func imageUTType(for url: URL) -> UTType? {
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
       let uti = CGImageSourceGetType(source) as String? {
        return UTType(uti)
    }
    return UTType(filenameExtension: url.pathExtension)
}

/// Load any image format supported by CGImageSource and return a CGImage.
func loadImage(from url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw NSError(domain: "mac-screen-search", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot read image: \(url.path)"])
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "mac-screen-search", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot decode image: \(url.path)"])
    }
    return image
}

/// Save a CGImage back to a URL in the given format.
func saveImage(_ image: CGImage, to url: URL, type: UTType) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, type.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "mac-screen-search", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination for \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "mac-screen-search", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Failed to write image: \(url.path)"])
    }
}

// MARK: - Glob

/// Expand a flat file glob pattern (no directory recursion) and return matching
/// file URLs sorted alphabetically.  Supports `~` expansion in the directory portion.
func expandGlob(_ pattern: String) -> [URL] {
    let fm = FileManager.default

    // Resolve the directory and filename pattern
    let nsPath = NSString(string: pattern)
    var directory = nsPath.deletingLastPathComponent
    let filenamePattern = nsPath.lastPathComponent

    if directory.isEmpty {
        directory = fm.currentDirectoryPath
    } else {
        directory = NSString(string: directory).expandingTildeInPath
    }

    guard let contents = try? fm.contentsOfDirectory(atPath: directory) else {
        return []
    }

    let predicate = NSPredicate(format: "SELF LIKE %@", filenamePattern)
    let matched = contents.filter { predicate.evaluate(with: $0) }

    return matched.sorted().map { name in
        URL(fileURLWithPath: directory).appendingPathComponent(name)
    }
}

/// Open a file in the macOS Preview application.
func openInPreview(_ url: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "Preview", url.path]
    try? process.run()
}

// MARK: - Caps Lock (commented out for later)

/*
/// Event tap callback that fires on modifier key changes.
func eventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .flagsChanged {
        // Caps Lock is modifier flag bit 16 (mask 0x10000 = 65536)
        if event.flags.contains(.maskAlphaShift) {
            // trigger capture
        }
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon = refcon {
            let machPort = Unmanaged<CFMachPort>.fromOpaque(refcon)
                .takeUnretainedValue()
            CGEvent.tapEnable(tap: machPort, enable: true)
        }
    }

    return Unmanaged.passRetained(event)
}
*/

// MARK: - Output

/// Print a progress/status message.  In list mode (-l) it goes to stderr so that
/// stdout carries only the tab-separated match data.
func printStatus(_ message: String, listOnly: Bool) {
    if listOnly {
        fputs("\(message)\n", stderr)
    } else {
        print(message)
    }
}

/// Format a match as tab-separated `text, x, y, width, height` with each
/// coordinate rounded to the nearest pixel.
func matchFields(_ match: TextMatch) -> String {
    let r = match.rect
    let values = [r.origin.x, r.origin.y, r.width, r.height].map { String(Int($0.rounded())) }
    return ([match.text] + values).joined(separator: "\t")
}

/// Column names matching `matchFields`, for the list-mode header row.
let matchFieldsHeader = "text\tx\ty\twidth\theight"

// MARK: - Hints

/// Build hints for a screenshot-mode search that found nothing: suggest -m when
/// other connected monitors were not searched, and -s when the searched image was
/// not saved.  Returns an empty array when there is nothing useful to suggest.
func noMatchHints(monitorSelection: String?, totalDisplays: Int, savedSearched: Bool) -> [String] {
    var hints: [String] = []
    if monitorSelection != "all" && totalDisplays > 1 {
        let searched = monitorSelection.flatMap { Int($0) } ?? 1
        hints.append("Hint: searched monitor \(searched) of \(totalDisplays); use -m <n> or -m all if the text is on another screen.")
    }
    if !savedSearched {
        hints.append("Hint: use -s to save the searched image and see what OCR actually saw.")
    }
    return hints
}

// MARK: - Process Files

/// Process a list of image files: perform OCR on each, annotate or redact matches,
/// overwrite in-place preserving the original format, and restore the original
/// modification time.  Returns 0 on success or 1 if any file produced an error.
func processFiles(_ files: [URL], searchTerms: [String], redact: Bool, blurPercent: Int? = nil, enhanced: Bool = false, maxDistance: Int? = nil, wholeWord: Bool = false, listOnly: Bool = false, color: CGColor = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)) -> Int32 {
    let fm = FileManager.default
    var updatedCount = 0
    var errorCount = 0
    var listHeaderPrinted = false

    for fileURL in files {
        let path = fileURL.path

        // Capture original modification time
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let originalMtime = attrs[.modificationDate] as? Date else {
            fputs("Warning: cannot read attributes of \(path), skipping\n", stderr)
            errorCount += 1
            continue
        }

        // Detect original image format
        guard let utType = imageUTType(for: fileURL) else {
            fputs("Warning: cannot determine image type of \(path), skipping\n", stderr)
            errorCount += 1
            continue
        }

        // Load the image
        let image: CGImage
        do {
            image = try loadImage(from: fileURL)
        } catch {
            fputs("Warning: \(error.localizedDescription), skipping\n", stderr)
            errorCount += 1
            continue
        }

        // OCR and find matches
        let matches: [TextMatch]
        do {
            matches = try findMatches(in: ocrInput(image, enhanced: enhanced), searchTerms: searchTerms,
                                      enhanced: enhanced, maxDistance: maxDistance,
                                      wholeWord: wholeWord)
        } catch {
            fputs("Warning: OCR failed on \(path): \(error.localizedDescription), skipping\n", stderr)
            errorCount += 1
            continue
        }

        if matches.isEmpty {
            continue
        }

        if listOnly {
            if !listHeaderPrinted {
                print("file\t\(matchFieldsHeader)")
                listHeaderPrinted = true
            }
            for match in matches {
                print("\(path)\t\(matchFields(match))")
            }
            updatedCount += 1
            continue
        }

        // Annotate
        guard let annotated = annotateImage(image, matches: matches, redact: redact, blurPercent: blurPercent, color: color, lineThickness: lineThickness) else {
            fputs("Warning: failed to annotate \(path), skipping\n", stderr)
            errorCount += 1
            continue
        }

        // Overwrite in-place
        do {
            try saveImage(annotated, to: fileURL, type: utType)
        } catch {
            fputs("Warning: \(error.localizedDescription), skipping\n", stderr)
            errorCount += 1
            continue
        }

        // Restore original modification time
        do {
            try fm.setAttributes([.modificationDate: originalMtime], ofItemAtPath: path)
        } catch {
            fputs("Warning: could not restore mtime on \(path): \(error.localizedDescription)\n", stderr)
        }

        let count = matches.count
        print("\(path): \(count) match\(count == 1 ? "" : "es")")
        updatedCount += 1
    }

    let verb = listOnly ? "matched" : "updated"
    printStatus("\n\(updatedCount) file\(updatedCount == 1 ? "" : "s") \(verb), \(errorCount) error\(errorCount == 1 ? "" : "s")", listOnly: listOnly)
    return errorCount > 0 ? 1 : 0
}

// MARK: - Main

let programName = "mac-screen-search"
let programVersion = "v1.7.0"
let programURL = "https://github.com/jftuga/mac-screen-search"

var redact = false
var blurPercent: Int? = nil
var enhanced = false
var fileGlob: String? = nil
var maxDistance: Int? = nil
var colorName: String = "red"
var noOpen = false
var outputPath: String? = nil
var monitorSelection: String? = nil
var listOnly = false
var captureDelay: Double = 2.0
var wholeWord = false
var delimiter: String = "|"
var lineThickness: CGFloat = 4.0
var saveSearched = false
var args = Array(CommandLine.arguments.dropFirst())

// Parse -v flag (version)
if args.contains("-v") || args.contains("--version") {
    print("\(programName) \(programVersion)")
    print(programURL)
    exit(0)
}

// Parse -h flag (help) or no arguments
if args.isEmpty || args.contains("-h") || args.contains("--help") {
    print("Usage: mac-screen-search [-r] [-b <pct>] [-e] [-d <dist>] [-c <color>] [-T <width>]")
    print("       [-n] [-o <path>] [-m <n|all>] [-M] [-l] [-t <secs>] [-w] [-D <delim>]")
    print("       [-s] [-v] <search-term> [-f <glob>]")
    print("  -r             Redact (fill) matched regions instead of outlining them")
    print("  -b <percent>   Blur matched regions (1-100); mutually exclusive with -r")
    print("  -e             Enhanced OCR (preprocess image + check multiple candidates)")
    print("  -d <dist>      Fuzzy match using Levenshtein distance threshold")
    print("  -c <color>     Rectangle color (default: red)")
    print("                 Available: \(namedColors.keys.sorted().joined(separator: ", "))")
    print("  -f <glob>      Process image files matching glob instead of capturing screen")
    print("  -n             Do not open the result in Preview (screenshot mode)")
    print("  -o <path>      Output directory or file path for the screenshot PNG")
    print("  -m <n|all>     Capture monitor n (1-based) or all monitors")
    print("  -M             List connected monitors and exit")
    print("  -l             List matches (text and coordinates) without annotating")
    print("  -t <seconds>   Capture delay in seconds (default: 2; 0 for immediate)")
    print("  -w             Whole-word matching (word boundaries required)")
    print("  -D <delim>     Delimiter for multiple search terms (default: |)")
    print("  -T <width>     Line thickness for outlines (default: 4)")
    print("  -s             Also save the unannotated image that OCR searched, for debugging")
    print("                 (preprocessed version when -e is set; screenshot mode only)")
    print("  -h             Print this help and exit")
    print("  -v             Print version and exit")
    exit(0)
}

// Parse -M flag (list monitors and exit)
if args.contains("-M") {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            let content = try await SCShareableContent.current
            let displays = content.displays
            if displays.isEmpty {
                fputs("No displays found\n", stderr)
            } else {
                var entries: [(index: Int, logical: String, pixel: String, displayID: UInt32)] = []
                for (i, d) in displays.enumerated() {
                    let px = nativePixelSize(of: d)
                    entries.append((i + 1, "\(d.width)x\(d.height)", "\(px.width)x\(px.height)", d.displayID))
                }
                let maxLogical = entries.map { $0.logical.count }.max() ?? 0
                let maxPixel = entries.map { $0.pixel.count }.max() ?? 0
                for e in entries {
                    let logPad = e.logical.padding(toLength: maxLogical, withPad: " ", startingAt: 0)
                    let pxPad = e.pixel.padding(toLength: maxPixel, withPad: " ", startingAt: 0)
                    print("Monitor \(e.index): \(logPad) (\(pxPad) px) [displayID: \(e.displayID)]")
                }
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

// Parse -r flag
if let idx = args.firstIndex(of: "-r") {
    redact = true
    args.remove(at: idx)
}

// Parse -b <percent> flag (blur matched regions)
if let idx = args.firstIndex(of: "-b") {
    guard idx + 1 < args.count, let pct = Int(args[idx + 1]), pct >= 1, pct <= 100 else {
        fputs("Error: -b requires an integer argument between 1 and 100\n", stderr)
        exit(1)
    }
    blurPercent = pct
    args.removeSubrange(idx...idx + 1)
}

if redact && blurPercent != nil {
    fputs("Error: -r and -b are mutually exclusive\n", stderr)
    exit(1)
}

// Parse -e flag (enhanced OCR: preprocessing + multi-candidate recognition)
if let idx = args.firstIndex(of: "-e") {
    enhanced = true
    args.remove(at: idx)
}

// Parse -d <distance> flag (fuzzy matching via Levenshtein distance)
if let idx = args.firstIndex(of: "-d") {
    guard idx + 1 < args.count, let dist = Int(args[idx + 1]), dist >= 0 else {
        fputs("Error: -d requires a non-negative integer argument\n", stderr)
        exit(1)
    }
    maxDistance = dist
    args.removeSubrange(idx...idx + 1)
}

// Parse -c <color> flag
if let idx = args.firstIndex(of: "-c") {
    guard idx + 1 < args.count else {
        fputs("Error: -c requires a color name argument\n", stderr)
        fputs("Available colors: \(namedColors.keys.sorted().joined(separator: ", "))\n", stderr)
        exit(1)
    }
    colorName = args[idx + 1]
    args.removeSubrange(idx...idx + 1)
}

// Parse -f <glob> flag
if let idx = args.firstIndex(of: "-f") {
    guard idx + 1 < args.count else {
        fputs("Error: -f requires a glob pattern argument\n", stderr)
        exit(1)
    }
    fileGlob = args[idx + 1]
    args.removeSubrange(idx...idx + 1)
}

// Parse -n flag (no-open: skip opening Preview)
if let idx = args.firstIndex(of: "-n") {
    noOpen = true
    args.remove(at: idx)
}

// Parse -o <path> flag (output path)
if let idx = args.firstIndex(of: "-o") {
    guard idx + 1 < args.count else {
        fputs("Error: -o requires a path argument\n", stderr)
        exit(1)
    }
    outputPath = args[idx + 1]
    args.removeSubrange(idx...idx + 1)
}

// Parse -m <n|all> flag (monitor selection)
if let idx = args.firstIndex(of: "-m") {
    guard idx + 1 < args.count else {
        fputs("Error: -m requires a monitor index (1-based) or \"all\"\n", stderr)
        exit(1)
    }
    let val = args[idx + 1]
    if val != "all" {
        guard let n = Int(val), n >= 1 else {
            fputs("Error: -m requires a positive integer or \"all\"\n", stderr)
            exit(1)
        }
        _ = n
    }
    monitorSelection = val
    args.removeSubrange(idx...idx + 1)
}

// Parse -l flag (list matches only, no annotation)
if let idx = args.firstIndex(of: "-l") {
    listOnly = true
    args.remove(at: idx)
}

// Parse -t <seconds> flag (capture delay)
if let idx = args.firstIndex(of: "-t") {
    guard idx + 1 < args.count, let secs = Double(args[idx + 1]), secs >= 0 else {
        fputs("Error: -t requires a non-negative number (seconds)\n", stderr)
        exit(1)
    }
    captureDelay = secs
    args.removeSubrange(idx...idx + 1)
}

// Parse -w flag (whole word matching)
if let idx = args.firstIndex(of: "-w") {
    wholeWord = true
    args.remove(at: idx)
}

// Parse -D <delimiter> flag (multi-term delimiter)
if let idx = args.firstIndex(of: "-D") {
    guard idx + 1 < args.count else {
        fputs("Error: -D requires a delimiter string argument\n", stderr)
        exit(1)
    }
    delimiter = args[idx + 1]
    if delimiter.isEmpty {
        fputs("Error: -D delimiter must not be empty\n", stderr)
        exit(1)
    }
    args.removeSubrange(idx...idx + 1)
}

// Parse -T <width> flag (line thickness)
if let idx = args.firstIndex(of: "-T") {
    guard idx + 1 < args.count, let width = Double(args[idx + 1]), width > 0 else {
        fputs("Error: -T requires a positive number\n", stderr)
        exit(1)
    }
    lineThickness = CGFloat(width)
    args.removeSubrange(idx...idx + 1)
}

// Parse -s flag (save the unannotated image passed to OCR, for debugging)
if let idx = args.firstIndex(of: "-s") {
    saveSearched = true
    args.remove(at: idx)
}

// Validate flag combinations
if fileGlob != nil {
    if saveSearched {
        fputs("Error: -s is not supported in file glob mode\n", stderr)
        exit(1)
    }
    if outputPath != nil {
        fputs("Error: -o is not supported in file glob mode\n", stderr)
        exit(1)
    }
    if monitorSelection != nil {
        fputs("Error: -m is not supported in file glob mode\n", stderr)
        exit(1)
    }
}

if listOnly && (redact || blurPercent != nil) {
    fputs("Error: -l is incompatible with -r and -b (no annotation is produced)\n", stderr)
    exit(1)
}

if monitorSelection == "all", let path = outputPath {
    let expanded = NSString(string: path).expandingTildeInPath
    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) || !isDir.boolValue {
        fputs("Error: -o must specify a directory when used with -m all\n", stderr)
        exit(1)
    }
}

if let sel = monitorSelection, sel != "all", let index = Int(sel) {
    let semaphore = DispatchSemaphore(value: 0)
    var displayCount = 0
    Task {
        if let content = try? await SCShareableContent.current {
            displayCount = content.displays.count
        }
        semaphore.signal()
    }
    semaphore.wait()
    if index > displayCount {
        fputs("Error: monitor index \(index) out of range (1-\(displayCount) available)\n", stderr)
        exit(1)
    }
}

guard args.count == 1 else {
    fputs("Error: expected exactly one search term; got \(args.count == 0 ? "none" : "\(args.count): \(args.joined(separator: " "))")\n", stderr)
    fputs("Run with -h for usage.\n", stderr)
    exit(1)
}

let searchTerms = args[0].components(separatedBy: delimiter).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
if searchTerms.isEmpty {
    fputs("Error: no non-empty search terms found after splitting by delimiter \"\(delimiter)\"\n", stderr)
    exit(1)
}
let termsDisplay = searchTerms.map { "\"\($0)\"" }.joined(separator: ", ")

guard let annotationColor = resolveColor(colorName) else {
    fputs("Error: unknown color \"\(colorName)\"\n", stderr)
    fputs("Available colors: \(namedColors.keys.sorted().joined(separator: ", "))\n", stderr)
    exit(1)
}

if let glob = fileGlob {
    // File glob mode: process matching files
    let files = expandGlob(glob)
    if files.isEmpty {
        fputs("No files matched: \(glob)\n", stderr)
        exit(1)
    }
    printStatus("Processing \(files.count) file\(files.count == 1 ? "" : "s") matching \"\(glob)\" for \(termsDisplay)", listOnly: listOnly)
    let code = processFiles(files, searchTerms: searchTerms, redact: redact, blurPercent: blurPercent,
                            enhanced: enhanced, maxDistance: maxDistance, wholeWord: wholeWord,
                            listOnly: listOnly, color: annotationColor)
    exit(code)
} else {
    // Screenshot mode
    printStatus("Searching for: \(termsDisplay)", listOnly: listOnly)
    if captureDelay > 0 {
        let delayStr = captureDelay == Double(Int(captureDelay)) ? String(Int(captureDelay)) : String(captureDelay)
        printStatus("Capturing screen in \(delayStr) second\(captureDelay == 1.0 ? "" : "s")...", listOnly: listOnly)
        Thread.sleep(forTimeInterval: captureDelay)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        do {
            let (displays, totalDisplays) = try await getDisplays(selection: monitorSelection)
            var listHeaderPrinted = false
            var anyMatches = false

            for (monitorNumber, display) in displays {
                let screenshot = try await captureScreenshot(display: display)
                let displayLabel = displays.count > 1 ? " (monitor \(monitorNumber))" : ""
                printStatus("Screenshot captured\(displayLabel) (\(screenshot.width)x\(screenshot.height))", listOnly: listOnly)

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd.HHmmss"
                let timestamp = formatter.string(from: Date())
                let monitorSuffix = displays.count > 1 ? "--monitor\(monitorNumber)" : ""
                let baseName = "screenshot--\(timestamp)\(monitorSuffix)"

                let searchedImage = ocrInput(screenshot, enhanced: enhanced)

                // Save before OCR so the image exists even when nothing matches
                if saveSearched {
                    let debugURL = resolveDebugOutputURL(outputPath: outputPath, defaultFilename: "\(baseName)--searched.png")
                    let savedDebugURL = try savePNG(searchedImage, to: debugURL)
                    printStatus("Saved searched image: \(savedDebugURL.path)", listOnly: listOnly)
                }

                let matches = try findMatches(in: searchedImage, searchTerms: searchTerms,
                                              enhanced: enhanced, maxDistance: maxDistance,
                                              wholeWord: wholeWord)

                if matches.isEmpty {
                    printStatus("No matches found for \(termsDisplay)\(displayLabel)", listOnly: listOnly)
                    continue
                }

                anyMatches = true
                printStatus("Found \(matches.count) match\(matches.count == 1 ? "" : "es")\(displayLabel)", listOnly: listOnly)

                if listOnly {
                    if !listHeaderPrinted {
                        print("monitor\t\(matchFieldsHeader)")
                        listHeaderPrinted = true
                    }
                    for match in matches {
                        print("\(monitorNumber)\t\(matchFields(match))")
                    }
                    continue
                }

                guard let annotated = annotateImage(screenshot, matches: matches, redact: redact, blurPercent: blurPercent, color: annotationColor, lineThickness: lineThickness) else {
                    fputs("Error: failed to annotate image\(displayLabel)\n", stderr)
                    exitCode = 1
                    continue
                }

                let url = resolveOutputURL(outputPath: outputPath, defaultFilename: "\(baseName).png")
                let savedURL = try savePNG(annotated, to: url)
                print("Saved: \(savedURL.path)")

                if !noOpen {
                    openInPreview(savedURL)
                }
            }

            if !anyMatches {
                fflush(stdout)  // keep hints after stdout output when piped
                for hint in noMatchHints(monitorSelection: monitorSelection, totalDisplays: totalDisplays, savedSearched: saveSearched) {
                    fputs("\(hint)\n", stderr)
                }
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exitCode = 1
        }
        semaphore.signal()
    }

    semaphore.wait()
    exit(exitCode)
}
