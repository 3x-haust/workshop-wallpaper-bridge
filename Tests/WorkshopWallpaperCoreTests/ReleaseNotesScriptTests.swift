import Foundation
import XCTest

final class ReleaseNotesScriptTests: XCTestCase {
    func testReleaseNotesStayStableAcrossSigningTransitionsAndReruns() throws {
        let generatedNotes = """
        ## Changes

        - Fix packaged resource loading
        """

        let adHocNotes = try renderReleaseNotes(signingAvailable: false, existingNotes: generatedNotes)
        XCTAssertTrue(adHocNotes.contains("<!-- unsigned-install:start -->"))
        XCTAssertTrue(adHocNotes.contains("xattr -r -d com.apple.quarantine"))
        XCTAssertTrue(adHocNotes.hasSuffix(generatedNotes))

        let adHocRerun = try renderReleaseNotes(signingAvailable: false, existingNotes: adHocNotes)
        XCTAssertEqual(adHocRerun, adHocNotes)

        let signedNotes = try renderReleaseNotes(signingAvailable: true, existingNotes: adHocNotes)
        XCTAssertEqual(signedNotes, generatedNotes)

        let signedRerun = try renderReleaseNotes(signingAvailable: true, existingNotes: signedNotes)
        XCTAssertEqual(signedRerun, generatedNotes)

        let adHocAgain = try renderReleaseNotes(signingAvailable: false, existingNotes: signedNotes)
        XCTAssertEqual(adHocAgain, adHocNotes)
    }

    func testReleaseNotesPreserveMalformedMarkersAndTrimBoundaryWhitespace() throws {
        let malformedNotes = """
        ## Changes
        <!-- unsigned-install:start -->
        User-authored text
        """
        let signedMalformed = try renderReleaseNotes(
            signingAvailable: true,
            existingNotes: malformedNotes
        )
        XCTAssertEqual(signedMalformed, malformedNotes)

        let paddedNotes = "\n  \n## Changes\n\n- Fix\n \t\n"
        let signedTrimmed = try renderReleaseNotes(
            signingAvailable: true,
            existingNotes: paddedNotes
        )
        XCTAssertEqual(signedTrimmed, "## Changes\n\n- Fix")
    }

    private func renderReleaseNotes(signingAvailable: Bool, existingNotes: String) throws -> String {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "Scripts/render-release-notes.sh")
        process.arguments = [signingAvailable ? "true" : "false"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(Data(existingNotes.utf8))
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(bytes: error, encoding: .utf8) ?? ""
        )
        return String(bytes: output, encoding: .utf8) ?? ""
    }
}
