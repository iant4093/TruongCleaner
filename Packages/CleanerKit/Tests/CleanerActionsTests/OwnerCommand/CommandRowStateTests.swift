import Foundation
import Testing

@testable import CleanerActions

/// The Developer page's decisions, tested without the page.
struct CommandRowStateTests {
    private func result(
        exitCode: Int32? = 0, timedOut: Bool = false, skipped: String? = nil
    ) -> OwnerCommandResult {
        OwnerCommandResult(
            id: .brewCleanup, executable: nil, exitCode: exitCode, timedOut: timedOut, skipped: skipped,
            outputTail: "", duration: .zero)
    }

    // MARK: Row state

    @Test func readyRowHasAnEnabledRunButtonAndNoNote() {
        let state = DeveloperRowState(isInstalled: true, isRunning: false, isBusy: false, blockReason: nil)
        #expect(state.trailing == .run(isEnabled: true))
        #expect(state.note == nil)
    }

    @Test func missingToolShowsNotInstalledAndNoNote() {
        let state = DeveloperRowState(isInstalled: false, isRunning: false, isBusy: false, blockReason: "A simulator is running.")
        #expect(state.trailing == .notInstalled)
        #expect(state.note == nil)
        #expect(DeveloperRowState.notInstalledText == "Not installed")
    }

    @Test func unknownInstallStateKeepsRunOff() {
        let state = DeveloperRowState(isInstalled: nil, isRunning: false, isBusy: false, blockReason: nil)
        #expect(state.trailing == .run(isEnabled: false))
    }

    @Test func anotherJobRunningKeepsRunOff() {
        let state = DeveloperRowState(isInstalled: true, isRunning: false, isBusy: true, blockReason: nil)
        #expect(state.trailing == .run(isEnabled: false))
    }

    @Test func blockReasonKeepsRunOffAndIsShownAsANote() {
        let state = DeveloperRowState(isInstalled: true, isRunning: false, isBusy: false, blockReason: "A simulator is running. Quit Simulator first.")
        #expect(state.trailing == .run(isEnabled: false))
        #expect(state.note == "A simulator is running. Quit Simulator first.")
    }

    @Test func runningRowShowsASpinnerEvenWhenBusy() {
        let state = DeveloperRowState(isInstalled: true, isRunning: true, isBusy: true, blockReason: nil)
        #expect(state.trailing == .running)
    }

    // MARK: Simulator block reasons

    @Test(arguments: [
        (SimulatorListStatus.notLoaded, false, "Reading the simulator list…"),
        (.loading, true, "Reading the simulator list…"),
        (.unavailable("Xcode is not installed."), false, "Xcode is not installed."),
        (.ready, true, "A simulator is running. Quit Simulator first."),
        (.ready, false, nil),
    ] as [(SimulatorListStatus, Bool, String?)])
    func simulatorBlockReason(status: SimulatorListStatus, running: Bool, expected: String?) {
        #expect(DeveloperRowState.simulatorBlockReason(status: status, anySimulatorRunning: running) == expected)
    }

    @Test(arguments: [
        (true, true, "Something else is running."),
        (true, false, "Something else is running."),
        (false, false, "This simulator is running. Shut it down first."),
        (false, true, nil),
    ] as [(Bool, Bool, String?)])
    func deviceDeleteBlockReason(busy: Bool, shutDown: Bool, expected: String?) {
        #expect(DeveloperRowState.deviceDeleteBlockReason(isBusy: busy, isShutDown: shutDown) == expected)
    }

    @Test(arguments: [
        (true, true, nil, "Something else is running."),
        (false, false, nil, "Xcode says this runtime cannot be deleted."),
        (false, true, "A simulator is running. Quit Simulator first.", "A simulator is running. Quit Simulator first."),
        (false, true, nil, nil),
    ] as [(Bool, Bool, String?, String?)])
    func runtimeDeleteBlockReason(busy: Bool, deletable: Bool, simulator: String?, expected: String?) {
        let reason = DeveloperRowState.runtimeDeleteBlockReason(
            isBusy: busy, isDeletable: deletable, simulatorBlockReason: simulator)
        #expect(reason == expected)
    }

