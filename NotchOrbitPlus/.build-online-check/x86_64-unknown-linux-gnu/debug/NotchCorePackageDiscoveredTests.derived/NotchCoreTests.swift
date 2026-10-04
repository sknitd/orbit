import XCTest
@testable import NotchCoreTests

fileprivate extension FocusTimerTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__FocusTimerTests = [
        ("testDeadlineSurvivesPersistenceAndSleepWithoutTickCounting", testDeadlineSurvivesPersistenceAndSleepWithoutTickCounting),
        ("testPauseResumePreservesRemainingAcrossLongHiddenInterval", testPauseResumePreservesRemainingAcrossLongHiddenInterval),
        ("testRestDoesNotCountAsFocusAndCancelNeverCompletes", testRestDoesNotCountAsFocusAndCancelNeverCompletes)
    ]
}

fileprivate extension NotchActivationTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__NotchActivationTests = [
        ("testEscapeOrFullCancellationCannotReactivateWithoutAnotherMouseDown", testEscapeOrFullCancellationCannotReactivateWithoutAnotherMouseDown),
        ("testFreshFileDragNeedsNoModifierAndActivatesOnlyOnce", testFreshFileDragNeedsNoModifierAndActivatesOnlyOnce),
        ("testFreshTextDragCannotActivateFileActions", testFreshTextDragCannotActivateFileActions),
        ("testHoverWithoutMouseDownAndStaleDragPasteboardCannotActivate", testHoverWithoutMouseDownAndStaleDragPasteboardCannotActivate),
        ("testLeavingAndReenteringRequiresNewPresentationGeneration", testLeavingAndReenteringRequiresNewPresentationGeneration),
        ("testMouseUpOnlyKeepsExistingDestinationPendingAndCannotAuthorizeLateInspection", testMouseUpOnlyKeepsExistingDestinationPendingAndCannotAuthorizeLateInspection),
        ("testNegativeOriginScreenIsChosenFromPointerRatherThanPrimaryScreen", testNegativeOriginScreenIsChosenFromPointerRatherThanPrimaryScreen),
        ("testOutsideEveryScreenAndZeroSizePanelCannotActivate", testOutsideEveryScreenAndZeroSizePanelCannotActivate),
        ("testScreenRemovalAndScreenLayoutChangeInvalidateOldGeneration", testScreenRemovalAndScreenLayoutChangeInvalidateOldGeneration),
        ("testSecondPasteboardWriterInvalidatesWholeMouseDown", testSecondPasteboardWriterInvalidatesWholeMouseDown),
        ("testTransportTowardLowerOptionsDoesNotCancelPresentation", testTransportTowardLowerOptionsDoesNotCancelPresentation)
    ]
}

fileprivate extension NotchDragPayloadTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__NotchDragPayloadTests = [
        ("testChangedCountChangedFileDuplicatesAndEmptyPayloadAreRejected", testChangedCountChangedFileDuplicatesAndEmptyPayloadAreRejected),
        ("testEquivalentBatchMayArriveInDifferentOrder", testEquivalentBatchMayArriveInDifferentOrder),
        ("testLocalhostFileHostIsEquivalentToLocalFilePath", testLocalhostFileHostIsEquivalentToLocalFilePath),
        ("testRemoteURLsForeignFileHostsAndURLDecorationsAreRejected", testRemoteURLsForeignFileHostsAndURLDecorationsAreRejected)
    ]
}

fileprivate extension NotchGeometryTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__NotchGeometryTests = [
        ("testAboveAnchorEndpointsCenterAndInterRingGapAreNotActions", testAboveAnchorEndpointsCenterAndInterRingGapAreNotActions),
        ("testAngularSeparatorsCannotAccidentallyChooseAnAdjacentAction", testAngularSeparatorsCannotAccidentallyChooseAnAdjacentAction),
        ("testFourSixEightAndTenWedgeCentersRunFromLeftToRightBelowAnchor", testFourSixEightAndTenWedgeCentersRunFromLeftToRightBelowAnchor),
        ("testNonfinitePointsAndInvalidBandsNeverSelect", testNonfinitePointsAndInvalidBandsNeverSelect),
        ("testOuterRingUsesItsActualOptionCount", testOuterRingUsesItsActualOptionCount),
        ("testPrimaryRadialBoundsAreInclusiveAndTheirNeighborsAreInactive", testPrimaryRadialBoundsAreInclusiveAndTheirNeighborsAreInactive)
    ]
}

