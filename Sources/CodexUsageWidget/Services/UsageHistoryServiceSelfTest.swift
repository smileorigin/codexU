import Foundation

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
            return true
        } catch {
            print("history service failed: \(error)")
            return false
        }
    }
}
