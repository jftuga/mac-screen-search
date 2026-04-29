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
//   - Monitor selection (-m) and listing (-M) for multi-display setups
//   - List mode (-l): prints match text and coordinates without annotation
//   - Multi-term search via configurable delimiter (-D, default: |)
//   - Output path control (-o), no-preview mode (-n), configurable delay (-t)
//   - Help (-h) and version (-v) flags

import Cocoa
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: - Screenshot

/// Return the displays to capture based on the monitor selection flag.
func getDisplays(selection: String?) async throws -> [SCDisplay] {
    let content = try await SCShareableContent.current
    let allDisplays = content.displays
    guard !allDisplays.isEmpty else {
        throw NSError(domain: "mac-screen-search", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "No display found"])
    }

    guard let sel = selection else {
        return [allDisplays[0]]
    }

    if sel == "all" {
        return allDisplays
    }

    guard let index = Int(sel), index >= 1, index <= allDisplays.count else {
        throw NSError(domain: "mac-screen-search", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Monitor index \(sel) out of range (1-\(allDisplays.count) available)"])
    }
    return [allDisplays[index - 1]]
}

/// Capture a screenshot of the given display at Retina resolution.
func captureScreenshot(display: SCDisplay) async throws -> CGImage {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = display.width * 2  // Retina
    config.height = display.height * 2
    config.showsCursor = false

    return try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
}

// MARK: - Levenshtein Distance

/// Compute the Levenshtein (edit) distance between two strings.
func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
    let a = Array(s1.unicodeScalars)
    let b = Array(s2.unicodeScalars)
    let m = a.count
    let n = b.count
    if m == 0 { return n }
    if n == 0 { return m }

    var prev = Array(0...n)
    var curr = Array(repeating: 0, count: n + 1)

    for i in 1...m {
        curr[0] = i
        for j in 1...n {
            if a[i-1] == b[j-1] {
                curr[j] = prev[j-1]
            } else {
                curr[j] = 1 + min(prev[j], curr[j-1], prev[j-1])
            }
        }
        swap(&prev, &curr)
    }
    return prev[n]
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

// MARK: - OCR

/// A single match with its bounding box in image pixel coordinates.
struct TextMatch {
    let text: String
    let rect: CGRect
}

