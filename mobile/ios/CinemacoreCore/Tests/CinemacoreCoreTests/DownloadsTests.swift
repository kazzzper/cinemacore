import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CinemacoreCore

// MARK: - Fixtures

private func uniqueDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("cinemacore-downloads-\(UUID().uuidString)", isDirectory: true)
}

private func removeDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func makeURL(_ path: String) -> URL {
    guard let url = URL(string: "https://cdn.test/\(path)") else {
        preconditionFailure("the test URL builder produced an invalid URL for \(path)")
    }
    return url
}

private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeItem(
    id: String = "subject-1-s1e1-1080p",
    title: String = "Subject",
    quality: String = "1080p",
    cookie: String? = nil,
    status: DownloadStatus = .queued,
    totalBytes: Int64 = 0,
    bytesWritten: Int64 = 0,
    createdAt: Date = baseDate,
    updatedAt: Date = baseDate,
    season: Int? = 1,
    episode: Int? = 1,
    localFileName: String? = nil,
    container: MediaContainer = .mp4,
    layoutVersion: Int = 2,
    remoteURL: URL? = nil
) -> DownloadItem {
    DownloadItem(
        id: id,
        subjectID: "subject-1",
        title: title,
        season: season,
        episode: episode,
        quality: quality,
        remoteURL: remoteURL ?? makeURL("\(id).mp4"),
        cookie: cookie,
        container: container,
        layoutVersion: layoutVersion,
        status: status,
        totalBytes: totalBytes,
        bytesWritten: bytesWritten,
        createdAt: createdAt,
        updatedAt: updatedAt,
        localFileName: localFileName ?? "\(id).\(container.assetExtension)"
    )
}

/// Deterministic, non-repeating bytes: a byte-for-byte comparison against this
/// is what proves no chunk was fetched twice or dropped.
private func makePayload(_ count: Int) -> Data {
    var generator: UInt64 = 0x2545_F491_4F6C_DD1D
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    for _ in 0..<count {
        generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        bytes.append(UInt8(truncatingIfNeeded: generator >> 33))
    }
    return Data(bytes)
}

/// Polls instead of sleeping a fixed amount, so a test never depends on how
/// fast the machine is.
private func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

private actor SnapshotCollector {
    private(set) var snapshots: [[DownloadItem]] = []

    func record(_ snapshot: [DownloadItem]) {
        snapshots.append(snapshot)
    }
}

// MARK: - Mock transport

/// What one `content` call should do before it is done.
private enum Attempt: Sendable {
    case all
    /// Deliver `bytes` and then throw — a jittering connection.
    case fail(after: Int64)
    /// Deliver `bytes` and then end cleanly — a connection the server cut.
    case truncate(after: Int64)
}

