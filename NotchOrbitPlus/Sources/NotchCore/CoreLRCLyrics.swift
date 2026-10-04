import Foundation

/// Metadata sent only when the user explicitly requests an LRCLIB lookup.
public struct CoreLyricsQuery: Codable, Sendable, Hashable {
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Double

    public init(title: String, artist: String, album: String, duration: Double) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        self.duration = duration
    }

    public func requestURL() throws -> URL {
        guard Self.validText(title), Self.validText(artist), Self.validText(album, allowEmpty: true),
              duration.isFinite, (1...3_600).contains(duration) else { throw CoreLyricsError.invalidQuery }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/get"
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(duration))
        ]
        // LRCLIB decodes query parameters as form data, where an unescaped + is a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw CoreLyricsError.invalidQuery }
        return url
    }

    fileprivate static func validText(_ value: String, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.isEmpty) && value.count <= 512
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

public enum CoreLyricsKind: String, Sendable, Hashable {
    case synced, plain, instrumental
}

public enum CoreLyricsError: LocalizedError, Sendable, Equatable {
    case invalidQuery, invalidResponse, mismatchedTrack, noLyrics, oversized

    public var errorDescription: String? {
        switch self {
        case .invalidQuery: "A song title, artist, and duration between 1 and 3600 seconds are required for lyrics lookup."
        case .invalidResponse: "LRCLIB returned lyrics that could not be read safely."
        case .mismatchedTrack: "The LRCLIB result did not match this song and duration."
        case .noLyrics: "LRCLIB has no lyrics for this matching song."
        case .oversized: "The lyrics response exceeded the 2 MB limit."
        }
    }
}

public struct CoreLyricsResult: Sendable, Hashable {
    public static let maximumResponseBytes = 2 * 1_024 * 1_024
    public let id: Int64
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Double
    public let kind: CoreLyricsKind
    public let lines: [OrbitLRCLine]
    public let plainLyrics: String?

    /// Reads only an exact metadata lookup response, never a search or generated fallback.
    public static func decode(_ data: Data, for query: CoreLyricsQuery) throws -> Self {
        _ = try query.requestURL()
        guard data.count <= maximumResponseBytes else { throw CoreLyricsError.oversized }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw CoreLyricsError.invalidResponse }
        guard response.id > 0, let rawTitle = response.trackName, let rawArtist = response.artistName,
              let duration = response.duration, duration.isFinite, (1...3_600).contains(duration) else {
            throw CoreLyricsError.invalidResponse
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = rawArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (response.albumName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard CoreLyricsQuery.validText(title), CoreLyricsQuery.validText(artist),
              CoreLyricsQuery.validText(album, allowEmpty: true) else { throw CoreLyricsError.invalidResponse }
        guard equalMetadata(title, query.title), equalMetadata(artist, query.artist),
              abs(duration - query.duration) <= 2 else { throw CoreLyricsError.mismatchedTrack }
        if response.instrumental {
            return Self(id: response.id, title: title, artist: artist, album: album, duration: duration,
                        kind: .instrumental, lines: [], plainLyrics: nil)
        }
        let plain = nonempty(response.plainLyrics)
        if let synced = nonempty(response.syncedLyrics) {
            let lines = OrbitLRCParser.parse(synced)
            guard !lines.isEmpty, lines.contains(where: { !$0.text.isEmpty }),
                  lines.allSatisfy({ $0.time.isFinite && $0.time <= duration + 2 }) else {
                throw CoreLyricsError.invalidResponse
            }
            return Self(id: response.id, title: title, artist: artist, album: album, duration: duration,
                        kind: .synced, lines: lines, plainLyrics: plain)
        }
        if let plain {
            return Self(id: response.id, title: title, artist: artist, album: album, duration: duration,
                        kind: .plain, lines: [], plainLyrics: plain)
        }
        throw CoreLyricsError.noLyrics
    }

    private static func equalMetadata(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private struct Response: Decodable {
        let id: Int64
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?
    }
}