    // MARK: Confirmation text

    @Test func commandConfirmationNamesTheExactCommandAndSaysItCannotBePutBack() {
        let confirmation = DeveloperConfirmation.command(
            title: "Homebrew cleanup", commandText: "/opt/homebrew/bin/brew cleanup --prune=30")
        #expect(confirmation.title == "Homebrew cleanup?")
        #expect(confirmation.buttonTitle == "Run")
        #expect(confirmation.message.contains("TruongCleaner will run:\n/opt/homebrew/bin/brew cleanup --prune=30\n"))
        #expect(confirmation.message.contains("cannot be put back from the Trash"))
    }

    @Test func deviceConfirmationNamesTheDeviceTheSizeAndTheCommand() {
        let udid = "0F3A9C2E-5B7D-4E1A-9C6F-1D2B3A4C5D6E"
        let confirmation = DeveloperConfirmation.device(name: "iPhone 17", udid: udid, approximateBytes: 2_000_000_000)
        #expect(confirmation.title == "Delete “iPhone 17”?")
        #expect(confirmation.buttonTitle == "Delete")
        #expect(confirmation.message.contains(", about "))
        #expect(confirmation.message.contains("/usr/bin/xcrun simctl delete \(udid)"))
        #expect(confirmation.message.hasSuffix("It cannot be put back."))
    }

    @Test func deviceConfirmationWithoutASizeLeavesOutTheAboutPhrase() {
        let confirmation = DeveloperConfirmation.device(name: "iPhone", udid: "U", approximateBytes: nil)
        #expect(!confirmation.message.contains("about"))
        #expect(confirmation.message.hasPrefix("Deletes this simulator with its apps and data. TruongCleaner will run:"))
    }

    @Test func runtimeConfirmationNamesTheRuntimeAndSaysXcodeCanDownloadItAgain() {
        let confirmation = DeveloperConfirmation.runtime(name: "iOS 27.0", identifier: "abc-1", approximateBytes: nil)
        #expect(confirmation.title == "Delete the iOS 27.0 runtime?")
        #expect(confirmation.buttonTitle == "Delete")
        #expect(confirmation.message.contains("/usr/bin/xcrun simctl runtime delete abc-1"))
        #expect(confirmation.message.hasSuffix("Xcode can download it again."))
    }

    // MARK: Result text

    @Test func summaryTextCoversEveryWayARunCanEnd() {
        #expect(result(exitCode: 0).summaryText == "Finished")
        #expect(result(exitCode: 3).summaryText == "Failed (exit code 3)")
        #expect(result(exitCode: nil, timedOut: true).summaryText == "Timed out and was stopped")
        #expect(result(exitCode: nil).summaryText == "Stopped before it finished")
        #expect(result(exitCode: nil, skipped: "tool not found").summaryText == "Not installed")
        #expect(result(exitCode: nil, skipped: "a simulator is running").summaryText == "Not run: a simulator is running")
    }

    @Test func onlyTheToolNotFoundSkipCountsAsAMissingTool() {
        #expect(result(exitCode: nil, skipped: "tool not found").isToolMissing)
        #expect(!result(exitCode: nil, skipped: "Docker is not running").isToolMissing)
        #expect(!result().isToolMissing)
    }

    @Test func everyAllowedCommandHasAShortTitle() {
        for id in OwnerCommands.all.keys {
            #expect(id.title != id.rawValue)
        }
        #expect(OwnerCommandID.simctlDeleteDevice.title == "Delete simulator")
        #expect(OwnerCommandID.simctlDeleteRuntime.title == "Delete simulator runtime")
        #expect(OwnerCommandID(rawValue: "unknown.thing").title == "unknown.thing")
    }
}