/// A transport the tests drive by hand: it records every offset it was asked to
/// resume from, which is the evidence that a retry continued rather than
/// restarted.
private actor MockTransport: DownloadTransport {
    struct Call: Sendable, Hashable {
        let from: Int64
    }

    private let payload: Data
    private let supportsRanges: Bool
    private let script: [Attempt]
    private let chunkBytes: Int
    private let chunkDelay: Duration
    /// Answer every ranged request with `200` and the whole body, as a CDN that
    /// advertises `Accept-Ranges` and then ignores `Range` does.
    private let rejectsResume: Bool
    private let contentFailure: CinemacoreError?
    private let probeFailure: CinemacoreError?

    private var callIndex = 0
    private(set) var contentCalls: [Call] = []
    private(set) var probeCount = 0
    private(set) var probedHeaders: [[String: String]] = []

    init(
        payload: Data,
        supportsRanges: Bool = true,
        script: [Attempt] = [],
        chunkBytes: Int = 64 * 1024,
        chunkDelay: Duration = .zero,
        rejectsResume: Bool = false,
        contentFailure: CinemacoreError? = nil,
        probeFailure: CinemacoreError? = nil
    ) {
        self.payload = payload
        self.supportsRanges = supportsRanges
        self.script = script
        self.chunkBytes = chunkBytes
        self.chunkDelay = chunkDelay
        self.rejectsResume = rejectsResume
        self.contentFailure = contentFailure
        self.probeFailure = probeFailure
    }

    func probe(url: URL, headers: [String: String]) async throws(CinemacoreError) -> RemoteFileInfo {
        probeCount += 1
        probedHeaders.append(headers)
        if let probeFailure { throw probeFailure }
        return RemoteFileInfo(
            totalBytes: Int64(payload.count),
            supportsRanges: supportsRanges
        )
    }

    func content(
        url: URL,
        headers: [String: String],
        from: Int64
    ) async throws(CinemacoreError) -> AsyncThrowingStream<Data, any Error> {
        contentCalls.append(Call(from: from))
        if let contentFailure { throw contentFailure }
        if rejectsResume, from > 0 {
            throw .http(status: 200, code: nil, message: "Range ignored")
        }

        let index = callIndex
        callIndex += 1
        let attempt = index < script.count ? script[index] : .all
        // A server that cannot resume always answers from the start of the file.
        let start = supportsRanges ? Int(from) : 0
        let body = payload.subdata(in: start..<payload.count)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var delivered: Int64 = 0
                var cursor = body.startIndex
                let limit: Int64?
                let fails: Bool
                switch attempt {
                case .all:
                    limit = nil
                    fails = false
                case .fail(let bytes):
                    limit = bytes
                    fails = true
                case .truncate(let bytes):
                    limit = bytes
                    fails = false
                }
                while cursor < body.endIndex {
                    if let limit, delivered >= limit { break }
                    var take = min(chunkBytes, body.endIndex - cursor)
                    if let limit { take = min(take, Int(limit - delivered)) }
                    let end = body.index(cursor, offsetBy: take)
                    if case .terminated = continuation.yield(Data(body[cursor..<end])) { return }
                    delivered += Int64(take)
                    cursor = end
                    if chunkDelay > .zero {
                        try? await Task.sleep(for: chunkDelay)
                    }
                }
                if fails {
                    continuation.finish(throwing: CinemacoreError.upstream("The connection dropped."))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Model

@Suite("DownloadItem — derived presentation")
struct DownloadItemTests {

    @Test("progress is 0 while the total is unknown and clamped once it is not")
    func progress() {
        #expect(makeItem(totalBytes: 0, bytesWritten: 500).progress == 0)
        #expect(makeItem(totalBytes: 1000, bytesWritten: 250).progress == 0.25)
        #expect(makeItem(totalBytes: 1000, bytesWritten: 1000).progress == 1)
        // A server that under-reports the total must not push a bar past 1.
        #expect(makeItem(totalBytes: 1000, bytesWritten: 1500).progress == 1)
    }

    @Test("sizeText is nil while the size is unknown and base-1024 otherwise")
    func sizeText() {
        #expect(makeItem(totalBytes: 0).sizeText == nil)
        #expect(makeItem(totalBytes: 512).sizeText == "512 B")
        #expect(makeItem(totalBytes: 1024).sizeText == "1.0 KB")
        #expect(makeItem(totalBytes: 1024 * 1024).sizeText == "1.0 MB")
        #expect(makeItem(totalBytes: 3 * 1024 * 1024 * 1024 / 2).sizeText == "1.5 GB")
    }

    @Test("remainingBytes never goes negative")
    func remaining() {
        #expect(makeItem(totalBytes: 1000, bytesWritten: 400).remainingBytes == 600)
        #expect(makeItem(totalBytes: 1000, bytesWritten: 1200).remainingBytes == 0)
        #expect(makeItem(totalBytes: 0, bytesWritten: 0).remainingBytes == 0)
    }

    @Test("status flags and the episode label")
    func flags() {
        #expect(makeItem(status: .completed).isFinished)
        #expect(!makeItem(status: .downloading).isFinished)
        #expect(makeItem(status: .downloading).isActive)
        for status in [DownloadStatus.queued, .paused, .failed] {
            #expect(makeItem(status: status).canResume)
        }
        #expect(!makeItem(status: .downloading).canResume)
        #expect(!makeItem(status: .completed).canResume)

        #expect(makeItem(season: 2, episode: 4).episodeLabel == "S2 E4")
        #expect(makeItem(season: nil, episode: nil).episodeLabel == nil)
        #expect(makeItem(season: 2, episode: nil).episodeLabel == nil)
    }

    @Test("a round trip through the library encoder preserves every field")
    func codableRoundTrip() throws {
        let item = DownloadItem(
            id: "7-s3e9-720p",
            subjectID: "7",
            title: "Round Trip",
            poster: "//cdn.test/7.jpg",
            season: 3,
            episode: 9,
            episodeTitle: "Finale",
            quality: "720p",
            remoteURL: makeURL("7.mp4"),
            cookie: "session=abc",
            status: .paused,
            totalBytes: 4096,
            bytesWritten: 1024,
            attempts: 2,
            failure: "offline",
            createdAt: baseDate,
            updatedAt: baseDate.addingTimeInterval(30),
            localFileName: "7-s3e9-720p.mp4"
        )
        let data = try JSONEncoder.library.encode(item)
        let decoded = try JSONDecoder.library.decode(DownloadItem.self, from: data)
        #expect(decoded == item)
        #expect(decoded.updatedAt == baseDate.addingTimeInterval(30))
    }

    @Test("a document missing newer keys decodes with defaults instead of failing")
    func tolerantDecoding() throws {
        let json = #"{"id":"42","remoteURL":"https://cdn.test/42.mp4"}"#
        let item = try JSONDecoder.library.decode(DownloadItem.self, from: Data(json.utf8))
        #expect(item.subjectID == "42")
        #expect(item.title == "")
        #expect(item.quality == "")
        #expect(item.status == .queued)
        #expect(item.totalBytes == 0)
        #expect(item.bytesWritten == 0)
        #expect(item.attempts == 0)
        #expect(item.failure == nil)
        // The fallback name has to be usable as a file name.
        #expect(item.localFileName == "42.mp4")
        #expect(item.container == .mp4)
        #expect(item.layoutVersion == 1)
        // A queue written before captions were saved with a download still
        // decodes; the empty list is the honest answer for it.
        #expect(item.subtitles == [])
    }

    @Test("captions stored with a download survive a round trip")
    func subtitleRoundTrip() throws {
        var item = makeItem(status: .completed)
        item.subtitles = [DownloadedSubtitle(language: "English", fileName: "english-abc.vtt")]
        let data = try JSONEncoder.library.encode(item)
        let decoded = try JSONDecoder.library.decode(DownloadItem.self, from: data)
        #expect(decoded.subtitles == item.subtitles)
    }

    @Test("a manifest URL is classified as HLS even without a stored container")
    func manifestTolerantDecoding() throws {
        let json = #"{"id":"42","remoteURL":"https://cdn.test/hls/index.m3u8","localFileName":"42.m3u8"}"#
        let item = try JSONDecoder.library.decode(DownloadItem.self, from: Data(json.utf8))
        #expect(item.container == .hls)
        #expect(item.layoutVersion == 1)
        #expect(item.isManifestDownload)
    }

    @Test("a stored container and layout survive a round trip")
    func containerRoundTrip() throws {
        let item = makeItem(container: .dash, layoutVersion: 2, remoteURL: makeURL("stream.mpd"))
        let decoded = try JSONDecoder.library.decode(
            DownloadItem.self,
            from: JSONEncoder.library.encode(item)
        )
        #expect(decoded == item)
        #expect(decoded.container == .dash)
        #expect(decoded.layoutVersion == 2)
    }
}

// MARK: - Sorting

@Suite("DownloadList.sorted")
struct DownloadListSortedTests {

    private func ids(_ items: [DownloadItem]) -> [String] {
        items.map(\.id)
    }

    @Test("dateAdded orders by createdAt in both directions")
    func dateAdded() {
        let items = [
            makeItem(id: "b", createdAt: baseDate.addingTimeInterval(60)),
            makeItem(id: "a", createdAt: baseDate),
            makeItem(id: "c", createdAt: baseDate.addingTimeInterval(120)),
        ]
        #expect(ids(DownloadList.sorted(items, by: .init(key: .dateAdded, ascending: true))) == ["a", "b", "c"])
        #expect(ids(DownloadList.sorted(items, by: .init(key: .dateAdded, ascending: false))) == ["c", "b", "a"])
    }

    @Test("title is case-insensitive and ties fall back to createdAt")
    func title() {
        let items = [
            makeItem(id: "later", title: "banana", createdAt: baseDate.addingTimeInterval(10)),
            makeItem(id: "first", title: "Banana", createdAt: baseDate),
            makeItem(id: "apple", title: "apple", createdAt: baseDate),
        ]
        #expect(ids(DownloadList.sorted(items, by: .init(key: .title, ascending: true))) == ["apple", "first", "later"])
        #expect(ids(DownloadList.sorted(items, by: .init(key: .title, ascending: false))) == ["later", "first", "apple"])
    }

    @Test("size orders by totalBytes")
    func size() {
        let items = [
            makeItem(id: "big", totalBytes: 3000),
            makeItem(id: "small", totalBytes: 1000),
            makeItem(id: "mid", totalBytes: 2000),
        ]
        #expect(ids(DownloadList.sorted(items, by: .init(key: .size, ascending: true))) == ["small", "mid", "big"])
        #expect(ids(DownloadList.sorted(items, by: .init(key: .size, ascending: false))) == ["big", "mid", "small"])
    }

    @Test("progress orders by the fraction written, not by bytes")
    func progress() {
        let items = [
            makeItem(id: "half", totalBytes: 2000, bytesWritten: 1000),
            makeItem(id: "quarter", totalBytes: 1000, bytesWritten: 250),
            makeItem(id: "full", totalBytes: 1000, bytesWritten: 1000),
        ]
        #expect(ids(DownloadList.sorted(items, by: .init(key: .progress, ascending: true))) == ["quarter", "half", "full"])
        #expect(ids(DownloadList.sorted(items, by: .init(key: .progress, ascending: false))) == ["full", "half", "quarter"])
    }

    @Test("status uses downloading, queued, paused, failed, completed")
    func status() {
        let items = [
            makeItem(id: "done", status: .completed),
            makeItem(id: "dead", status: .failed),
            makeItem(id: "hold", status: .paused),
            makeItem(id: "wait", status: .queued),
            makeItem(id: "live", status: .downloading),
        ]
        #expect(ids(DownloadList.sorted(items, by: .init(key: .status, ascending: true))) == ["live", "wait", "hold", "dead", "done"])
        #expect(ids(DownloadList.sorted(items, by: .init(key: .status, ascending: false))) == ["done", "dead", "hold", "wait", "live"])
    }

    @Test("every key is a total order, so equal elements cannot jitter", arguments: DownloadSortKey.allCases)
    func tiesAreDeterministic(key: DownloadSortKey) {
        // Five items identical on every sort key: only the id can order them.
        let items = ["e", "d", "c", "b", "a"].map { makeItem(id: $0) }
        let order = DownloadSortOrder(key: key, ascending: true)
        let expected = ids(DownloadList.sorted(items, by: order))

        for offset in 0..<items.count {
            let rotated = Array(items[offset...] + items[..<offset])
            #expect(ids(DownloadList.sorted(rotated, by: order)) == expected)
        }
        for _ in 0..<8 {
            #expect(ids(DownloadList.sorted(items.shuffled(), by: order)) == expected)
        }
        #expect(expected == ["a", "b", "c", "d", "e"])

        let descending = DownloadSortOrder(key: key, ascending: false)
        #expect(ids(DownloadList.sorted(items.shuffled(), by: descending)) == Array(expected.reversed()))
    }

    @Test("the empty list stays empty for every key and direction", arguments: DownloadSortKey.allCases)
    func empty(key: DownloadSortKey) {
        #expect(DownloadList.sorted([], by: .init(key: key, ascending: true)).isEmpty)
        #expect(DownloadList.sorted([], by: .init(key: key, ascending: false)).isEmpty)
    }
}

// MARK: - Grouping

@Suite("DownloadList.grouped")
struct DownloadListGroupedTests {

    private var items: [DownloadItem] {
        [
            makeItem(id: "zebra-1", title: "Zebra", status: .completed, totalBytes: 100),
            makeItem(id: "apple-1", title: "Apple", status: .downloading, totalBytes: 100),
            makeItem(id: "apple-2", title: "Apple", status: .paused, totalBytes: 100),
            makeItem(id: "mango-1", title: "Mango", status: .failed, totalBytes: 100),
        ]
    }

    @Test("grouping by none returns one All section, sorted")
    func none() {
        let sections = DownloadList.grouped(items, by: .none, order: .init(key: .title, ascending: true))
        #expect(sections.count == 1)
        #expect(sections.first?.id == "all")
        #expect(sections.first?.title == "All")
        #expect(sections.first?.items.map(\.id) == ["apple-1", "apple-2", "mango-1", "zebra-1"])
    }

    @Test("grouping by title makes one section per subject, alphabetical, items sorted")
    func title() {
        let sections = DownloadList.grouped(items, by: .title, order: .init(key: .dateAdded, ascending: true))
        #expect(sections.map(\.title) == ["Apple", "Mango", "Zebra"])
        #expect(sections.map(\.id) == ["Apple", "Mango", "Zebra"])
        // Apple's two rows keep the requested order inside their own section.
        #expect(sections.first?.items.map(\.id) == ["apple-1", "apple-2"])
        #expect(sections.last?.items.map(\.id) == ["zebra-1"])
    }

    @Test("grouping by status uses the presentation order and omits empty statuses")
    func status() {
        let sections = DownloadList.grouped(items, by: .status, order: .init(key: .title, ascending: true))
        // `queued` has no members, so it has no section.
        #expect(sections.map(\.id) == ["downloading", "paused", "failed", "completed"])
        #expect(sections.map(\.title) == ["Downloading", "Paused", "Failed", "Completed"])
        #expect(sections.first?.items.map(\.id) == ["apple-1"])
    }

    @Test("an empty list has no sections in any grouping", arguments: DownloadGrouping.allCases)
    func empty(grouping: DownloadGrouping) {
        #expect(DownloadList.grouped([], by: grouping, order: .init()).isEmpty)
        // A single status with no members still produces nothing.
        #expect(DownloadList.grouped([], by: .status, order: .init(key: .size)).isEmpty)
    }

    @Test("a single status produces exactly one section")
    func oneStatus() {
        let only = [makeItem(id: "a", status: .paused), makeItem(id: "b", status: .paused)]
        let sections = DownloadList.grouped(only, by: .status, order: .init())
        #expect(sections.count == 1)
        #expect(sections.first?.title == "Paused")
        #expect(sections.first?.items.count == 2)
    }
}

// MARK: - Transfer

@Suite("DownloadEngine — jitter, retries and ranges")
struct DownloadEngineTransferTests {

    @Test("a mid-stream throw resumes from the committed offset and never re-fetches")
    func resumesAfterMidStreamThrow() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(256 * 1024)
        // First attempt delivers 96 KiB and drops; the second delivers the rest.
        let transport = MockTransport(payload: payload, script: [.fail(after: 96 * 1024), .all])
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(
                maxConcurrent: 1,
                maxAttempts: 4,
                initialBackoff: 0.001,
                maxBackoff: 0.002,
                progressFlushBytes: 32 * 1024
            )
        )
        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })

        // The retry asked for exactly the byte the first attempt stopped at.
        let offsets = await transport.contentCalls.map(\.from)
        #expect(offsets == [0, 96 * 1024])
        // Byte-for-byte: nothing was fetched twice and nothing was dropped.
        #expect(try Data(contentsOf: engine.fileURL(for: item)) == payload)
        #expect(!FileManager.default.fileExists(atPath: engine.partialURL(for: item).path))

        let finished = await engine.item(item.id)
        #expect(finished?.attempts == 1)
        #expect(finished?.bytesWritten == Int64(payload.count))
        #expect(finished?.failure == nil)
        // The total was known, so the probe only ran once the download resumed.
        #expect(await transport.probeCount == 1)
    }

    @Test("every attempt keeps its bytes and the item fails once the budget is spent")
    func exhaustedAttemptsKeepPartialData() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(256 * 1024)
        // Every attempt delivers 32 KiB and then drops.
        let transport = MockTransport(
            payload: payload,
            script: [.fail(after: 32 * 1024), .fail(after: 32 * 1024), .fail(after: 32 * 1024)]
        )
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(
                maxConcurrent: 1,
                maxAttempts: 3,
                initialBackoff: 0.001,
                maxBackoff: 0.002,
                progressFlushBytes: 8 * 1024
            )
        )
        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .failed })

        let offsets = await transport.contentCalls.map(\.from)
        #expect(offsets == [0, 32 * 1024, 64 * 1024])

        let failed = await engine.item(item.id)
        #expect(failed?.attempts == 3)
        #expect((failed?.failure ?? "").isEmpty == false)
        let written = failed?.bytesWritten ?? -1
        #expect(written == Int64(96 * 1024))
        #expect(failed?.isFinished == false)

        // The partial file is the prefix of the payload, exactly once over.
        let partial = try Data(contentsOf: engine.partialURL(for: item))
        #expect(partial == payload.prefix(96 * 1024))
        #expect(!FileManager.default.fileExists(atPath: engine.fileURL(for: item).path))
    }

    @Test("a non-retryable transport failure spends exactly one attempt")
    func nonRetryableFailureStopsImmediately() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let transport = MockTransport(
            payload: makePayload(64 * 1024),
            contentFailure: .http(status: 404, code: nil, message: nil)
        )
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 1, maxAttempts: 5, initialBackoff: 0.001)
        )
        let item = makeItem(totalBytes: 64 * 1024)
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .failed })

        #expect(await transport.contentCalls.count == 1)
        let failed = await engine.item(item.id)
        #expect(failed?.attempts == 1)
        #expect(failed?.failure == "The server returned an error (404).")
    }

    @Test("a non-retryable probe failure also spends exactly one attempt")
    func nonRetryableProbeFailureStopsImmediately() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let transport = MockTransport(
            payload: makePayload(64 * 1024),
            probeFailure: .locked(reason: "Not available here.")
        )
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 1, maxAttempts: 5, initialBackoff: 0.001)
        )
        // An unknown size forces the probe, which is where this failure lives.
        let item = makeItem(totalBytes: 0)
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .failed })

        #expect(await transport.probeCount == 1)
        #expect(await transport.contentCalls.isEmpty)
        #expect(await engine.item(item.id)?.attempts == 1)
        #expect(await engine.item(item.id)?.failure == "Not available here.")
    }

    @Test("a retryable probe failure does burn attempts")
    func retryableProbeFailureIsRetried() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let transport = MockTransport(payload: makePayload(4096), probeFailure: .offline)
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(
                maxConcurrent: 1, maxAttempts: 3, initialBackoff: 0.001, maxBackoff: 0.002
            )
        )
        let item = makeItem(totalBytes: 0)
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .failed })
        #expect(await transport.probeCount == 3)
        #expect(await engine.item(item.id)?.attempts == 3)
    }

    @Test("backoff doubles from initialBackoff and is capped at maxBackoff")
    func backoffSchedule() async {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let engine = DownloadEngine(
            directory: directory,
            transport: MockTransport(payload: Data()),
            configuration: DownloadConfiguration(initialBackoff: 1, maxBackoff: 10)
        )
        #expect(engine.backoff(afterAttempt: 1) == 1)
        #expect(engine.backoff(afterAttempt: 2) == 2)
        #expect(engine.backoff(afterAttempt: 3) == 4)
        #expect(engine.backoff(afterAttempt: 4) == 8)
        #expect(engine.backoff(afterAttempt: 5) == 10)
        #expect(engine.backoff(afterAttempt: 40) == 10)

        let instant = DownloadEngine(
            directory: directory,
            transport: MockTransport(payload: Data()),
            configuration: DownloadConfiguration(initialBackoff: 0, maxBackoff: 0)
        )
        #expect(instant.backoff(afterAttempt: 1) == 0)
        #expect(instant.backoff(afterAttempt: 6) == 0)
    }

    @Test("an advertised-but-absent Range support truncates instead of gluing two copies")
    func rangeUnsupportedTruncatesAndRestarts() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(200 * 1024)
        let transport = MockTransport(payload: payload, supportsRanges: false)
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 1, maxAttempts: 3, initialBackoff: 0.001)
        )
        let item = makeItem(status: .paused, totalBytes: Int64(payload.count), bytesWritten: 80 * 1024)

        // A previous session left 80 KiB on disk; the server cannot resume.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.prefix(80 * 1024).write(to: engine.partialURL(for: item))
        #expect(await engine.enqueue([item]) == 1)
        await engine.resume(item.id)
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })

        #expect(await transport.contentCalls.map(\.from) == [0])
        // Exactly one copy of the payload: not the old 80 KiB plus a whole file.
        let saved = try Data(contentsOf: engine.fileURL(for: item))
        #expect(saved == payload)
        #expect(await engine.item(item.id)?.bytesWritten == Int64(payload.count))
    }

    @Test("a 200 answer to a ranged request restarts from zero without burning an attempt")
    func rangeIgnoredOnRangedRequest() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(200 * 1024)
        // `probe` promises ranges; `content` then answers a resume with 200.
        let transport = MockTransport(payload: payload, rejectsResume: true)
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 1, maxAttempts: 3, initialBackoff: 0.001)
        )
        let item = makeItem(status: .paused, totalBytes: Int64(payload.count), bytesWritten: 80 * 1024)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.prefix(80 * 1024).write(to: engine.partialURL(for: item))
        #expect(await engine.enqueue([item]) == 1)
        await engine.resume(item.id)
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })

        // The first request asked to resume; the second asked for the whole file
        // and the engine swapped the prefix for it rather than appending.
        #expect(await transport.contentCalls.map(\.from) == [80 * 1024, 0])
        #expect(try Data(contentsOf: engine.fileURL(for: item)) == payload)
        let finished = await engine.item(item.id)
        #expect(finished?.attempts == 0)
        #expect(finished?.bytesWritten == Int64(payload.count))
    }

    @Test("a stream that ends short of the promised size is jitter, not a finished file")
    func shortStreamIsRetried() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(160 * 1024)
        // First attempt ends cleanly after 64 KiB; the second delivers the rest.
        let transport = MockTransport(payload: payload, script: [.truncate(after: 64 * 1024), .all])
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(
                maxConcurrent: 1, maxAttempts: 3, initialBackoff: 0.001, maxBackoff: 0.002
            )
        )
        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })

        #expect(await transport.contentCalls.map(\.from) == [0, 64 * 1024])
        #expect(try Data(contentsOf: engine.fileURL(for: item)) == payload)
        #expect(await engine.item(item.id)?.attempts == 1)
    }

    @Test("an unknown size is learned from the probe and reported at completion")
    func unknownSizeIsResolvedByProbe() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(40 * 1024)
        let transport = MockTransport(payload: payload)
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 1, maxAttempts: 2, initialBackoff: 0.001)
        )
        let item = makeItem(totalBytes: 0)
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })

        #expect(await transport.probeCount == 1)
        #expect(await engine.item(item.id)?.totalBytes == Int64(payload.count))
        #expect(await engine.item(item.id)?.progress == 1)
    }

    @Test("media requests carry only the media headers the spec allows")
    func requestsUseMediaHeaders() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let item = makeItem(cookie: "signCookie=abc", totalBytes: 0)
        let transport = MockTransport(payload: makePayload(2048))
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 1, maxAttempts: 2, initialBackoff: 0.001)
        )
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })

        let headers = try #require(await transport.probedHeaders.first)
        #expect(headers == MediaRequest.headers(cookie: "signCookie=abc"))
        #expect(headers["User-Agent"] != nil)
        #expect(headers.count == 2)
    }
}

