import Testing
import Foundation
@testable import CinemacoreCore

// MARK: - Fixtures

private let firstEpoch = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let secondEpoch = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeItem(
    id: String = "subject-1-s1e1-1080p",
    quality: String = "1080p",
    status: DownloadStatus = .queued,
    container: MediaContainer = .mp4,
    layoutVersion: Int = 2,
    transferEpoch: UUID? = nil,
    remoteURL: URL? = nil
) -> DownloadItem {
    DownloadItem(
        id: id,
        subjectID: "subject-1",
        title: "Subject",
        season: 1,
        episode: 1,
        quality: quality,
        remoteURL: remoteURL ?? URL(string: "https://cdn.test/\(id).mp4")!,
        container: container,
        layoutVersion: layoutVersion,
        transferEpoch: transferEpoch,
        status: status,
        createdAt: fixedDate,
        updatedAt: fixedDate,
        localFileName: "\(id).mp4"
    )
}

private func makeKey(
    itemID: String,
    epoch: UUID = firstEpoch,
    index: Int = 0
) -> TransferTaskKey {
    TransferTaskKey(itemID: itemID, epoch: epoch, index: index)
}

private func makeSnapshot(
    key: TransferTaskKey?,
    taskIdentifier: Int = 7,
    url: URL? = URL(string: "https://cdn.test/subject-1-s1e1-1080p.mp4")
) -> TransferSnapshot {
    TransferSnapshot(
        key: key,
        taskIdentifier: taskIdentifier,
        url: url,
        bytesReceived: 512,
        expectedBytes: 1024,
        isDownloading: true
    )
}

// MARK: - ByteRange

@Suite("ByteRange")
struct BackgroundByteRangeTests {

    @Test("length is inclusive of both endpoints")
    func lengthIsInclusive() {
        #expect(ByteRange(start: 0, end: 0).length == 1)
        #expect(ByteRange(start: 0, end: 1023).length == 1024)
        #expect(ByteRange(start: 100, end: 199).length == 100)
    }

    @Test("contains includes its endpoints and excludes everything else")
    func containsBounds() {
        let range = ByteRange(start: 100, end: 199)
        #expect(range.contains(100))
        #expect(range.contains(150))
        #expect(range.contains(199))
        #expect(!range.contains(99))
        #expect(!range.contains(200))
    }

    @Test("headerValue is a closed byte interval")
    func headerValue() {
        #expect(ByteRange(start: 0, end: 0).headerValue == "bytes=0-0")
        #expect(ByteRange(start: 512, end: 1023).headerValue == "bytes=512-1023")
    }

    @Test("an inverted range collapses to one byte instead of a negative length")
    func invertedRangeIsSafe() {
        let range = ByteRange(start: 10, end: 4)
        #expect(range.start == 10)
        #expect(range.end == 10)
        #expect(range.length == 1)
        #expect(range.contains(10))
        #expect(!range.contains(4))
        #expect(!range.contains(11))
        #expect(range.headerValue == "bytes=10-10")
    }

    @Test("a range survives Codable round trips")
    func codableRoundTrip() throws {
        let range = ByteRange(start: 12, end: 34)
        let decoded = try JSONDecoder().decode(
            ByteRange.self,
            from: JSONEncoder().encode(range)
        )
        #expect(decoded == range)
    }
}

// MARK: - TransferTaskKey

@Suite("TransferTaskKey")
struct BackgroundTransferTaskKeyTests {

    @Test("taskDescription round-trips ids containing separators, spaces and a UUID epoch")
    func roundTripHostileItemIDs() {
        let ids = [
            "subject:1",
            "subject/1",
            "subject 1 s1e1 1080p",
            "subject:1/s1 e1/1080p",
            "cinemacore:subject/1 s1 e1",
        ]
        for id in ids {
            let key = makeKey(itemID: id, epoch: secondEpoch, index: 3)
            let description = key.taskDescription

            #expect(description.hasPrefix("cinemacore:"))
            #expect(!description.contains(":\(id):"), "the id must not be delimited in the description")
            #expect(TransferTaskKey.parse(description) == key)
        }
    }

    @Test("parse rejects nil, empty, garbage and prefix-only descriptions")
    func parseRejectsInvalidDescriptions() {
        #expect(TransferTaskKey.parse(nil) == nil)
        #expect(TransferTaskKey.parse("") == nil)
        #expect(TransferTaskKey.parse("garbage") == nil)
        #expect(TransferTaskKey.parse("cinemacore:") == nil)
        #expect(TransferTaskKey.parse("cinemacore:not base64!!") == nil)
    }

