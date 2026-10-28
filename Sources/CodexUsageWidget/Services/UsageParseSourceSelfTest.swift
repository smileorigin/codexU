import Darwin
import Foundation

enum UsageParseSourceSelfTest {
    static func run() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func check(_ value: Bool) throws { if !value { throw UsageIndexError.databaseFailure } }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("tests/fixtures/history-index/codex-counters.jsonl")
            let compressed = try Data(contentsOf: fixture.appendingPathExtension("zst"))
            let path = root.appendingPathComponent("session.jsonl")
            let archive = path.appendingPathExtension("zst")
            try compressed.write(to: archive)
            let source = try UsageParseSource(path: path.path, runtime: "codex")
            let stamp = try source.stamp(at: 0)
            let plainSize = UInt64(try Data(contentsOf: fixture).count)
            try check(stamp.size == plainSize && stamp.size != compressed.count && stamp.identity.hasPrefix("zstd:"))
            var attributes = stat()
            try check(fstat(source.descriptor!, &attributes) == 0 && attributes.st_nlink == 0
                && attributes.st_mode & 0o777 == 0o600)
            let cached = try UsageParseSource(path: path.path, runtime: "codex", cached: source)
            try check(cached.descriptor == source.descriptor)
            let direct = try UsageParseSource(path: archive.path, runtime: "codex")
            try check(direct.stamp(at: 0) == stamp)
            let large = try UsageParseSource(path: fixture.deletingLastPathComponent().appendingPathComponent("codex-large-output.jsonl.zst").path, runtime: "codex")
            try check(large.stamp(at: 0).size > 200_000)
            var checkpoint = CodexIndexCheckpoint()
            var total: Int64 = 0
            var batches = 0
            while checkpoint.cursor.offset < plainSize {
                let batch = try UsageStreamParser.readCodex(url: archive, targetEnd: plainSize,
                    checkpoint: checkpoint, maximumLines: 1, descriptor: source.descriptor)
                checkpoint = try JSONDecoder().decode(CodexIndexCheckpoint.self, from: JSONEncoder().encode(batch.checkpoint))
                total += batch.deltas.reduce(0) { $0 + $1.tokens.totalTokens }
                batches += 1
                try check(batches < 20)
            }
            try check(total == 175 && batches > 1)
            // 多帧拼接必须全部解码，第二帧不能被当成尾部垃圾忽略
            try (compressed + compressed).write(to: archive, options: .atomic)
            let joined = try UsageParseSource(path: archive.path, runtime: "codex")
            try check(joined.stamp(at: 0).size == plainSize * 2)
            do { _ = try source.stamp(at: 0); return false } catch UsageIndexError.sourceChanged {}
            for corrupt in [Data(compressed.dropLast()), compressed + Data([1, 2, 3]), Data("invalid".utf8)] {
                try corrupt.write(to: archive, options: .atomic)
                do { _ = try UsageParseSource(path: path.path, runtime: "codex"); return false }
                catch UsageIndexError.cacheInvalid {}
            }
            try compressed.write(to: archive, options: .atomic)
            let input = open(archive.path, O_RDONLY | O_CLOEXEC)
            let output = open("/dev/null", O_WRONLY | O_CLOEXEC)
            defer { close(input); close(output) }
            try check(input >= 0 && output >= 0)
            try check(codexu_decode_zstd(input, output, 8, 3) == 2)
            _ = lseek(input, 0, SEEK_SET)
            try check(codexu_decode_zstd(input, output, plainSize, 0) == 4)
            try FileManager.default.removeItem(at: archive)
            do { _ = try UsageParseSource(path: path.path, runtime: "codex"); return false }
            catch UsageIndexError.sourceMissing {}
            // 真实 helper 错误分类必须与直接读取一致
            let helper = UsageParseHelper()
            do {
                _ = try helper.parse(UsageParseRequest(id: "missing", path: path.path, targetEnd: 0,
                    checkpoint: CodexIndexCheckpoint(), previousStamp: nil))
                return false
            } catch UsageIndexError.sourceMissing {}

            // 扫描不得清除排队任务或三次失败后的退避时间
            let store = try UsageIndexStore(directory: root.appendingPathComponent("index"))
            let now = Date()
            try store.registerSource(id: "one", root: "fixture", runtime: "codex", logicalID: "one", locator: path.path, now: now)
            try store.enqueueSource("one", priority: 2, now: now)
            let retry = try usageIndexMilliseconds(now.addingTimeInterval(300))
            for status in ["queued", "error"] {
                try store.execute("UPDATE job SET status=?,retry_at_ms=?,cursor='{\"error\":\"sourceMissing\"}' WHERE source_id='one'", [.text(status), .integer(retry)])
                try store.enqueueDiscoveredSource("one", priority: 1, now: now.addingTimeInterval(30))
                try check(store.scalar("SELECT retry_at_ms FROM job WHERE source_id='one'") == retry)
                try check(store.claimJob(now: now.addingTimeInterval(30)) == nil)
            }
            try store.enqueueDiscoveredSource("one", priority: 1, now: now.addingTimeInterval(301))
            try check(store.claimJob(now: now.addingTimeInterval(301)) != nil)
            try missingWorkerTest(root: root, fixture: fixture)
            print("history compressed source: offsets, resume, unlinked private spool, multiple frames, corruption, budgets and retry backoff passed")
            return true
        } catch {
            print("history compressed source failed: \(error)")
            return false
        }
    }

    private static func missingWorkerTest(root: URL, fixture: URL) throws {
        let worker = UsageIndexWorker()
        let done = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
        let directory = root.appendingPathComponent("missing-worker")
        let sources = [
            UsageDiscoveredSource(runtime: "codex", logicalID: "valid", locator: fixture.path, model: nil, project: "fixture", updatedAt: 0),
            UsageDiscoveredSource(runtime: "codex", logicalID: "missing", locator: root.appendingPathComponent("missing.jsonl").path, model: nil, project: "fixture", updatedAt: 0)
        ]
        var failures = 0, completed = false
        worker.start(directory: directory, sources: sources, rootID: "fixture") { progress in
            if progress.error == .sourceMissing { failures += 1 }
            if progress.pendingJobs == 0, !completed {
                completed = true
                worker.stop { stopped.signal() }
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + 15) == .success,
              stopped.wait(timeout: .now() + 5) == .success else {
            worker.stop(); throw UsageIndexError.cancelled
        }
        let store = try UsageIndexStore(directory: directory)
        guard failures == 3,
              try store.scalar("SELECT count(*) FROM job WHERE kind='parse' AND status='done'") == 1,
              try store.scalar("SELECT count(*) FROM job WHERE kind='parse' AND status='error' AND retry_at_ms>0") == 1 else {
            throw UsageIndexError.databaseFailure
        }
    }
}