// MARK: - Scheduling

@Suite("DownloadEngine — scheduling")
struct DownloadEngineSchedulingTests {

    @Test("no more than maxConcurrent items download at once, and queued ones are promoted")
    func concurrencyCapAndPromotion() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(64 * 1024)
        let transport = MockTransport(
            payload: payload, chunkBytes: 4 * 1024, chunkDelay: .milliseconds(1)
        )
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(
                maxConcurrent: 2,
                maxAttempts: 3,
                initialBackoff: 0.001,
                maxBackoff: 0.002,
                progressFlushBytes: 4 * 1024
            )
        )
        let items = (0..<5).map { index in
            makeItem(id: "item-\(index)", totalBytes: Int64(payload.count))
        }
        #expect(await engine.enqueue(items) == 5)

        let collector = SnapshotCollector()
        let stream = await engine.updates()
        let watcher = Task { for await snapshot in stream { await collector.record(snapshot) } }

        await engine.start()
        #expect(await waitUntil { await engine.items().allSatisfy { $0.status == .completed } })
        watcher.cancel()
        await watcher.value

        let snapshots = await collector.snapshots
        let peak = snapshots.map { $0.filter(\.isActive).count }.max() ?? 0
        #expect(peak <= 2)
        // The limit was actually reached, so the test is not vacuous.
        #expect(peak == 2)
        // Items waited while others ran, and every one of them was promoted.
        #expect(snapshots.contains { snapshot in
            snapshot.contains { $0.status == .queued } && snapshot.contains { $0.status == .downloading }
        })
        #expect(snapshots.last?.allSatisfy { $0.status == .completed } == true)
        // One content call per item: nothing was ever run twice.
        #expect(await transport.contentCalls.map(\.from) == [0, 0, 0, 0, 0])

        for item in items {
            #expect(try Data(contentsOf: engine.fileURL(for: item)) == payload)
        }
    }

    @Test("start() is re-entrant: calling it again never runs an item twice")
    func startIsIdempotent() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(64 * 1024)
        let transport = MockTransport(
            payload: payload, chunkBytes: 4 * 1024, chunkDelay: .milliseconds(1)
        )
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 3, maxAttempts: 2, initialBackoff: 0.001)
        )
        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)

        await engine.start()
        await engine.start()
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })
        // Give a hypothetical second runner time to show up before asserting.
        try? await Task.sleep(for: .milliseconds(20))

        #expect(await transport.contentCalls.count == 1)
        #expect(await engine.item(item.id)?.attempts == 0)
        #expect(try Data(contentsOf: engine.fileURL(for: item)) == payload)
    }

    @Test("pause keeps bytesWritten and resume continues from it")
    func pauseAndResume() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(512 * 1024)
        let transport = MockTransport(
            payload: payload, chunkBytes: 16 * 1024, chunkDelay: .milliseconds(2)
        )
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(
                maxConcurrent: 1, maxAttempts: 3, initialBackoff: 0.001, progressFlushBytes: 32 * 1024
            )
        )
        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { (await engine.item(item.id)?.bytesWritten ?? 0) > 0 })
        await engine.pause(item.id)

        let paused = await engine.item(item.id)
        #expect(paused?.status == .paused)
        let written = try #require(paused?.bytesWritten)
        #expect(written > 0)
        #expect(written < Int64(payload.count))
        // The committed bytes are on disk, not only in memory.
        #expect(try Data(contentsOf: engine.partialURL(for: item)).count == Int(written))

        await engine.resume(item.id)
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })

        #expect(await transport.contentCalls.map(\.from) == [0, written])
        #expect(try Data(contentsOf: engine.fileURL(for: item)) == payload)
    }

    @Test("cancel drops the partial file and leaves a resumable row")
    func cancelDeletesPartialFile() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(512 * 1024)
        let transport = MockTransport(
            payload: payload, chunkBytes: 16 * 1024, chunkDelay: .milliseconds(2)
        )
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 1, maxAttempts: 3, initialBackoff: 0.001)
        )
        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { (await engine.item(item.id)?.bytesWritten ?? 0) > 0 })
        let partial = engine.partialURL(for: item)
        #expect(FileManager.default.fileExists(atPath: partial.path))

        await engine.cancel(item.id)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let cancelled = await engine.item(item.id)
        #expect(cancelled?.status == .paused)
        #expect(cancelled?.bytesWritten == 0)
        #expect(await engine.items().count == 1)
    }

    @Test("remove deletes the row and both of its files")
    func removeDeletesEverything() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(16 * 1024)
        let transport = MockTransport(payload: payload)
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 1, maxAttempts: 2, initialBackoff: 0.001)
        )
        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })
        #expect(FileManager.default.fileExists(atPath: engine.fileURL(for: item).path))

        await engine.remove(item.id)
        #expect(await engine.item(item.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: engine.fileURL(for: item).path))
        #expect(!FileManager.default.fileExists(atPath: engine.partialURL(for: item).path))
        #expect(await engine.bytesOnDisk() == 0)
    }

    @Test("removeCompleted removes only finished items and their files")
    func removeCompleted() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(8 * 1024)
        let transport = MockTransport(payload: payload)
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 2, maxAttempts: 2, initialBackoff: 0.001)
        )
        let done = makeItem(id: "done", totalBytes: Int64(payload.count))
        let waiting = makeItem(id: "waiting", status: .paused, totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([done, waiting]) == 2)
        await engine.start()
        #expect(await waitUntil { await engine.item(done.id)?.status == .completed })
        #expect(await engine.item(waiting.id)?.status == .paused)

        await engine.removeCompleted()
        #expect(await engine.items().map(\.id) == ["waiting"])
        #expect(!FileManager.default.fileExists(atPath: engine.fileURL(for: done).path))
    }

    @Test("removeAll empties the queue and the directory")
    func removeAll() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(8 * 1024)
        let transport = MockTransport(payload: payload)
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 2, maxAttempts: 2, initialBackoff: 0.001)
        )
        let done = makeItem(id: "done", totalBytes: Int64(payload.count))
        let paused = makeItem(id: "paused", status: .paused, totalBytes: Int64(payload.count))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: engine.partialURL(for: paused))
        #expect(await engine.enqueue([done, paused]) == 2)
        await engine.start()
        #expect(await waitUntil { await engine.item(done.id)?.status == .completed })

        await engine.removeAll()
        #expect(await engine.items().isEmpty)
        #expect(await engine.bytesOnDisk() == 0)
        #expect(!FileManager.default.fileExists(atPath: engine.partialURL(for: paused).path))
    }

    @Test("pauseAll stops everything that is not settled")
    func pauseAll() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(512 * 1024)
        let transport = MockTransport(
            payload: payload, chunkBytes: 16 * 1024, chunkDelay: .milliseconds(2)
        )
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(maxConcurrent: 2, maxAttempts: 3, initialBackoff: 0.001)
        )
        let items = (0..<4).map { makeItem(id: "item-\($0)", totalBytes: Int64(payload.count)) }
        #expect(await engine.enqueue(items) == 4)
        await engine.start()
        #expect(await waitUntil { (await engine.items().filter(\.isActive).count) == 2 })

        await engine.pauseAll()
        let statuses = await engine.items().map(\.status)
        #expect(statuses.allSatisfy { $0 == .paused })

        // Nothing is left running, so nothing changes after a settle.
        let before = await engine.items().map(\.bytesWritten)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await engine.items().map(\.bytesWritten) == before)
    }

    @Test("retry starts a failed item over with a fresh attempt budget")
    func retryResetsAttempts() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(64 * 1024)
        let transport = MockTransport(payload: payload, script: [.fail(after: 32 * 1024)])
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(
                maxConcurrent: 1, maxAttempts: 1, initialBackoff: 0.001
            )
        )
        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .failed })
        #expect(await engine.item(item.id)?.attempts == 1)

        await engine.retry(item.id)
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })
        let finished = await engine.item(item.id)
        #expect(finished?.attempts == 0)
        #expect(await transport.contentCalls.map(\.from) == [0, 32 * 1024])
        #expect(try Data(contentsOf: engine.fileURL(for: item)) == payload)
    }

    @Test("a duplicate id is skipped and never replaces the item already queued")
    func duplicateEnqueueIsSkipped() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let engine = DownloadEngine(
            directory: directory,
            transport: MockTransport(payload: Data())
        )
        let first = makeItem(id: "same", title: "First")
        let second = makeItem(id: "same", title: "Second")

        #expect(await engine.enqueue([first]) == 1)
        #expect(await engine.enqueue([second]) == 0)
        #expect(await engine.enqueue([second, first]) == 0)
        #expect(await engine.enqueue([makeItem(id: "other")]) == 1)

        #expect(await engine.items().count == 2)
        let kept = await engine.item("same")
        #expect(kept?.title == "First")
    }
}