    @Test("parse rejects a prefixed payload that is not a JSON key")
    func parseRejectsMalformedPayload() {
        let notAKey = Data(#"{"itemID":"subject-1"}"#.utf8).base64EncodedString()
        let notJSON = Data([0x00, 0x01, 0x02, 0x03]).base64EncodedString()

        #expect(TransferTaskKey.parse("cinemacore:" + notAKey) == nil)
        #expect(TransferTaskKey.parse("cinemacore:" + notJSON) == nil)
    }

    @Test("two keys that share an id but differ by epoch or index are distinct")
    func identityIncludesEpochAndIndex() {
        let base = makeKey(itemID: "subject-1-s1e1-1080p")
        #expect(base != makeKey(itemID: "subject-1-s1e1-1080p", epoch: secondEpoch))
        #expect(base != makeKey(itemID: "subject-1-s1e1-1080p", index: 1))
        #expect(base.taskDescription != makeKey(itemID: "subject-1-s1e1-1080p", index: 1).taskDescription)
    }
}

// MARK: - TransferReconciler

@Suite("TransferReconciler")
struct BackgroundTransferReconcilerTests {

    private let reconciler = TransferReconciler()

    @Test("a persisted downloading item reattaches to its active daemon task")
    func activeTaskAndDownloadingItemReattach() {
        let item = makeItem(status: .downloading)
        let snapshot = makeSnapshot(key: makeKey(itemID: item.id))

        let decisions = reconciler.reconcile(queue: [item], snapshots: [snapshot])

        #expect(decisions == [
            .init(itemID: item.id, taskIdentifier: snapshot.taskIdentifier, action: .reattach)
        ])
    }

    @Test("a relaunch-demoted paused item in reattachable reattaches")
    func relaunchDemotedItemReattaches() {
        let item = makeItem(status: .paused)
        let snapshot = makeSnapshot(key: makeKey(itemID: item.id))

        let decisions = reconciler.reconcile(
            queue: [item],
            snapshots: [snapshot],
            reattachable: [item.id]
        )

        #expect(decisions == [
            .init(itemID: item.id, taskIdentifier: snapshot.taskIdentifier, action: .reattach)
        ])
    }

    @Test("a user-paused item that is not reattachable cancels the orphan task")
    func userPausedItemCancelsOrphan() {
        let item = makeItem(status: .paused)
        let snapshot = makeSnapshot(key: makeKey(itemID: item.id))

        let decisions = reconciler.reconcile(queue: [item], snapshots: [snapshot])

        #expect(decisions == [
            .init(itemID: item.id, taskIdentifier: snapshot.taskIdentifier, action: .cancelOrphan)
        ])
    }

    @Test("a snapshot for an item no longer queued is an orphan")
    func snapshotForRemovedItemCancelsOrphan() {
        let snapshot = makeSnapshot(key: makeKey(itemID: "removed-item"))

        let decisions = reconciler.reconcile(queue: [], snapshots: [snapshot])

        #expect(decisions == [
            .init(itemID: "removed-item", taskIdentifier: snapshot.taskIdentifier, action: .cancelOrphan)
        ])
    }

    @Test("a snapshot without a key cannot be matched and is an orphan")
    func snapshotWithoutKeyCancelsOrphan() {
        let snapshot = makeSnapshot(key: nil, taskIdentifier: 42)

        let decisions = reconciler.reconcile(queue: [], snapshots: [snapshot])

        #expect(decisions == [
            .init(itemID: nil, taskIdentifier: 42, action: .cancelOrphan)
        ])
    }

    @Test("a downloading item without a snapshot pauses instead of spinning")
    func downloadingItemWithoutSnapshotPauses() {
        let item = makeItem(status: .downloading)

        let decisions = reconciler.reconcile(queue: [item], snapshots: [])

        #expect(decisions == [
            .init(itemID: item.id, taskIdentifier: nil, action: .pause)
        ])
    }

    @Test("settled items produce no decisions and matched items are not paused")
    func settledItemsAreIgnored() {
        let paused = makeItem(id: "paused", status: .paused)
        let completed = makeItem(id: "completed", status: .completed)
        let downloading = makeItem(id: "downloading", status: .downloading)
        let snapshot = makeSnapshot(key: makeKey(itemID: downloading.id))

        let decisions = reconciler.reconcile(
            queue: [paused, completed, downloading],
            snapshots: [snapshot]
        )

        #expect(decisions == [
            .init(itemID: downloading.id, taskIdentifier: snapshot.taskIdentifier, action: .reattach)
        ])
    }
}

// MARK: - DownloadItem.transferEpoch

@Suite("DownloadItem transferEpoch")
struct BackgroundTransferEpochTests {

    @Test("an explicit epoch survives a JSON round trip")
    func epochRoundTrip() throws {
        let item = makeItem(
            status: .downloading,
            container: .hls,
            layoutVersion: 2,
            transferEpoch: firstEpoch,
            remoteURL: URL(string: "https://cdn.test/subject-1-s1e1.m3u8")!
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: data)

        #expect(decoded.id == item.id)
        #expect(decoded.transferEpoch == firstEpoch)
        #expect(decoded.container == .hls)
        #expect(decoded.layoutVersion == 2)
        #expect(decoded.status == .downloading)
    }

    @Test("a nil epoch stays nil after a round trip")
    func nilEpochRoundTrip() throws {
        let item = makeItem(transferEpoch: nil)

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: data)

