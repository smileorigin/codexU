import Foundation
import SQLite3

enum UsageHistoryServiceSelfTest {
    static func run() -> Bool {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        do {
            let project=directory.appendingPathComponent(".claude/projects/fixture")
            try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
            let line = #"{"timestamp":"2026-09-19T10:00:00Z","cwd":"/fixture","message":{"id":"one","model":"claude-sonnet-4","usage":{"input_tokens":30,"output_tokens":5}}}"# + "\n"
            try Data(line.utf8).write(to:project.appendingPathComponent("one.jsonl"))
            let service=UsageHistoryService()
            let completed=DispatchSemaphore(value:0)
            let stopped=DispatchSemaphore(value:0)
            let now=Date()
            var signaled=false
            var lastContext: RuntimeLoadContext?
            for zone in ["UTC","Asia/Tokyo","Asia/Shanghai"] {
                let statistics=StatisticsContext(preference:.init(selection:.fixed,fixedIdentifier:zone),now:now)
                let context=RuntimeLoadContext(now:now,homeDirectory:directory,cacheDirectory:directory.appendingPathComponent("cache"),statistics:statistics)
                lastContext=context
                service.subscribe(context:context) { value in
                    if value.scope == .claudeCode, value.complete, value.local.lifetimeTokens == 35, !signaled {
                        signaled=true;completed.signal()
                    }
                }
            }
            let success=completed.wait(timeout:.now()+30) == .success
            var refreshed=false
            if success, let context=lastContext {
                let additional=line.replacingOccurrences(of:"\"id\":\"one\"",with:"\"id\":\"two\"")
                try Data(additional.utf8).write(to:project.appendingPathComponent("two.jsonl"))
                let updated=DispatchSemaphore(value:0)
                var received=false
                for _ in 0..<20 {
                    service.subscribe(context:context) { value in
                        if value.scope == .claudeCode, value.complete, value.local.lifetimeTokens == 70, !received {
                            received=true;updated.signal()
                        }
                    }
                }
                // 必须在 30 秒周期扫描前发现新增来源并发布完整结果
                refreshed=updated.wait(timeout:.now()+10) == .success
            }
            service.stop { stopped.signal() }
            guard stopped.wait(timeout:.now()+10) == .success,success,refreshed else { throw UsageIndexError.cancelled }
            print("history service: Claude-only discovery, A/B/C transition and immediate coalesced rescan passed")
            return deletedEmptyCodexSource()
        } catch {
            print("history service failed: \(error)")
            return false
        }
    }

    private static func deletedEmptyCodexSource() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = UsageHistoryService()
        var database: OpaquePointer?
        defer {
            let stopped = DispatchSemaphore(value: 0)
            service.stop { stopped.signal() }
            _ = stopped.wait(timeout: .now() + 10)
            if let database { sqlite3_close(database) }
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            let codex = directory.appendingPathComponent(".codex")
            try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
            guard sqlite3_open(codex.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK else {
                throw UsageIndexError.databaseFailure
            }
            func sql(_ statement: String) throws {
                guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw UsageIndexError.databaseFailure }
            }
            let now = Date()
            let statistics = StatisticsContext(preference: .init(selection: .utc, fixedIdentifier: "UTC"), now: now)
            let monthStart = statistics.calendar.dateInterval(of: .month, for: now)!.start
            let file = codex.appendingPathComponent("valid.jsonl")
            func event(_ date: Date, input: Int, output: Int) throws -> Data {
                let object: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: date),
                    "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": [
                        "input_tokens": input, "cached_input_tokens": 0, "output_tokens": output, "total_tokens": input + output]]]]
                var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
                return data
            }
            try event(monthStart.addingTimeInterval(-1), input: 80, output: 20).write(to: file)
            try sql("CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT,model TEXT,cwd TEXT,updated_at INTEGER)")
            let escaped = file.path.replacingOccurrences(of: "'", with: "''")
            try sql("INSERT INTO threads VALUES ('valid','\(escaped)','gpt-5.5','/fixture',\(Int(now.timeIntervalSince1970)))")
            let context = RuntimeLoadContext(now: now, homeDirectory: directory,
                cacheDirectory: directory.appendingPathComponent("cache"), statistics: statistics)
            let initial = DispatchSemaphore(value: 0)
            var initialSent = false
            service.subscribe(context: context) { value in
                if value.scope == .codex, value.complete, value.local.lifetimeTokens == 100, !initialSent {
                    initialSent = true; initial.signal()
                }
            }
            guard initial.wait(timeout: .now() + 30) == .success else { throw UsageIndexError.cancelled }

            let missing = codex.appendingPathComponent("removed.jsonl").path.replacingOccurrences(of: "'", with: "''")
            try sql("INSERT INTO threads VALUES ('removed','\(missing)','gpt-5.5','/fixture',\(Int(now.timeIntervalSince1970)))")
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: event(now, input: 120, output: 30))
            try handle.close()
            let failed = DispatchSemaphore(value: 0)
            var failureSent = false
            service.subscribe(context: context, onFailure: { error in
                if error == .sourceMissing, !failureSent { failureSent = true; failed.signal() }
            }) { _ in }
            guard failed.wait(timeout: .now() + 10) == .success else { throw UsageIndexError.cancelled }

            try sql("DELETE FROM threads WHERE id='removed'")
            let updated = DispatchSemaphore(value: 0)
            var updateSent = false
            service.subscribe(context: context) { value in
                if value.scope == .codex, value.complete, value.local.lifetimeTokens == 150,
                   value.local.todayTokens == 50, value.local.detailedUsage?.month.tokens.totalTokens == 50, !updateSent {
                    updateSent = true; updated.signal()
                }
            }
            guard updated.wait(timeout: .now() + 15) == .success else { throw UsageIndexError.cancelled }
            print("history service: deleted never-indexed Codex source unblocks current-day and current-month publication")
            return true
        } catch {
            print("history service deleted-source regression failed: \(error)")
            return false
        }
    }
}
