import XCTest

/// What "The client stopped" says when the client quits on its own (ClientStop.message): the
/// client's own alert, which the AppKit shim logs to the console and the device shows nobody, quoted; and a
/// file error while the game streams its data says to press Play again (a first stream's ERROR #137 in the
/// rc9 run worked on the retry, where the step said only "It quit with exit code 1").
final class ClientStopTests: XCTestCase {
    private let line = #" 123.69 [sp:CoreFoundation] stub hit: CFUserNotificationCreate: "World of Warcraft" / "ERROR #137 (0x85100089) File I/O error." (no alert server here: shown to nobody, never answered)"#

    func testReadsTheClientsAlert() {
        XCTAssertEqual(ClientStop.alert(in: line), "ERROR #137 (0x85100089) File I/O error.")
        XCTAssertNil(ClientStop.alert(in: #"CFUserNotificationCreate: "World of Warcraft" / "(null)" (no alert server here: …)"#))
        XCTAssertNil(ClientStop.alert(in: "[sp:launch] flavors classic_era, running classic_era"))
    }

    func testAFileErrorSaysToTryAgain() {
        let message = ClientStop.message(code: 1, alert: "ERROR #137 (0x85100089) File I/O error.")
        XCTAssertTrue(message.hasPrefix("Press Play to try again."), message)
        XCTAssertTrue(message.contains("ERROR #137"), message)
    }

    func testAnotherAlertIsQuoted() {
        XCTAssertEqual(ClientStop.message(code: 1, alert: "Something else."),
                       "The game said “Something else.” and quit (exit code 1). The log has its last messages (~/Library/Logs/Slashplayed/console.txt).")
    }

    func testNoAlertGivesTheExitCode() {
        XCTAssertEqual(ClientStop.message(code: 1, alert: nil),
                       "It quit with exit code 1. The log has its last messages (~/Library/Logs/Slashplayed/console.txt).")
    }
}