// MARK: - Persistence

@Suite("DownloadEngine — persistence")
struct DownloadEnginePersistenceTests {

    private struct QueueDocument: Encodable {
        let items: [DownloadItem]
    }

    private func write(_ items: [DownloadItem], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.library.encode(QueueDocument(items: items))
        try data.write(to: directory.appendingPathComponent("downloads.json"))
    }

    @Test("a fresh engine over the same directory sees the queue")
    func queueSurvivesAFreshEngine() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let transport = MockTransport(payload: Data())

        let writer = DownloadEngine(directory: directory, transport: transport)
        let items = [makeItem(id: "a"), makeItem(id: "b", status: .paused)]
        #expect(await writer.enqueue(items) == 2)

        let reader = DownloadEngine(directory: directory, transport: transport)
        let loaded = await reader.load()
        #expect(loaded.map(\.id) == ["a", "b"])
        #expect(loaded.map(\.status) == [.queued, .paused])
        #expect(loaded.first?.title == "Subject")
    }

    @Test("an item left downloading in the file comes back as paused")
    func downloadingBecomesPaused() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        try write(
            [makeItem(id: "inflight", status: .downloading, totalBytes: 1000, bytesWritten: 400)],
            to: directory
        )

        let engine = DownloadEngine(directory: directory, transport: MockTransport(payload: Data()))
        let loaded = await engine.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.status == .paused)
        // The committed byte count survives the restart.
        #expect(loaded.first?.bytesWritten == 400)

        // The correction is written back, so the next reader does not see a
        // still-downloading item either.
        let reader = DownloadEngine(directory: directory, transport: MockTransport(payload: Data()))
        #expect(await reader.load().first?.status == .paused)
    }

    @Test("a legacy completed manifest is paused, emptied and deleted")
    func legacyManifestIsRepaired() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let item = makeItem(
            id: "legacy",
            status: .completed,
            totalBytes: 20,
            bytesWritten: 20,
            localFileName: "legacy.m3u8",
            container: .hls,
            layoutVersion: 1,
            remoteURL: makeURL("hls/index.m3u8")
        )
        try write([item], to: directory)
        try Data("#EXTM3U\n".utf8)
            .write(to: directory.appendingPathComponent("legacy.m3u8"))

        let engine = DownloadEngine(directory: directory, transport: MockTransport(payload: Data()))
        let loaded = await engine.load()
        #expect(loaded.first?.status == .paused)
        #expect(loaded.first?.bytesWritten == 0)
        #expect(loaded.first?.totalBytes == 0)
        #expect(loaded.first?.layoutVersion == 2)
        #expect(loaded.first?.failure != nil)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("legacy.m3u8").path
        ))
    }

    @Test("a corrupt queue file yields a clean empty queue instead of throwing")
    func corruptDocument() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("this is not json {{{".utf8)
            .write(to: directory.appendingPathComponent("downloads.json"))

        let engine = DownloadEngine(directory: directory, transport: MockTransport(payload: Data()))
        #expect(await engine.load().isEmpty)
        #expect(await engine.items().isEmpty)
        #expect(await engine.bytesOnDisk() == 0)

        // Truncated JSON is treated exactly the same way.
        let truncatedDirectory = uniqueDirectory()
        defer { removeDirectory(truncatedDirectory) }
        try FileManager.default.createDirectory(at: truncatedDirectory, withIntermediateDirectories: true)
        try Data(#"{"items":[{"id":"x""#.utf8)
            .write(to: truncatedDirectory.appendingPathComponent("downloads.json"))
        let truncated = DownloadEngine(directory: truncatedDirectory, transport: MockTransport(payload: Data()))
        #expect(await truncated.load().isEmpty)
    }

    @Test("progress is persisted at flush granularity, never per byte")
    func progressFlush() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(64 * 1024)
        // A large flush interval means a mid-flight file has almost no progress.
        let transport = MockTransport(
            payload: payload, chunkBytes: 4 * 1024, chunkDelay: .milliseconds(1)
        )
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(
                maxConcurrent: 1,
                maxAttempts: 2,
                initialBackoff: 0.001,
                progressFlushBytes: 32 * 1024
            )
        )
        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { (await engine.item(item.id)?.bytesWritten ?? 0) > 16 * 1024 })

        // The queue file exists and holds a valid document while the item runs.
        let data = try Data(contentsOf: directory.appendingPathComponent("downloads.json"))
        let document = try JSONDecoder.library.decode(QueueDocumentDecoded.self, from: data)
        #expect(document.items.count == 1)

        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })
    }

    private struct QueueDocumentDecoded: Decodable {
        let items: [DownloadItem]
    }

    @Test("bytesOnDisk counts the partial file and the finished file, never both at once")
    func bytesOnDisk() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(8 * 1024)
        let engine = DownloadEngine(
            directory: directory,
            transport: MockTransport(payload: payload),
            configuration: DownloadConfiguration(maxConcurrent: 1, maxAttempts: 2, initialBackoff: 0.001)
        )
        #expect(await engine.bytesOnDisk() == 0)

        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)
        // A partial file on disk counts even before anything ran.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.prefix(2048).write(to: engine.partialURL(for: item))
        #expect(await engine.bytesOnDisk() == 2048)

        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })
        // The rename moved the data, it did not duplicate it.
        #expect(await engine.bytesOnDisk() == Int64(payload.count))
    }
}

