import Foundation
import XCTest
import CornerCore
@testable import CornerOrbit

final class CornerWindowActionTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testConstructionUnsupportedAndCanceledRunDoNotRequestAccess() async throws {
        let provider = CornerWindowFixture()
        let runner = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        XCTAssertTrue(provider.events.isEmpty)
        do { _ = try await runner.run(.finder); XCTFail("An unrelated action must fail before permission") }
        catch is CornerWindowFailure {}
        let operation = Task { @MainActor in try await runner.run(.windowLeft) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("An already canceled action must not start") }
        catch is CancellationError {}
        XCTAssertTrue(provider.events.isEmpty)
    }
    @MainActor
    func testExplicitDeniedAccessAndOwnWindowNeverMutateOrResolveFurther() async throws {
        let provider = CornerWindowFixture()
        provider.trusted = false
        let runner = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        do { _ = try await runner.run(.windowLeft); XCTFail("Access is required") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Accessibility")) }
        XCTAssertEqual(provider.events, ["permission"])
        provider.trusted = true; provider.events = []
        provider.window = .init(id: UUID(), processID: 99)
        do { _ = try await runner.run(.windowLeft); XCTFail("Own window must be excluded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("own windows")) }
        XCTAssertEqual(provider.events, ["permission", "focus"])
    }
    @MainActor
    func testSnapAndRestoreUseVerifiedFramesAndRetainOriginal() async throws {
        let provider = CornerWindowFixture()
        let actions = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        let original = provider.currentFrame
        _ = try await actions.run(.windowLeft)
        let left = CornerRect(x: 0, y: 25, width: 720, height: 827)
        XCTAssertEqual(provider.currentFrame, left)
        _ = try await actions.run(.windowRight)
        XCTAssertEqual(provider.currentFrame, .init(x: 720, y: 25, width: 720, height: 827))
        _ = try await actions.run(.windowRestore)
        XCTAssertEqual(provider.currentFrame, left)
        _ = try await actions.run(.windowRestore)
        XCTAssertEqual(provider.currentFrame, original)
        do { _ = try await actions.run(.windowRestore); XCTFail("Restored history must be consumed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No previous frame")) }
    }
    @MainActor
    func testCenterMaximizeAndNextDisplayUseNegativeOriginGeometry() async throws {
        let provider = CornerWindowFixture()
        let runner = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        _ = try await runner.run(.windowCenter)
        XCTAssertEqual(provider.currentFrame, .init(x: 470, y: 238.5, width: 500, height: 400))
        _ = try await runner.run(.windowMaximize)
        XCTAssertEqual(provider.currentFrame, .init(x: 0, y: 25, width: 1440, height: 827))
        _ = try await runner.run(.windowRestore)
        provider.screens.append(.init(id: "left", frame: .init(x: -1920, y: -200, width: 1920, height: 1080), visibleFrame: .init(x: -1920, y: -152, width: 1920, height: 1007)))
        _ = try await runner.run(.windowNextDisplay)
        XCTAssertEqual(provider.currentFrame.width, 500); XCTAssertEqual(provider.currentFrame.height, 400)
        XCTAssertLessThan(provider.currentFrame.x, 0)
        _ = try await runner.run(.windowRestore)
        XCTAssertEqual(provider.currentFrame, .init(x: 470, y: 238.5, width: 500, height: 400))
    }
    @MainActor
    func testPartialWriteAndConstrainedFrameRollbackWithoutConsumingHistory() async throws {
        let provider = CornerWindowFixture()
        let runner = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        let original = provider.currentFrame
        _ = try await runner.run(.windowLeft)
        let left = provider.currentFrame
        provider.positionFailures = 1
        do { _ = try await runner.run(.windowRight); XCTFail("Partial write must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("previous frame was restored")) }
        XCTAssertEqual(provider.currentFrame, left)
        _ = try await runner.run(.windowRestore)
        XCTAssertEqual(provider.currentFrame, original)
        provider.constrainNextSize = true
        do { _ = try await runner.run(.windowMaximize); XCTFail("A constrained window must not report success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("constrained")) }
        XCTAssertEqual(provider.currentFrame, original)
    }
    @MainActor
    func testCanceledPartialMutationRecoversAndConcurrentActionsAreRefused() async throws {
        let provider = CornerWindowFixture()
        let runner = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        let original = provider.currentFrame
        provider.pauseNextPosition = true
        let operation = Task { @MainActor in try await runner.run(.windowLeft) }
        for _ in 0..<100 {
            if provider.positionIsWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(provider.positionIsWaiting)
        do { _ = try await runner.run(.windowRight); XCTFail("Concurrent mutation must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("still running")) }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {}
        XCTAssertEqual(provider.currentFrame, original)
        _ = try await runner.run(.windowRight)
        XCTAssertEqual(provider.currentFrame.x, 720)
    }
    @MainActor
    func testMinimizeAndFullscreenReadActualStateAndRollbackRejectedChange() async throws {
        let provider = CornerWindowFixture()
        let runner = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        _ = try await runner.run(.windowFullscreen); XCTAssertTrue(provider.fullscreen)
        _ = try await runner.run(.windowFullscreen); XCTAssertFalse(provider.fullscreen)
        _ = try await runner.run(.windowMinimize); XCTAssertTrue(provider.minimized)
        let before = provider.flagWrites
        _ = try await runner.run(.windowMinimize)
        XCTAssertEqual(provider.flagWrites, before)
        provider.minimized = false; provider.flagFailures = 1
        do { _ = try await runner.run(.windowFullscreen); XCTFail("Partial flag failure must be rolled back") }
        catch is CornerWindowFailure {}
        XCTAssertFalse(provider.fullscreen)
    }
    @MainActor
    func testHideRestoreExcludeOwnAlreadyHiddenAndNonregularWithoutAX() async throws {
        let provider = CornerWindowFixture()
        provider.applications = [provider.app(1), provider.app(2, hidden: true), provider.app(3, regular: false), provider.app(99)]
        let runner = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        _ = try await runner.run(.hideOtherApps)
        XCTAssertEqual(provider.hiddenCalls, [1]); XCTAssertFalse(provider.events.contains("permission"))
        _ = try await runner.run(.restoreHiddenApps)
        XCTAssertEqual(provider.unhiddenCalls, [1])
        XCTAssertTrue(try XCTUnwrap(provider.applications.first { $0.processID == 2 }).isHidden)
        _ = try await runner.run(.restoreHiddenApps)
        XCTAssertEqual(provider.unhiddenCalls, [1])
    }
    @MainActor
    func testReusedProcessIsNotUnhiddenAndFailedRestoreCanBeRetried() async throws {
        let provider = CornerWindowFixture()
        provider.applications = [provider.app(1), provider.app(2)]
        let runner = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        _ = try await runner.run(.hideOtherApps)
        provider.applications[0] = provider.app(1, hidden: true, birth: 999)
        provider.unhideFailures = [2]
        let failed = try await runner.run(.restoreHiddenApps)
        XCTAssertTrue(failed.contains("could not be restored"))
        XCTAssertEqual(provider.unhiddenCalls, [2])
        provider.unhideFailures = []
        _ = try await runner.run(.restoreHiddenApps)
        XCTAssertEqual(provider.unhiddenCalls, [2, 2])
        XCTAssertTrue(provider.applications[0].isHidden)
    }
    @MainActor
    func testBoundedFrameHistoryKeepsOriginalAndEvictsOldWindowRecords() async throws {
        let provider = CornerWindowFixture()
        let runner = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        let original = provider.currentFrame
        for index in 0..<12 { _ = try await runner.run(index.isMultiple(of: 2) ? .windowLeft : .windowRight) }
        for _ in 0..<8 { _ = try await runner.run(.windowRestore) }
        XCTAssertEqual(provider.currentFrame, original)
        do { _ = try await runner.run(.windowRestore); XCTFail("History must be bounded and consumed") }
        catch is CornerWindowFailure {}
        let firstWindow = provider.window
        for _ in 0..<17 {
            provider.window = .init(id: UUID(), processID: 10)
            provider.currentFrame = original
            _ = try await runner.run(.windowLeft)
        }
        provider.window = firstWindow
        do { _ = try await runner.run(.windowRestore); XCTFail("Old window records must be evicted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No previous frame")) }
    }
    @MainActor
    func testCancelDuringHideRestoresOnlyTheCurrentOperationOwnedChanges() async throws {
        let provider = CornerWindowFixture()
        provider.applications = [provider.app(1), provider.app(2), provider.app(3, hidden: true)]
        provider.cancelOnNextHide = true
        let runner = CornerWindowActionRunner(provider: provider, ownProcessID: 99)
        let operation = Task { @MainActor in try await runner.run(.hideOtherApps) }
        do { _ = try await operation.value; XCTFail("Canceled Hide must recover") }
        catch is CancellationError {}
        XCTAssertEqual(provider.hiddenCalls, [1]); XCTAssertEqual(provider.unhiddenCalls, [1])
        XCTAssertFalse(provider.applications[0].isHidden)
        XCTAssertFalse(provider.applications[1].isHidden)
        XCTAssertTrue(provider.applications[2].isHidden)
        _ = try await runner.run(.restoreHiddenApps)
        XCTAssertEqual(provider.unhiddenCalls, [1])
        XCTAssertFalse(provider.events.contains("permission"))
    }
}

@MainActor
private final class CornerWindowFixture: CornerWindowProviding {
    var events: [String] = []
    var trusted = true
    var window = CornerWindowHandle(id: UUID(), processID: 10)
    var currentFrame = CornerRect(x: 200, y: 100, width: 500, height: 400)
    var minimized = false, fullscreen = false
    var positionFailures = 0, flagFailures = 0, flagWrites = 0
    var constrainNextSize = false, pauseNextPosition = false, positionIsWaiting = false
    var screens: [CornerWindowDisplay] = [.init(id: "main", frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 48, width: 1440, height: 827))]
    var applications: [CornerWindowApplication] = []
    var hiddenCalls: [Int32] = [], unhiddenCalls: [Int32] = []
    var unhideFailures: Set<Int32> = []
    var cancelOnNextHide = false
    func requestAccessibility() -> Bool { events.append("permission"); return trusted }
    func focusedWindow() async throws -> CornerWindowHandle { events.append("focus"); return window }
    func frame(of window: CornerWindowHandle) async throws -> CornerRect { events.append("frame"); return currentFrame }
    func setPosition(_ point: CornerPoint, of window: CornerWindowHandle) async throws {
        events.append("position")
        if pauseNextPosition {
            pauseNextPosition = false; positionIsWaiting = true
            defer { positionIsWaiting = false }
            try await Task.sleep(for: .seconds(5))
        }
        currentFrame = .init(x: point.x, y: point.y, width: currentFrame.width, height: currentFrame.height)
        if positionFailures > 0 { positionFailures -= 1; throw CornerWindowFailure.unavailable("Fixture partial position write.") }
    }
    func setSize(width: Double, height: Double, of window: CornerWindowHandle) async throws {
        events.append("size")
        let actualWidth = constrainNextSize ? width + 20 : width
        constrainNextSize = false
        currentFrame = .init(x: currentFrame.x, y: currentFrame.y, width: actualWidth, height: height)
    }
    func flag(_ flag: CornerWindowFlag, of window: CornerWindowHandle) async throws -> Bool { flag == .minimized ? minimized : fullscreen }
    func setFlag(_ flag: CornerWindowFlag, value: Bool, of window: CornerWindowHandle) async throws {
        flagWrites += 1
        if flag == .minimized { minimized = value } else { fullscreen = value }
        if flagFailures > 0 { flagFailures -= 1; throw CornerWindowFailure.unavailable("Fixture partial flag write.") }
    }
    func displays() -> [CornerWindowDisplay] { screens }
    func runningApplications() -> [CornerWindowApplication] { applications }
    func app(_ pid: Int32, hidden: Bool = false, regular: Bool = true, birth: TimeInterval = 1) -> CornerWindowApplication {
        .init(processID: pid, launchDate: Date(timeIntervalSince1970: birth), name: "Fixture \(pid)", isRegular: regular, isHidden: hidden)
    }
    func hide(_ application: CornerWindowApplication) async -> Bool {
        hiddenCalls.append(application.processID)
        update(application, hidden: true)
        if cancelOnNextHide { cancelOnNextHide = false; withUnsafeCurrentTask { $0?.cancel() } }
        return true
    }
    func unhide(_ application: CornerWindowApplication) async -> Bool {
        unhiddenCalls.append(application.processID)
        guard !unhideFailures.contains(application.processID) else { return false }
        update(application, hidden: false); return true
    }
    private func update(_ application: CornerWindowApplication, hidden: Bool) {
        guard let index = applications.firstIndex(where: { $0.processID == application.processID && $0.launchDate == application.launchDate }) else { return }
        applications[index] = .init(processID: application.processID, launchDate: application.launchDate, name: application.name, isRegular: application.isRegular, isHidden: hidden)
    }
}
