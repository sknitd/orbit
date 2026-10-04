import Foundation

/// Values copied from a MediaRemote callback before crossing an actor boundary.
public struct CoreSystemMediaFields: Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: Double?
    public var elapsed: Double?
    public var playbackRate: Double?
    public var timestamp: Date?
    public var artwork: Data?
    public init(title: String? = nil, artist: String? = nil, album: String? = nil,
                duration: Double? = nil, elapsed: Double? = nil, playbackRate: Double? = nil,
                timestamp: Date? = nil, artwork: Data? = nil) {
        self.title = title; self.artist = artist; self.album = album
        self.duration = duration; self.elapsed = elapsed; self.playbackRate = playbackRate
        self.timestamp = timestamp; self.artwork = artwork
    }
}

public struct CoreSystemMediaReading: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Double
    public let position: Double
    public let positionAvailable: Bool
    public let playing: Bool
    public let playbackStateKnown: Bool
    public let artwork: Data?

    public init?(fields: CoreSystemMediaFields, playing: Bool?, now: Date) {
        guard let title = fields.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              title.count <= 4_096 else { return nil }
        self.title = title
        artist = String((fields.artist ?? "").prefix(4_096))
        album = String((fields.album ?? "").prefix(4_096))
        duration = Self.nonnegative(fields.duration)
        let rate = fields.playbackRate.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        playbackStateKnown = playing != nil || rate != nil
        self.playing = playing ?? ((rate ?? 0) > 0)
        var position = Self.nonnegative(fields.elapsed)
        positionAvailable = fields.elapsed.map { $0.isFinite && $0 >= 0 } ?? false
        // Metadata reports elapsed time at its timestamp. Advance only from
        // actual finite rate/state; a future or invalid timestamp never rewinds.
        if positionAvailable, self.playing, let rate, let timestamp = fields.timestamp {
            let interval = now.timeIntervalSince(timestamp)
            if interval.isFinite, interval > 0 {
                let current = position + interval * rate
                if current.isFinite { position = current }
            }
        }
        self.position = duration > 0 ? min(duration, position) : position
        artwork = fields.artwork.flatMap { !$0.isEmpty && $0.count <= 4_194_304 ? $0 : nil }
    }
    private static func nonnegative(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return max(0, value)
    }
}