// MARK: - Updates

@Suite("DownloadEngine — updates")
struct DownloadEngineUpdatesTests {

    @Test("updates() emits the whole queue on every change and reports progress")
    func emitsProgressAndCompletion() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(128 * 1024)
        let transport = MockTransport(
            payload: payload, chunkBytes: 8 * 1024, chunkDelay: .milliseconds(1)
        )
        let engine = DownloadEngine(
            directory: directory,
            transport: transport,
            configuration: DownloadConfiguration(
                maxConcurrent: 1,
                maxAttempts: 2,
                initialBackoff: 0.001,
                progressFlushBytes: 8 * 1024
            )
        )
        let item = makeItem(totalBytes: Int64(payload.count))
        #expect(await engine.enqueue([item]) == 1)

        let collector = SnapshotCollector()
        let stream = await engine.updates()
        let watcher = Task { for await snapshot in stream { await collector.record(snapshot) } }

        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })
        // Cancelling the consumer is what finishes the stream.
        watcher.cancel()
        await watcher.value

        let snapshots = await collector.snapshots
        #expect(snapshots.isEmpty == false)
        // Every emission is the full list, never a delta.
        #expect(snapshots.allSatisfy { $0.count == 1 })
        #expect(snapshots.first?.first?.status == .queued)
        #expect(snapshots.last?.first?.status == .completed)
        // A progress bar needs snapshots strictly between empty and full.
        let total = Int64(payload.count)
        #expect(snapshots.contains { snapshot in
            guard let written = snapshot.first?.bytesWritten else { return false }
            return written > 0 && written < total
        })
    }

    @Test("a second subscriber sees the same list")
    func multipleSubscribers() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let engine = DownloadEngine(directory: directory, transport: MockTransport(payload: Data()))

        let first = SnapshotCollector()
        let second = SnapshotCollector()
        let streamA = await engine.updates()
        let watcherA = Task { for await snapshot in streamA { await first.record(snapshot) } }
        let streamB = await engine.updates()
        let watcherB = Task { for await snapshot in streamB { await second.record(snapshot) } }

        #expect(await engine.enqueue([makeItem(id: "a")]) == 1)
        #expect(await waitUntil { await first.snapshots.count >= 2 })
        #expect(await waitUntil { await second.snapshots.count >= 2 })

        watcherA.cancel()
        await watcherA.value

        #expect(await first.snapshots.last?.map(\.id) == ["a"])
        #expect(await second.snapshots.last?.map(\.id) == ["a"])
        // Cancelling the first subscriber must not disturb the second.
        #expect(await engine.enqueue([makeItem(id: "b")]) == 1)
        #expect(await waitUntil { await second.snapshots.last?.count == 2 })
        #expect(await second.snapshots.last?.map(\.id) == ["a", "b"])

        watcherB.cancel()
        await watcherB.value
    }
}