        #expect(decoded.transferEpoch == nil)
    }

    @Test("a legacy document without an epoch decodes to nil and keeps old layout defaults")
    func legacyDocumentWithoutEpoch() throws {
        let legacy = """
        {
          "id": "subject-1-s1e1-1080p",
          "subjectID": "subject-1",
          "title": "Subject",
          "quality": "1080p",
          "remoteURL": "https://cdn.test/subject-1-s1e1.m3u8",
          "status": "paused",
          "totalBytes": 1024,
          "bytesWritten": 512
        }
        """

        let decoded = try JSONDecoder().decode(DownloadItem.self, from: Data(legacy.utf8))

        #expect(decoded.transferEpoch == nil)
        #expect(decoded.layoutVersion == 1)
        // No container key: the URL extension is the only evidence available.
        #expect(decoded.container == .hls)
        #expect(decoded.status == .paused)
    }

    @Test("an explicit container and layout survive decoding")
    func explicitContainerAndLayout() throws {
        let document = """
        {
          "id": "subject-1-s1e1-1080p",
          "remoteURL": "https://cdn.test/subject-1-s1e1.m3u8",
          "container": "dash",
          "layoutVersion": 2,
          "transferEpoch": "\(firstEpoch.uuidString)"
        }
        """

        let decoded = try JSONDecoder().decode(DownloadItem.self, from: Data(document.utf8))

        #expect(decoded.container == .dash)
        #expect(decoded.layoutVersion == 2)
        #expect(decoded.transferEpoch == firstEpoch)
    }
}

// MARK: - TransferStaging

@Suite("TransferStaging")
struct BackgroundTransferStagingTests {

    private let root = URL(fileURLWithPath: "/tmp/cinemacore-staging", isDirectory: true)

    @Test("the same item, epoch and index produce the same URL")
    func pathsAreDeterministic() {
        let first = TransferStaging.fileURL(
            root: root,
            itemID: "subject-1-s1e1-1080p",
            epoch: firstEpoch,
            index: 3
        )
        let second = TransferStaging.fileURL(
            root: root,
            itemID: "subject-1-s1e1-1080p",
            epoch: firstEpoch,
            index: 3
        )

        #expect(first == second)
        #expect(first.lastPathComponent == "chunk-000003")
        #expect(first.path.hasPrefix(root.path + "/"))
    }

    @Test(
        "item ids with path separators cannot escape the staging root",
        arguments: [
            "../escape",
            "../../etc/passwd",
            "subject:1/s1 e1",
            "a\\b/../../c",
            "/absolute/path",
        ]
    )
    func separatorsCannotEscape(itemID: String) {
        let url = TransferStaging.fileURL(
            root: root,
            itemID: itemID,
            epoch: firstEpoch,
            index: 0
        )
        let rootPath = root.standardizedFileURL.path
        let stagedPath = url.standardizedFileURL.path
        let components = stagedPath.split(separator: "/").map(String.init)

        #expect(stagedPath.hasPrefix(rootPath + "/"))
        #expect(!components.contains(".."))
        #expect(url.lastPathComponent == "chunk-000000")
        #expect(
            TransferStaging.itemRoot(root: root, itemID: itemID)
                .standardizedFileURL.path
                .hasPrefix(rootPath + "/")
        )
        #expect(
            TransferStaging.epochDirectory(root: root, itemID: itemID, epoch: firstEpoch)
                .standardizedFileURL.path
                .hasPrefix(rootPath + "/")
        )
    }

    @Test("different epochs and indexes produce different paths")
    func epochAndIndexDisambiguate() {
        let base = TransferStaging.fileURL(
            root: root,
            itemID: "subject-1-s1e1-1080p",
            epoch: firstEpoch,
            index: 0
        )
        let otherEpoch = TransferStaging.fileURL(
            root: root,
            itemID: "subject-1-s1e1-1080p",
            epoch: secondEpoch,
            index: 0
        )
        let otherIndex = TransferStaging.fileURL(
            root: root,
            itemID: "subject-1-s1e1-1080p",
            epoch: firstEpoch,
            index: 1
        )

        #expect(base != otherEpoch)
        #expect(base != otherIndex)
        #expect(base.deletingLastPathComponent() != otherEpoch.deletingLastPathComponent())

        let otherItem = TransferStaging.fileURL(
            root: root,
            itemID: "subject-1-s1e2-1080p",
            epoch: firstEpoch,
            index: 0
        )
        #expect(base != otherItem)
    }

    @Test("the file lives inside the epoch directory for the item")
    func fileNestsUnderEpochDirectory() {
        let itemID = "subject-1-s1e1-1080p"
        let epochDirectory = TransferStaging.epochDirectory(
            root: root,
            itemID: itemID,
            epoch: firstEpoch
        )
        let file = TransferStaging.fileURL(
            root: root,
            itemID: itemID,
            epoch: firstEpoch,
            index: 9
        )

        #expect(file.deletingLastPathComponent() == epochDirectory)
        #expect(epochDirectory.deletingLastPathComponent() == TransferStaging.itemRoot(root: root, itemID: itemID))
        #expect(epochDirectory.lastPathComponent == firstEpoch.uuidString)
    }
}
