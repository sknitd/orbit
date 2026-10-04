import Foundation

public struct DownloadFileObservation: Equatable, Sendable {
    public let url: URL
    public let identity: String
    public let bytes: Int64?
    public let modifiedAt: Date
    public let isDirectory: Bool
    public init(url: URL, identity: String, bytes: Int64?, modifiedAt: Date, isDirectory: Bool = false) {
        self.url = url; self.identity = identity; self.bytes = bytes.flatMap { $0 >= 0 ? $0 : nil }
        self.modifiedAt = modifiedAt; self.isDirectory = isDirectory
    }
    public var isPartial: Bool { ["crdownload", "part", "partial", "download"].contains(url.pathExtension.lowercased()) }
    public var expectedOutput: URL { url.deletingPathExtension() }
}
public enum DownloadActivityState: String, Sendable { case active, completed, removed, paused }
public enum DownloadActivityError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let value) = self { value } else { nil } }
}
public struct DownloadActivity: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public var state: DownloadActivityState
    public var byteCount: Int64?
    public let startedAt: Date
    public var updatedAt: Date
    public var outputURL: URL?
    /// This total is supplied explicitly by the user, never inferred from current file size.
    public var expectedTotalBytes: Int64? = nil
    public var bytesPerSecond: Double? = nil
    public var progress: Double? {
        guard state == .active, let total = expectedTotalBytes, total > 0,
              let bytes = byteCount, bytes >= 0, bytes <= total else { return nil }
        return Double(bytes) / Double(total)
    }
    public var estimatedRemaining: Double? {
        guard progress != nil, let total = expectedTotalBytes, let bytes = byteCount,
              let rate = bytesPerSecond, rate.isFinite, rate > 0 else { return nil }
        let seconds = Double(total - bytes) / rate
        return seconds.isFinite && (0...604_800).contains(seconds) ? seconds : nil
    }
}
public struct DownloadActivityTracker: Sendable {
    public private(set) var activities: [DownloadActivity] = []
    private var previous: [URL: DownloadFileObservation] = [:]
    public init() {}
    public mutating func observe(_ files: [DownloadFileObservation], at date: Date = Date()) {
        let current = Dictionary(files.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { first, _ in first })
        for file in files where file.isPartial {
            let id = file.url.standardizedFileURL.path
            if let index = activities.firstIndex(where: { $0.id == id && $0.state != .completed }) {
                let elapsed = date.timeIntervalSince(activities[index].updatedAt)
                if let earlier = previous[file.url.standardizedFileURL], earlier.identity == file.identity,
                   let old = earlier.bytes, let bytes = file.bytes, bytes >= old, elapsed.isFinite, (0.01...60).contains(elapsed) {
                    let rate = Double(bytes - old) / elapsed
                    activities[index].bytesPerSecond = rate.isFinite ? rate : nil
                } else { activities[index].bytesPerSecond = nil }
                activities[index].state = .active; activities[index].byteCount = file.bytes; activities[index].updatedAt = date
            } else {
                activities.insert(.init(id: id, name: file.expectedOutput.lastPathComponent, state: .active,
                                        byteCount: file.bytes, startedAt: date, updatedAt: date, outputURL: nil), at: 0)
            }
        }
        for prior in previous.values where prior.isPartial && current[prior.url.standardizedFileURL] == nil {
            guard let index = activities.firstIndex(where: { $0.id == prior.url.standardizedFileURL.path && $0.state == .active }) else { continue }
            let target = prior.expectedOutput.standardizedFileURL
            if let completed = current[target], !completed.isPartial, !completed.isDirectory,
               previous[target] != completed {
                activities[index].state = .completed; activities[index].byteCount = completed.bytes
                activities[index].outputURL = completed.url
            } else { activities[index].state = .removed }
            activities[index].updatedAt = date
        }
        activities = Array(activities.sorted { $0.updatedAt > $1.updatedAt }.prefix(50))
        previous = current
    }
    public mutating func pause() {
        for index in activities.indices where activities[index].state == .active { activities[index].state = .paused; activities[index].bytesPerSecond = nil }
        previous = [:]
    }
    public mutating func setExpectedTotal(_ bytes: Int64?, forID id: String) throws {
        guard let index = activities.firstIndex(where: { $0.id == id && $0.state == .active }) else { throw DownloadActivityError.invalid("Choose a currently observed partial file.") }
        if let bytes {
            guard bytes > 0, bytes <= 1_125_899_906_842_624, bytes >= (activities[index].byteCount ?? 0) else {
                throw DownloadActivityError.invalid("Expected total must be a positive whole number of bytes, at least the observed size and no more than 1 PiB.")
            }
        }
        activities[index].expectedTotalBytes = bytes
    }
    public mutating func clearRetained() { activities.removeAll { $0.state != .active && $0.state != .paused } }
}
