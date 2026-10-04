import Foundation
import XCTest
import Darwin
@testable import NotchOrbitPlus

final class CodexQuotaRunnerTests: XCTestCase, @unchecked Sendable {
    func testRealSubprocessUsesOnlyDocumentedQuotaHandshake() async throws {
        let fixture = try makeFixture(script: """
        import json,sys
        assert sys.argv[1:] == ['app-server']
        initialize=json.loads(sys.stdin.readline())
        assert initialize['method']=='initialize' and initialize['id']==1
        assert initialize['params']['capabilities']['explicitGatewayOauth'] is True
        print(json.dumps({'id':1,'result':{}}),flush=True)
        assert json.loads(sys.stdin.readline())=={'method':'initialized'}
        request=json.loads(sys.stdin.readline())
        assert request=={'id':2,'method':'account/rateLimits/read'}
        print(json.dumps({'id':2,'result':{'rateLimits':{'primary':{'usedPercent':37,'windowDurationMins':300,'resetsAt':1791118800}}}}),flush=True)
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let quota = try await OnlineCodexQuotaReader.read(executable: fixture.executable)
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(quota.windows[0].usedPercent, 37)
        XCTAssertEqual(quota.windows[0].remainingPercent, 63)
        XCTAssertEqual(quota.windows[0].label, "5-hour session")
        XCTAssertEqual(quota.windows[0].resetsAt?.timeIntervalSince1970, 1_791_118_800)
    }

    func testClosedCLIInputProducesAnErrorWithoutCrashingTheApplication() async throws {
        let fixture = try makeFixture(script: """
        import json,os,sys,time
        json.loads(sys.stdin.readline())
        os.close(0)
        print(json.dumps({'id':1,'result':{}}),flush=True)
        time.sleep(60)
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await OnlineCodexQuotaReader.read(executable: fixture.executable)
            XCTFail("An exited CLI must not fabricate quota")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testCancellationTerminatesItsOwnPendingSubprocess() async throws {
        let fixture = try makeFixture(script: """
        import json,os,sys,time
        with open(os.path.join(os.path.dirname(sys.argv[0]),'pid.txt'),'w') as handle: handle.write(str(os.getpid()))
        json.loads(sys.stdin.readline())
        print(json.dumps({'id':1,'result':{}}),flush=True)
        time.sleep(60)
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let worker = Task { try await OnlineCodexQuotaReader.read(executable: fixture.executable) }
        let pidURL = fixture.directory.appendingPathComponent("pid.txt")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidURL.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidURL, encoding: .utf8)))
        worker.cancel()
        do {
            _ = try await worker.value
            XCTFail("A cancelled read must fail")
        } catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error.localizedDescription)") }
        for _ in 0..<50 {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let status = Darwin.kill(pid, 0)
        let errorCode = errno
        XCTAssertEqual(status, -1)
        XCTAssertEqual(errorCode, ESRCH)
    }

    private func makeFixture(script: String) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchOrbitPlus-RPC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let executable = directory.appendingPathComponent("fixture-codex")
        try ("#!/usr/bin/env python3\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }
}
