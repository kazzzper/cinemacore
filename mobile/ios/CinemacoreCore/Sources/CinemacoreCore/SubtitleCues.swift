import Foundation

/// One WebVTT cue.
///
/// Times are seconds from the start of the media. The range is half-open —
/// `[start, end)` — which is what the player's overlay assumes when it decides
/// what to draw at a frame boundary.
public struct SubtitleCue: Hashable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A parsed WebVTT document, queried once per frame by the player overlay.
///
/// `AVPlayer` renders side-loaded captions itself only when the media is
/// rebuilt into a composition, so the app draws the active cue in its own
/// view instead and this type answers "what is on screen now". Parsing is the
/// part with the edge cases, so it lives here where the host `swift test` can
/// cover it without a device.
public struct SubtitleDocument: Sendable {
    /// The cues, sorted by start time.
    public let cues: [SubtitleCue]

    /// The running maximum `end` up to each cue index.
    ///
    /// Precomputed so ``activeCue(at:)`` can prove a gap with one comparison
    /// instead of walking the whole document.
    private let maxEnd: [Double]

    /// Parses WebVTT text, tolerating the malformed files providers serve.
    public init(webVTT text: String) {
        let parsed = Self.parse(text)
        cues = parsed.cues
        maxEnd = parsed.maxEnd
    }

    /// The cue covering `time`, or `nil` in a gap.
    ///
    /// A binary search rather than a scan: a feature film carries a few thousand
    /// cues and this is asked four times a second. The search finds the last cue
    /// that starts at or before `time`; `maxEnd` then rejects the common case (a
    /// gap, where nothing before `time` reaches it) with a single comparison and
    /// the walk back only continues while an earlier cue could still be running —
    /// one step for the non-overlapping cues that real WebVTT files contain.
    ///
    /// Overlapping cues are legal in WebVTT. When `time` falls inside more than
    /// one, the cue that starts last wins.
    public func activeCue(at time: Double) -> SubtitleCue? {
        guard !cues.isEmpty else { return nil }

        var low = 0
        var high = cues.count - 1
        var candidate = -1
        while low <= high {
            let middle = low + (high - low) / 2
            if cues[middle].start <= time {
                candidate = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }

        guard candidate >= 0, maxEnd[candidate] > time else { return nil }

        // `maxEnd` is non-decreasing, so its lower bound is the earliest cue
        // that can still be running; the scan never reaches past it.
        // Named apart from the search above: both loops are binary searches and
        // re-declaring `low`/`high` in one scope does not compile.
        var floorLow = 0
        var floorHigh = candidate
        var floor = candidate
        while floorLow <= floorHigh {
            let middle = floorLow + (floorHigh - floorLow) / 2
            if maxEnd[middle] > time {
                floor = middle
                floorHigh = middle - 1
            } else {
                floorLow = middle + 1
            }
        }

        var index = candidate
        while index >= floor {
            // Every index in `floor...candidate` starts at or before `time`, so
            // containment is decided by the end alone.
            if time < cues[index].end { return cues[index] }
            index -= 1
        }
        return nil
    }

    // MARK: - Parsing

    private static func parse(_ text: String) -> (cues: [SubtitleCue], maxEnd: [Double]) {
        var cues: [SubtitleCue] = []

        for (index, block) in blocks(in: text).enumerated() {
            var lines = block
            if index == 0, let first = lines.first, isKeyword(first, "WEBVTT") {
                // Header metadata (`Kind`, `Language`, `X-TIMESTAMP-MAP`) shares
                // this block when the file omits the blank line after the
                // signature. Only the signature line is dropped: anything else
                // here is either metadata (no timeline, so the block is skipped
                // below) or the first cue.
                lines.removeFirst()
            }
            guard let first = lines.first,
                  !isKeyword(first, "NOTE"),
                  !isKeyword(first, "STYLE"),
                  !isKeyword(first, "REGION") else { continue }

            // Everything before the timeline is the optional cue identifier.
            guard let timelineIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let cue = cue(from: lines[timelineIndex], text: lines[(timelineIndex + 1)...])
            else { continue }

            cues.append(cue)
        }

        // A start/end tie-break keeps the order deterministic where `sorted` is
        // not guaranteed stable, so the same document always yields the same
        // sequence.
        let sorted = cues.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var maxEnd: [Double] = []
        maxEnd.reserveCapacity(sorted.count)
        var running = -Double.infinity
        for cue in sorted {
            running = max(running, cue.end)
            maxEnd.append(running)
        }
        return (sorted, maxEnd)
    }

    /// Splits on blank lines, the separator WebVTT uses between its header,
    /// comment, style and cue blocks.
    private static func blocks(in text: String) -> [[String]] {
        var normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalised.hasPrefix("\u{FEFF}") { normalised.removeFirst() }

        var blocks: [[String]] = []
        var current: [String] = []
        for line in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
            } else {
                current.append(String(line))
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    /// True when `line` is the keyword or the keyword plus arguments, so a cue
    /// identifier such as `NOTES` is not mistaken for a `NOTE` block.
    private static func isKeyword(_ line: String, _ keyword: String) -> Bool {
        guard line.hasPrefix(keyword) else { return false }
        return line.count == keyword.count || line.dropFirst(keyword.count).first?.isWhitespace == true
    }

    private static func cue(from timeline: String, text: some Collection<String>) -> SubtitleCue? {
        let halves = timeline.components(separatedBy: "-->")
        guard halves.count == 2,
              let start = seconds(in: halves[0]),
              let end = seconds(in: halves[1]),
              // A cue that ends where it starts can never be on screen.
              end > start
        else { return nil }

        let body = text.joined(separator: "\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SubtitleCue(start: start, end: end, text: body)
    }

    /// The leading timestamp of one side of a timeline, ignoring the cue
    /// settings (`align:start position:10%`) that may trail it.
    private static func seconds(in raw: String) -> Double? {
        guard let stamp = raw.split(separator: " ", omittingEmptySubsequences: true).first else {
            return nil
        }
        return seconds(stamp)
    }

    /// Parses `HH:MM:SS.mmm` or the short `MM:SS.mmm`.
    ///
    /// A comma is accepted in place of the period because comma-separated
    /// timestamps reach this parser from files that claim to be WebVTT. The
    /// sub-second field is required: a stamp without one cannot be placed, and
    /// dropping it is better than guessing a frame.
    private static func seconds(_ stamp: some StringProtocol) -> Double? {
        let fields = stamp
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }

        let fraction = fields[fields.count - 1].split(separator: ".", omittingEmptySubsequences: false)
        guard fraction.count == 2,
              fraction[0].count == 2,
              fraction[1].count == 3,
              fraction[0].allSatisfy(\.isNumber),
              fraction[1].allSatisfy(\.isNumber),
              let wholeSeconds = Double(fraction[0]),
              let milliseconds = Double(fraction[1])
        else { return nil }

        let minuteField = fields[fields.count - 2]
        guard minuteField.count == 2,
              minuteField.allSatisfy(\.isNumber),
              let minutes = Double(minuteField)
        else { return nil }

        var hours = 0.0
        if fields.count == 3 {
            let hourField = fields[0]
            guard !hourField.isEmpty, hourField.allSatisfy(\.isNumber), let parsed = Double(hourField) else {
                return nil
            }
            hours = parsed
        }

        guard wholeSeconds < 60, minutes < 60 else { return nil }
        return hours * 3600 + minutes * 60 + wholeSeconds + milliseconds / 1000
    }
}