/// Perform OCR on the image and return bounding rects for all occurrences of the
/// search terms (case-insensitive).  OCR runs once; each term is matched against
/// the same recognized text.  When `enhanced` is true, the image is preprocessed
/// and multiple OCR candidates are checked.  When `maxDistance` is set, fuzzy
/// matching via Levenshtein distance is used instead of exact matching.
func findMatches(in image: CGImage, searchTerms: [String], enhanced: Bool = false, maxDistance: Int? = nil, wholeWord: Bool = false) throws -> [TextMatch] {
    let ocrImage = enhanced ? preprocessImage(image) : image

    let handler = VNImageRequestHandler(cgImage: ocrImage)
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
                    let searchLen = lowerSearch.count
                    let textLen = lowerFull.count
                    guard textLen >= searchLen else { continue }

                    for winStart in 0...(textLen - searchLen) {
                        let sIdx = lowerFull.index(lowerFull.startIndex, offsetBy: winStart)
                        let eIdx = lowerFull.index(sIdx, offsetBy: searchLen)
                        let window = String(lowerFull[sIdx..<eIdx])

                        if levenshteinDistance(window, lowerSearch) <= maxDist {
                            if wholeWord {
                                let before = winStart > 0 ? lowerFull[lowerFull.index(lowerFull.startIndex, offsetBy: winStart - 1)] : nil
                                let after = winStart + searchLen < textLen ? lowerFull[lowerFull.index(lowerFull.startIndex, offsetBy: winStart + searchLen)] : nil
                                let isWord: (Character?) -> Bool = { c in guard let c = c else { return false }; return c.isLetter || c.isNumber || c == "_" }
                                if isWord(before) || isWord(after) { continue }
                            }

                            let origStart = fullString.index(fullString.startIndex, offsetBy: winStart)
                            let origEnd = fullString.index(origStart, offsetBy: searchLen)
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
                   color: CGColor = CGColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)) -> CGImage? {
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
    context.setLineWidth(4.0)

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
            matches = try findMatches(in: image, searchTerms: searchTerms,
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
                print("file\ttext\tx\ty\twidth\theight")
                listHeaderPrinted = true
            }
            for match in matches {
                print("\(path)\t\(match.text)\t\(Int(match.rect.origin.x))\t\(Int(match.rect.origin.y))\t\(Int(match.rect.width))\t\(Int(match.rect.height))")
            }
            updatedCount += 1
            continue
        }

        // Annotate
        guard let annotated = annotateImage(image, matches: matches, redact: redact, blurPercent: blurPercent, color: color) else {
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

    print("\n\(updatedCount) file\(updatedCount == 1 ? "" : "s") updated, \(errorCount) error\(errorCount == 1 ? "" : "s")")
    return errorCount > 0 ? 1 : 0
}

// MARK: - Main

let programName = "mac-screen-search"
let programVersion = "v1.3.0"
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
var args = Array(CommandLine.arguments.dropFirst())

// Parse -v flag (version)
if args.contains("-v") || args.contains("--version") {
    print("\(programName) \(programVersion)")
    print(programURL)
    exit(0)
}

// Parse -h flag (help) or no arguments
if args.isEmpty || args.contains("-h") || args.contains("--help") {
    print("Usage: mac-screen-search [-r] [-b <pct>] [-e] [-d <dist>] [-c <color>] [-v]")
    print("       [-n] [-o <path>] [-m <n|all>] [-M] [-l] [-t <secs>] [-w] [-D <delim>]")
    print("       <search-term> [-f <glob>]")
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
                    entries.append((i + 1, "\(d.width)x\(d.height)", "\(d.width * 2)x\(d.height * 2)", d.displayID))
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

// Validate flag combinations
if fileGlob != nil {
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
    print("Processing \(files.count) file\(files.count == 1 ? "" : "s") matching \"\(glob)\" for \(termsDisplay)")
    let code = processFiles(files, searchTerms: searchTerms, redact: redact, blurPercent: blurPercent,
                            enhanced: enhanced, maxDistance: maxDistance, wholeWord: wholeWord,
                            listOnly: listOnly, color: annotationColor)
    exit(code)
} else {
    // Screenshot mode
    print("Searching for: \(termsDisplay)")
    if captureDelay > 0 {
        let delayStr = captureDelay == Double(Int(captureDelay)) ? String(Int(captureDelay)) : String(captureDelay)
        print("Capturing screen in \(delayStr) second\(captureDelay == 1.0 ? "" : "s")...")
        Thread.sleep(forTimeInterval: captureDelay)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        do {
            let displays = try await getDisplays(selection: monitorSelection)
            var listHeaderPrinted = false

            for (displayIndex, display) in displays.enumerated() {
                let screenshot = try await captureScreenshot(display: display)
                let displayLabel = displays.count > 1 ? " (monitor \(displayIndex + 1))" : ""
                print("Screenshot captured\(displayLabel) (\(screenshot.width)x\(screenshot.height))")

                let matches = try findMatches(in: screenshot, searchTerms: searchTerms,
                                              enhanced: enhanced, maxDistance: maxDistance,
                                              wholeWord: wholeWord)

                if matches.isEmpty {
                    print("No matches found for \(termsDisplay)\(displayLabel)")
                    continue
                }

                print("Found \(matches.count) match\(matches.count == 1 ? "" : "es")\(displayLabel)")

                if listOnly {
                    if !listHeaderPrinted {
                        print("text\tx\ty\twidth\theight")
                        listHeaderPrinted = true
                    }
                    for match in matches {
                        print("\(match.text)\t\(Int(match.rect.origin.x))\t\(Int(match.rect.origin.y))\t\(Int(match.rect.width))\t\(Int(match.rect.height))")
                    }
                    continue
                }

                guard let annotated = annotateImage(screenshot, matches: matches, redact: redact, blurPercent: blurPercent, color: annotationColor) else {
                    fputs("Error: failed to annotate image\(displayLabel)\n", stderr)
                    exitCode = 1
                    continue
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd.HHmmss"
                let timestamp = formatter.string(from: Date())
                let filename: String
                if displays.count > 1 {
                    filename = "screenshot--\(timestamp)--monitor\(displayIndex + 1).png"
                } else {
                    filename = "screenshot--\(timestamp).png"
                }

                let url = resolveOutputURL(outputPath: outputPath, defaultFilename: filename)
                let savedURL = try savePNG(annotated, to: url)
                print("Saved: \(savedURL.path)")

                if !noOpen {
                    openInPreview(savedURL)
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
