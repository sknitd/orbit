import Combine
import Foundation

@MainActor
final class CornerTimedPauseController: ObservableObject {
    @Published private(set) var until: Date?
    @Published private(set) var errorMessage: String?
    var isPaused: Bool { until != nil }
    var onPause: (@MainActor () -> Void)?
    var onResume: (@MainActor () -> Void)?
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Double) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.now = now; self.sleep = sleep
    }
    deinit { task?.cancel() }
    func pause(minutes: Int) {
        guard [5, 15, 60].contains(minutes) else { errorMessage = "Choose a pause of 5, 15, or 60 minutes."; return }
        cancel(); let token = UUID(); generation = token
        let duration = Double(minutes * 60); until = now().addingTimeInterval(duration); errorMessage = nil
        onPause?()
        let sleeper = sleep
        task = Task { @MainActor [weak self] in
            do { try await sleeper(duration) } catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.until = nil; self.task = nil; self.onResume?()
        }
    }
    func resumeNow() { guard isPaused else { return }; cancel(); onResume?() }
    /// A manual monitoring-off choice cancels the timer without invoking resume.
    func cancel() { generation = UUID(); task?.cancel(); task = nil; until = nil }
    func shutdown() { cancel() }
}