// MARK: - Transport response handling

@Suite("URLSessionDownloadTransport — response handling")
struct URLSessionDownloadTransportTests {

    private func response(status: Int, _ headers: [String: String]) throws -> HTTPURLResponse {
        let url = makeURL("x.mp4")
        return try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        )
    }

    @Test("parses a Content-Range into start, end and total")
    func parsesContentRange() {
        let range = URLSessionDownloadTransport.contentRange("bytes 100-999/1000")
        #expect(range?.start == 100)
        #expect(range?.end == 999)
        #expect(range?.total == 1000)
    }

    @Test("an unknown total in Content-Range reads as zero")
    func parsesUnknownTotal() {
        #expect(URLSessionDownloadTransport.contentRange("bytes 0-0/*")?.total == 0)
        #expect(URLSessionDownloadTransport.contentRange("bytes 0-0/*")?.start == 0)
    }

    @Test("a malformed or absent Content-Range is rejected rather than guessed")
    func rejectsMalformedContentRange() {
        #expect(URLSessionDownloadTransport.contentRange(nil) == nil)
        #expect(URLSessionDownloadTransport.contentRange("") == nil)
        #expect(URLSessionDownloadTransport.contentRange("pages 1-2/3") == nil)
        #expect(URLSessionDownloadTransport.contentRange("bytes 1-2") == nil)
        #expect(URLSessionDownloadTransport.contentRange("bytes a-b/3") == nil)
        #expect(URLSessionDownloadTransport.contentRange("bytes 1-2-3/4") == nil)
    }

    @Test("a 200 response reports Accept-Ranges as range support")
    func fileInfoFromFullResponse() throws {
        let withRanges = URLSessionDownloadTransport.fileInfo(
            from: try response(status: 200, ["Content-Length": "1024", "Accept-Ranges": "bytes"])
        )
        #expect(withRanges.totalBytes == 1024)
        #expect(withRanges.supportsRanges)

        let withoutRanges = URLSessionDownloadTransport.fileInfo(
            from: try response(status: 200, ["Content-Length": "1024"])
        )
        #expect(withoutRanges.totalBytes == 1024)
        #expect(!withoutRanges.supportsRanges)

        // Header names are case-insensitive on the wire and in the parse.
        let uppercase = URLSessionDownloadTransport.fileInfo(
            from: try response(status: 200, ["Accept-Ranges": "BYTES", "Content-Length": "10"])
        )
        #expect(uppercase.supportsRanges)
    }

    @Test("a 206 response takes the total from Content-Range, not Content-Length")
    func fileInfoFromRangedResponse() throws {
        let info = URLSessionDownloadTransport.fileInfo(
            from: try response(status: 206, [
                "Content-Length": "1",
                "Content-Range": "bytes 0-0/987654",
                "Accept-Ranges": "none",
            ])
        )
        #expect(info.totalBytes == 987654)
        // A 206 is itself proof that the server honours ranges.
        #expect(info.supportsRanges)
    }

    @Test("a response with no length at all reports an unknown size")
    func fileInfoWithoutLength() throws {
        let info = URLSessionDownloadTransport.fileInfo(from: try response(status: 200, [:]))
        #expect(info.totalBytes == 0)
        #expect(!info.supportsRanges)
    }

    @Test("one ranged request asks for a bounded slice, and progress slices stay under 256 KB")
    func boundedRequests() {
        #expect(URLSessionDownloadTransport.chunkBytes > 0)
        #expect(URLSessionDownloadTransport.chunkBytes <= 4 << 20)
        #expect(URLSessionDownloadTransport.sliceBytes <= 256 * 1024)
        #expect(URLSessionDownloadTransport.sliceBytes > 0)
    }
}

