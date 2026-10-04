import Foundation
import Dispatch
import Darwin
import NotchCore

struct PlusMediaRemoteReading: Sendable {
    let metadata: CoreSystemMediaReading?
    let controlsAvailable: Bool
}

protocol PlusSystemMediaSource: Sendable {
    func read() async throws -> PlusMediaRemoteReading
    func command(_ command: String) async throws
}

enum PlusMediaRemoteError: LocalizedError {
    case unavailable, missingSymbols, timeout, rejectedCommand
    var errorDescription: String? {
        switch self {
        case .unavailable: "System playback access is unavailable on this Mac. Connect Music or Spotify instead."
        case .missingSymbols: "This macOS version does not expose the required system playback functions. Connect Music or Spotify instead."
        case .timeout: "System playback did not respond. macOS may restrict MediaRemote access; connect Music or Spotify instead."
        case .rejectedCommand: "The current system player did not accept this playback command."
        }
    }
}

/// A reply, timeout, and cancellation race to consume one continuation. The
/// private framework has no cancellation API; late replies are safely ignored.
final class PlusMediaRemoteReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var timer: DispatchWorkItem?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, any Error>, timeout: Double) -> Bool {
        lock.lock()
        if finished {
            let result = self.result!; lock.unlock()
            continuation.resume(with: result); return false
        }
        self.continuation = continuation
        let timer = DispatchWorkItem { [weak self] in self?.complete(.failure(PlusMediaRemoteError.timeout)) }
        self.timer = timer
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        return true
    }
    func complete(_ result: Result<Value, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; self.result = result
        let continuation = self.continuation; self.continuation = nil
        let timer = self.timer; self.timer = nil
        lock.unlock()
        timer?.cancel(); continuation?.resume(with: result)
    }
}

/// Direct in-process MediaRemote. No static framework dependency, entitlement
/// workaround, notification registration, or calls during initialization.
/// Sources documenting this private ABI and its 15.4+ restriction:
/// https://github.com/ungive/mediaremote-adapter/blob/master/src/private/MediaRemote.h
/// https://github.com/ungive/mediaremote-adapter#motivation
actor PlusMediaRemoteSource: PlusSystemMediaSource {
    private typealias GetInfo = @convention(c) @Sendable (DispatchQueue, @escaping @convention(block) @Sendable (NSDictionary?) -> Void) -> Void
    private typealias GetPlaying = @convention(c) @Sendable (DispatchQueue, @escaping @convention(block) @Sendable (Bool) -> Void) -> Void
    private typealias SendCommand = @convention(c) @Sendable (Int32, NSDictionary?) -> Bool
    private struct API {
        let handle: UnsafeMutableRawPointer
        let getInfo: GetInfo
        let getPlaying: GetPlaying?
        let sendCommand: SendCommand?
    }
    private var api: API?
    private let frameworkPath: String
    private let timeout: Double
    private let callbackQueue = DispatchQueue(label: "com.sknitd.NotchOrbitPlus.mediaremote", qos: .utility)

    init(frameworkPath: String = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", timeout: Double = 2.5) {
        self.frameworkPath = frameworkPath; self.timeout = timeout
    }

    func read() async throws -> PlusMediaRemoteReading {
        try Task.checkCancellation()
        let api = try load()
        let getInfo = api.getInfo; let queue = callbackQueue
        async let fields: CoreSystemMediaFields? = Self.wait(timeout: timeout) { reply in
            getInfo(queue) { dictionary in reply.complete(.success(Self.copyFields(dictionary))) }
        }
        let playing: Bool?
        if let getPlaying = api.getPlaying {
            playing = try await Self.wait(timeout: timeout) { reply in
                getPlaying(queue) { value in reply.complete(.success(value)) }
            }
        } else { playing = nil }
        let metadata = try await fields.flatMap { CoreSystemMediaReading(fields: $0, playing: playing, now: Date()) }
        try Task.checkCancellation()
        return PlusMediaRemoteReading(metadata: metadata, controlsAvailable: api.sendCommand != nil)
    }

    func command(_ command: String) throws {
        try Task.checkCancellation()
        let value: Int32
        switch command {
        case "playpause": value = 2
        case "next track": value = 4
        case "previous track": value = 5
        default: throw PlusMediaRemoteError.rejectedCommand
        }
        guard let send = try load().sendCommand else { throw PlusMediaRemoteError.missingSymbols }
        guard send(value, nil) else { throw PlusMediaRemoteError.rejectedCommand }
    }

    private func load() throws -> API {
        if let api { return api }
        guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL) else { throw PlusMediaRemoteError.unavailable }
        guard let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            dlclose(handle); throw PlusMediaRemoteError.missingSymbols
        }
        let getInfo = unsafeBitCast(symbol, to: GetInfo.self)
        let getPlaying = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying").map { unsafeBitCast($0, to: GetPlaying.self) }
        let sendCommand = dlsym(handle, "MRMediaRemoteSendCommand").map { unsafeBitCast($0, to: SendCommand.self) }
        let loaded = API(handle: handle, getInfo: getInfo, getPlaying: getPlaying, sendCommand: sendCommand)
        api = loaded
        // Keep this system image loaded for process lifetime. A timed-out private
        // callback may still execute framework code after our request completes.
        return loaded
    }

    private nonisolated static func wait<Value: Sendable>(timeout: Double,
        begin: @Sendable (PlusMediaRemoteReply<Value>) -> Void) async throws -> Value {
        let reply = PlusMediaRemoteReply<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if reply.install(continuation, timeout: timeout) { begin(reply) }
            }
        } onCancel: { reply.complete(.failure(CancellationError())) }
    }

    private nonisolated static func copyFields(_ dictionary: NSDictionary?) -> CoreSystemMediaFields? {
        guard let dictionary else { return nil }
        func number(_ key: String) -> Double? { (dictionary[key] as? NSNumber)?.doubleValue }
        return CoreSystemMediaFields(
            title: dictionary["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
            artist: dictionary["kMRMediaRemoteNowPlayingInfoArtist"] as? String,
            album: dictionary["kMRMediaRemoteNowPlayingInfoAlbum"] as? String,
            duration: number("kMRMediaRemoteNowPlayingInfoDuration"),
            elapsed: number("kMRMediaRemoteNowPlayingInfoElapsedTime"),
            playbackRate: number("kMRMediaRemoteNowPlayingInfoPlaybackRate"),
            timestamp: dictionary["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date,
            artwork: dictionary["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)
    }
}
