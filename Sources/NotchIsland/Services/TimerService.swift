import Foundation

/// A single countdown (Pomodoro-style) that lives in the notch.
@MainActor
final class TimerService: ObservableObject {
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var total: TimeInterval = 25 * 60
    @Published private(set) var label = "Focus"

    /// Called with the timer's label when it reaches zero.
    var onFinish: ((String) -> Void)?
    private var fire: Timer?

    var isRunning: Bool { endDate != nil }
    var isActive: Bool { endDate != nil || pausedRemaining != nil }

    func remaining(at now: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? total
    }

    var progress: Double { total > 0 ? 1 - remaining() / total : 0 }

    func start(minutes: Double, label: String) {
        total = minutes * 60
        self.label = label
        pausedRemaining = nil
        run(for: total)
    }

    func togglePause() {
        if let endDate {
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            self.endDate = nil
            fire?.invalidate()
        } else if let left = pausedRemaining {
            pausedRemaining = nil
            run(for: left)
        }
    }

    func add(minutes: Double) {
        let delta = minutes * 60
        total += delta
        if let endDate { run(for: max(1, endDate.timeIntervalSinceNow + delta)) }
        else if let left = pausedRemaining { pausedRemaining = max(1, left + delta) }
    }

    func reset() {
        fire?.invalidate()
        endDate = nil
        pausedRemaining = nil
    }

    private func run(for seconds: TimeInterval) {
        fire?.invalidate()
        endDate = Date().addingTimeInterval(seconds)
        fire = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let label = self.label
                self.reset()
                self.onFinish?(label)
            }
        }
        fire?.tolerance = 0.1
    }
}