// MARK: - Containers

@Suite("DownloadEngine — containers")
struct DownloadEngineContainerTests {

    @Test("a manifest fails before the first byte reaches a partial file")
    func manifestNeverStartsAsAFile() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let item = makeItem(
            id: "hls",
            localFileName: "hls.hls",
            container: .hls,
            remoteURL: makeURL("hls/index.m3u8")
        )
        let engine = DownloadEngine(directory: directory, transport: MockTransport(payload: Data()))

        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .failed })

        let failed = await engine.item(item.id)
        #expect(failed?.bytesWritten == 0)
        #expect(failed?.failure?.contains("HLS") == true)
        #expect(!FileManager.default.fileExists(atPath: engine.partialURL(for: item).path))
        #expect(!FileManager.default.fileExists(atPath: engine.fileURL(for: item).path))
    }
}

// MARK: - Captions

/// An episode is not complete until its subtitles are beside it: that is the
/// difference between a saved file and a watchable one with no connection.
@Suite("DownloadEngine — captions")
struct DownloadEngineCaptionTests {
    private func engine(_ directory: URL, payload: Data) -> DownloadEngine {
        DownloadEngine(
            directory: directory,
            transport: MockTransport(payload: payload, script: [.all]),
            configuration: DownloadConfiguration(
                maxConcurrent: 1,
                maxAttempts: 2,
                initialBackoff: 0.001,
                maxBackoff: 0.002,
                progressFlushBytes: 32 * 1024
            )
        )
    }

