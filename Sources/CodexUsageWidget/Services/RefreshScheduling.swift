import Foundation

enum UsageRefreshInterval: String, CaseIterable {
    case automatic
    case thirtySeconds
    case oneMinute
    case fiveMinutes
    case fifteenMinutes

    func seconds(foreground: Bool) -> TimeInterval {
        switch self {
        case .automatic: return foreground ? 5 * 60 : 15 * 60
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        }
    }

    func title(_ language: WidgetLanguage) -> String {
        switch self {
        case .automatic: return language.text("自动（前台 5 分钟 / 后台 15 分钟）", "Auto (5 min visible / 15 min hidden)")
        case .thirtySeconds: return language.text("30 秒", "30 seconds")
        case .oneMinute: return language.text("1 分钟", "1 minute")
        case .fiveMinutes: return language.text("5 分钟", "5 minutes")
        case .fifteenMinutes: return language.text("15 分钟", "15 minutes")
        }
    }
}

/// 在所属串行队列上合并请求，执行中收到的请求只保留一次后续执行
final class CoalescingRefreshScheduler {
    private let queue: DispatchQueue
    private let action: (@escaping () -> Void) -> Void
    private var scheduled: DispatchWorkItem?
    private var scheduledAt: TimeInterval?
    private var running = false
    private var requestedWhileRunning = false
    private var generation: UInt64 = 0

    init(queue: DispatchQueue, action: @escaping (@escaping () -> Void) -> Void) {
        self.queue = queue
        self.action = action
    }

    func request(after delay: TimeInterval = 0) {
        dispatchPrecondition(condition: .onQueue(queue))
        if running {
            requestedWhileRunning = true
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + delay
        if let scheduledAt, scheduledAt <= deadline { return }
        scheduled?.cancel()
        generation &+= 1
        let token = generation
        scheduledAt = deadline
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.scheduled = nil
            self.scheduledAt = nil
            self.running = true
            self.action { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.running = false
                    let again = self.requestedWhileRunning
                    self.requestedWhileRunning = false
                    if again { self.request() }
                }
            }
        }
        scheduled = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation &+= 1
        scheduled?.cancel()
        scheduled = nil
        scheduledAt = nil
        requestedWhileRunning = false
    }
}
