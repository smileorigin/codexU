import Foundation

enum RefreshSchedulingSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }
        func waitUntil(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(2)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            return condition()
        }

        let suite = "codexU.refresh-self-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        expect(settings.refreshInterval == .automatic && settings.refreshAfterCodexTask,
               "既有用户应保留自动周期，默认开启任务结束刷新")
        settings.refreshInterval = .thirtySeconds
        settings.refreshAfterCodexTask = false
        let restored = AppSettings(defaults: defaults)
        expect(restored.refreshInterval == .thirtySeconds && !restored.refreshAfterCodexTask,
               "刷新偏好必须跨启动保留")
        defaults.set("invalid", forKey: "codexU.refreshInterval")
        expect(AppSettings(defaults: defaults).refreshInterval == .automatic, "无效周期应回退到自动")
        expect(UsageRefreshInterval.automatic.seconds(foreground: true) == 300
            && UsageRefreshInterval.automatic.seconds(foreground: false) == 900,
               "自动周期应保持前台 5 分钟和后台 15 分钟")
        for interval in UsageRefreshInterval.allCases where interval != .automatic {
            expect(interval.seconds(foreground: true) == interval.seconds(foreground: false), "固定周期应在后台生效")
        }

        // 长周期等待必须能被手动刷新提前，忙时请求不能并发或丢失
        var calls = 0
        var finish: (() -> Void)?
        let scheduler = CoalescingRefreshScheduler(queue: .main) { done in
            calls += 1
            finish = done
        }
        scheduler.request(after: 30)
        scheduler.request(after: 0.01)
        scheduler.request(after: 0.01)
        expect(waitUntil { calls == 1 }, "紧急刷新必须提前到下一次周期之前")
        for _ in 0..<100 { scheduler.request() }
        expect(calls == 1, "运行中不得启动并行刷新")
        finish?()
        expect(waitUntil { calls == 2 }, "运行中收到的多个请求必须合并为一次后续刷新")
        finish?()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        expect(calls == 2, "完成后不得残留额外刷新")
        scheduler.request(after: 0.02)
        scheduler.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        expect(calls == 2, "关闭或切换统计上下文后不得执行旧请求")
        expect(CodexAppServerTaskClient.testCompletionNotifications(), "任务通知应支持分片输入、去重并排除非结束状态和请求")

        // 使用真实 UsageStore 与协调器，验证后台任务结束的完整触发路径
        let client = TestTaskClient()
        let reads = ReadCounter()
        let loaders = HomeLoaders(restore: { _ in nil }, quota: { _, _ in reads.increment(); return nil },
            tasks: { _, _ in nil }, local: { _, _ in nil }, leadership: { _ in .empty }, save: { _, _ in })
        let coordinator = UsageRefreshCoordinator(loaders: loaders, foregroundDeadline: 0.04, historyDelay: 0.01)
        let store = UsageStore(codexTaskClient: client, homeCoordinator: coordinator)
        store.start()
        expect(waitUntil { reads.value == 2 }, "启动应分别读取两个 Runtime")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for _ in 0..<20 { client.onTaskCompleted?() }
        expect(waitUntil { reads.value == 4 }, "后台任务结束应合并触发一次完整刷新")
        store.updateRefreshPreferences(interval: .oneMinute, afterCodexTask: false)
        client.onTaskCompleted?()
        RunLoop.main.run(until: Date().addingTimeInterval(1.05))
        expect(reads.value == 4, "关闭任务结束刷新后不得继续触发")
        store.updateRefreshPreferences(interval: .oneMinute, afterCodexTask: true)
        client.onTaskCompleted?()
        store.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(1.05))
        expect(reads.value == 4, "退出必须取消待执行的任务结束刷新")

        if failures.isEmpty { print("refresh scheduling self-test passed"); return true }
        failures.forEach { print("refresh scheduling self-test failed: \($0)") }
        return false
    }

    private final class TestTaskClient: CodexTaskEventClient {
        var onSnapshot: ((CodexTaskLiveSnapshot) -> Void)?
        var onTaskCompleted: (() -> Void)?
        func start(reason: TaskConnectionReason) {}
        func stopIfIdle() {}
        func stop() {}
        func refreshThreads() {}
    }

    private final class ReadCounter {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    }
}
