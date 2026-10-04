import Foundation
import XCTest
@testable import NotchOrbitPlus

final class MediaRemoteSourceTests: XCTestCase, @unchecked Sendable {
    func testUnavailableFrameworkFailsGracefullyOnlyAfterExplicitRead() async throws {
        // Creating the adapter performs no dlopen or private request. A path
        // fixture lets this test exercise a real load failure without players.
        let source = PlusMediaRemoteSource(frameworkPath: "/nonexistent/NotchOrbitMediaRemote.fixture")
        do {
            _ = try await source.read()
            XCTFail("Missing framework must fail")
        } catch PlusMediaRemoteError.unavailable {
            XCTAssertTrue(PlusMediaRemoteError.unavailable.localizedDescription.contains("Music or Spotify"))
        }
    }
    func testCancellationBeforeReadAvoidsPrivateFrameworkLoad() async {
        let source = PlusMediaRemoteSource(frameworkPath: "/nonexistent/NotchOrbitMediaRemote.fixture")
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.read()
        }
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Unexpected failure: \(error)") }
    }
    func testMissingSymbolsAndUnknownCommandsFailWithoutPlayback() async throws {
        let source = PlusMediaRemoteSource(frameworkPath: "/usr/lib/libSystem.B.dylib")
        do { _ = try await source.read(); XCTFail("System C library has no MediaRemote symbols") }
        catch PlusMediaRemoteError.missingSymbols {}
        do { try await source.command("arbitrary command"); XCTFail("Unknown command must fail") }
        catch PlusMediaRemoteError.rejectedCommand {}
    }
    func testLatePrivateCallbackCannotResumeTimedOutRequestTwice() async throws {
        let reply = PlusMediaRemoteReply<Int>()
        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(reply.install(continuation, timeout: 0.01))
            }
            XCTFail("Expected timeout")
        } catch PlusMediaRemoteError.timeout {}
        reply.complete(.success(42))
        reply.complete(.failure(CancellationError()))
    }
    func testCancellationBeforeContinuationInstallationWinsOnce() async throws {
        let reply = PlusMediaRemoteReply<Int>()
        reply.complete(.failure(CancellationError()))
        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(reply.install(continuation, timeout: 0.01))
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        reply.complete(.success(42))
    }
}