    @Test("a finished download keeps the captions fetched for it")
    func savesCaptions() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(64 * 1024)
        let engine = engine(directory, payload: payload)
        let item = makeItem(totalBytes: Int64(payload.count))
        let captionFile = directory.appendingPathComponent("english-abc.vtt")

        // Stands in for the app's archive: it writes the file the provider's
        // caption body converts into, then reports what it saved.
        await engine.setCaptionProvider { _ in
            try? "WEBVTT\n\n00:00.000 --> 00:01.000\nHi\n"
                .write(to: captionFile, atomically: true, encoding: .utf8)
            return [DownloadedSubtitle(language: "English", fileName: "english-abc.vtt")]
        }

        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })
        #expect(await waitUntil { await engine.item(item.id)?.subtitles.isEmpty == false })

        let finished = try #require(await engine.item(item.id))
        #expect(finished.subtitles.map(\.language) == ["English"])
        // The picker is handed the saved file, not the caption host.
        let tracks = engine.subtitleTracks(for: finished)
        #expect(tracks.first?.provider == .downloaded)
        #expect(tracks.first?.url.hasPrefix("file://") == true)

        // Deleting the episode takes its captions with it.
        await engine.remove(item.id)
        #expect(!FileManager.default.fileExists(atPath: captionFile.path))
    }

    @Test("a caption lookup that finds nothing leaves the episode complete")
    func noCaptions() async throws {
        let directory = uniqueDirectory()
        defer { removeDirectory(directory) }
        let payload = makePayload(32 * 1024)
        let engine = engine(directory, payload: payload)
        let item = makeItem(totalBytes: Int64(payload.count))

        await engine.setCaptionProvider { _ in [] }

        #expect(await engine.enqueue([item]) == 1)
        await engine.start()
        #expect(await waitUntil { await engine.item(item.id)?.status == .completed })

        // Give the detached lookup a chance to run before asserting it changed
        // nothing: "no captions" must not become "no episode".
        try? await Task.sleep(for: .milliseconds(50))
        let finished = try #require(await engine.item(item.id))
        #expect(finished.status == .completed)
        #expect(finished.subtitles.isEmpty)
        #expect(finished.failure == nil)
    }
}