fileprivate extension NotchLayoutTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__NotchLayoutTests = [
        ("testEveryOptionCenterFitsPanelAndAvoidsPhysicalNotch", testEveryOptionCenterFitsPanelAndAvoidsPhysicalNotch),
        ("testNegativeOriginsAndVerticallyStackedDisplaysFitTheirOwnVisibleFrame", testNegativeOriginsAndVerticallyStackedDisplaysFitTheirOwnVisibleFrame),
        ("testNotchlessScreenHasTopCenterFallbackAndSafeMenuGap", testNotchlessScreenHasTopCenterFallbackAndSafeMenuGap),
        ("testPhysicalNotchAndMenuBarAreOutsideThePanel", testPhysicalNotchAndMenuBarAreOutsideThePanel),
        ("testSmallVisibleScreenScalesBothRenderedAndHitTestBands", testSmallVisibleScreenScalesBothRenderedAndHitTestBands),
        ("testTransportRegionConnectsActivationTargetToLowestVisibleOption", testTransportRegionConnectsActivationTargetToLowestVisibleOption)
    ]
}

fileprivate extension OnlineServiceDataTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__OnlineServiceDataTests = [
        ("testEverySalesProviderNormalizesItsDocumentedEnvelope", testEverySalesProviderNormalizesItsDocumentedEnvelope),
        ("testFXUsesDatedRealBaseDirectionAndExcludesMissingCurrency", testFXUsesDatedRealBaseDirectionAndExcludesMissingCurrency),
        ("testSalesRejectsErrorsDuplicateIdentitiesAndInvalidMoney", testSalesRejectsErrorsDuplicateIdentitiesAndInvalidMoney),
        ("testStockQuoteDoesNotInventRateLimitedOrMissingData", testStockQuoteDoesNotInventRateLimitedOrMissingData),
        ("testStripeUTCFilteringCaptureMinorUnitsAndRefunds", testStripeUTCFilteringCaptureMinorUnitsAndRefunds),
        ("testUsageImportsExplicitLimitsMissingQuotaAndStaleness", testUsageImportsExplicitLimitsMissingQuotaAndStaleness),
        ("testUsageRejectsFutureTimestampsNegativeLimitsAndDuplicateScopes", testUsageRejectsFutureTimestampsNegativeLimitsAndDuplicateScopes),
        ("testWeatherRequiresSevenCompleteFiniteDays", testWeatherRequiresSevenCompleteFiniteDays)
    ]
}

fileprivate extension OrbitNativeParsersTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__OrbitNativeParsersTests = [
        ("testLyricsMultipleTagsFractionsOffsetAndSelection", testLyricsMultipleTagsFractionsOffsetAndSelection),
        ("testShortcutNamesCannotBecomeCLIOptions", testShortcutNamesCannotBecomeCLIOptions)
    ]
}

fileprivate extension OrbitSystemDeltasTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__OrbitSystemDeltasTests = [
        ("testCPUDeltaAndCounterRollover", testCPUDeltaAndCounterRollover),
        ("testNetworkIgnoresResetAndNewInterfaces", testNetworkIgnoresResetAndNewInterfaces)
    ]
}

fileprivate extension PlusLocalModelsTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__PlusLocalModelsTests = [
        ("testAffineTemperatureConversionAndAbsoluteZero", testAffineTemperatureConversionAndAbsoluteZero),
        ("testCatalogHasAllReferenceToolsAndRetainedFileActionsExactlyOnce", testCatalogHasAllReferenceToolsAndRetainedFileActionsExactlyOnce),
        ("testInvalidNumberCrossFamilyAndMalformedUnitAreRejected", testInvalidNumberCrossFamilyAndMalformedUnitAreRejected),
        ("testKnownImperialAndMetricLengthAndMass", testKnownImperialAndMetricLengthAndMass),
        ("testRoundTripsForEveryUnitFamily", testRoundTripsForEveryUnitFamily),
        ("testShelfPersistencePreservesManagedAndOriginalLocationsAndExpirySelection", testShelfPersistencePreservesManagedAndOriginalLocationsAndExpirySelection),
        ("testShelfRetentionInclusiveBoundaryAndFutureEntries", testShelfRetentionInclusiveBoundaryAndFutureEntries),
        ("testTaskPersistenceRetainsIdentityCompletionStarAndUnicodeTitle", testTaskPersistenceRetainsIdentityCompletionStarAndUnicodeTitle),
        ("testUSAndImperialVolumesAreDistinctAndNauticalSpeedIsExact", testUSAndImperialVolumesAreDistinctAndNauticalSpeedIsExact)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __NotchCoreTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(FocusTimerTests.__allTests__FocusTimerTests),
        testCase(NotchActivationTests.__allTests__NotchActivationTests),
        testCase(NotchDragPayloadTests.__allTests__NotchDragPayloadTests),
        testCase(NotchGeometryTests.__allTests__NotchGeometryTests),
        testCase(NotchLayoutTests.__allTests__NotchLayoutTests),
        testCase(OnlineServiceDataTests.__allTests__OnlineServiceDataTests),
        testCase(OrbitNativeParsersTests.__allTests__OrbitNativeParsersTests),
        testCase(OrbitSystemDeltasTests.__allTests__OrbitSystemDeltasTests),
        testCase(PlusLocalModelsTests.__allTests__PlusLocalModelsTests)
    ]
}