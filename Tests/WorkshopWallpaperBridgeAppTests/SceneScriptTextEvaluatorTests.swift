import Foundation
import XCTest
import WorkshopWallpaperCore
@testable import WorkshopWallpaperBridgeApp

final class SceneScriptTextEvaluatorTests: XCTestCase {
    func testEvaluateReturnsUpdatedTextFromDateAndMathScript() {
        // Given
        let script = SceneTextScript(source: """
        export function update(value) {
            const time = new Date();
            return Math.floor(12.9) + ":" + time.getMinutes();
        }
        """)
        let evaluator = SceneScriptTextEvaluator(script: script)

        // When
        let result = evaluator.string(
            currentValue: "old",
            date: Date(timeIntervalSince1970: 60 * 7),
            runtime: SceneScriptRuntime(time: 0, frameTime: 1.0 / 60.0)
        )

        // Then
        XCTAssertEqual(result, "12:7")
    }

    func testEvaluateExposesEngineRuntimeAndFrameTime() {
        // Given
        let script = SceneTextScript(source: """
        export function update(value) {
            return engine.runtime.toFixed(2) + "/" + engine.frametime.toFixed(3);
        }
        """)
        let evaluator = SceneScriptTextEvaluator(script: script)

        // When
        let result = evaluator.string(
            currentValue: "old",
            date: Date(timeIntervalSince1970: 0),
            runtime: SceneScriptRuntime(time: 3.25, frameTime: 1.0 / 30.0)
        )

        // Then
        XCTAssertEqual(result, "3.25/0.033")
    }

    func testEvaluateKeepsCurrentTextWhenUpdateReturnsUndefined() {
        // Given
        let script = SceneTextScript(source: """
        export function update(value) {
            if (value === "keep") {
                return undefined;
            }
            return "changed";
        }
        """)
        let evaluator = SceneScriptTextEvaluator(script: script)

        // When
        let result = evaluator.string(
            currentValue: "keep",
            date: Date(timeIntervalSince1970: 0),
            runtime: SceneScriptRuntime(time: 0, frameTime: 1.0 / 60.0)
        )

        // Then
        XCTAssertEqual(result, "keep")
    }

    func testEvaluateExposesScriptPropertiesAndTimeOfDay() throws {
        // Given
        let script = SceneTextScript(
            source: """
            export function update(value) {
                return scriptProperties.delimiter + engine.timeOfDay.toFixed(3);
            }
            """,
            properties: ["delimiter": .string("@")]
        )
        let evaluator = SceneScriptTextEvaluator(script: script)
        let noon = try XCTUnwrap(Calendar.current.date(from: DateComponents(hour: 12, minute: 0, second: 0)))

        // When
        let result = evaluator.string(
            currentValue: "old",
            date: noon,
            runtime: SceneScriptRuntime(time: 0, frameTime: 1.0 / 60.0)
        )

        // Then
        XCTAssertEqual(result, "@0.500")
    }

    func testEvaluateKeepsCurrentTextWhenScriptThrows() {
        // Given
        let script = SceneTextScript(source: """
        export function update(value) {
            throw new Error("bad scene script");
        }
        """)
        let evaluator = SceneScriptTextEvaluator(script: script)

        // When
        let result = evaluator.string(
            currentValue: "fallback",
            date: Date(timeIntervalSince1970: 0),
            runtime: SceneScriptRuntime(time: 0, frameTime: 1.0 / 60.0)
        )

        // Then
        XCTAssertEqual(result, "fallback")
    }

    func testEvaluateKeepsCurrentTextForUnsupportedLongRunningPatterns() {
        // Given
        let script = SceneTextScript(source: """
        export function update(value) {
            while (true) {
                value = value + "!";
            }
        }
        """)
        let evaluator = SceneScriptTextEvaluator(script: script)

        // When
        let result = evaluator.string(
            currentValue: "fallback",
            date: Date(timeIntervalSince1970: 0),
            runtime: SceneScriptRuntime(time: 0, frameTime: 1.0 / 60.0)
        )

        // Then
        XCTAssertEqual(result, "fallback")
    }

    func testEvaluateKeepsCurrentTextForDynamicFunctionConstructorBypass() {
        // Given
        let script = SceneTextScript(source: """
        export function update(value) {
            return update.constructor("return 'dynamic'")();
        }
        """)
        let evaluator = SceneScriptTextEvaluator(script: script)

        // When
        let result = evaluator.string(
            currentValue: "fallback",
            date: Date(timeIntervalSince1970: 0),
            runtime: SceneScriptRuntime(time: 0, frameTime: 1.0 / 60.0)
        )

        // Then
        XCTAssertEqual(result, "fallback")
    }

    func testEvaluateKeepsCurrentTextForBracketConstructorBypass() {
        // Given
        let script = SceneTextScript(source: """
        export function update(value) {
            return update["constructor"]("return 'dynamic'")();
        }
        """)
        let evaluator = SceneScriptTextEvaluator(script: script)

        // When
        let result = evaluator.string(
            currentValue: "fallback",
            date: Date(timeIntervalSince1970: 0),
            runtime: SceneScriptRuntime(time: 0, frameTime: 1.0 / 60.0)
        )

        // Then
        XCTAssertEqual(result, "fallback")
    }

    func testEvaluateKeepsCurrentTextForUnicodeConstructorBypass() {
        // Given
        let script = SceneTextScript(source: """
        export function update(value) {
            return update.con\\u0073tructor("return 'dynamic'")();
        }
        """)
        let evaluator = SceneScriptTextEvaluator(script: script)

        // When
        let result = evaluator.string(
            currentValue: "fallback",
            date: Date(timeIntervalSince1970: 0),
            runtime: SceneScriptRuntime(time: 0, frameTime: 1.0 / 60.0)
        )

        // Then
        XCTAssertEqual(result, "fallback")
    }

    func testEvaluateKeepsCurrentTextForAnonymousFunctionBypass() {
        // Given
        let script = SceneTextScript(source: """
        export function update(value) {
            const makeText = function() {
                return "dynamic";
            };
            return makeText();
        }
        """)
        let evaluator = SceneScriptTextEvaluator(script: script)

        // When
        let result = evaluator.string(
            currentValue: "fallback",
            date: Date(timeIntervalSince1970: 0),
            runtime: SceneScriptRuntime(time: 0, frameTime: 1.0 / 60.0)
        )

        // Then
        XCTAssertEqual(result, "fallback")
    }

    func testEvaluateKeepsCurrentTextForUpdateAliasRecursion() {
        // Given
        let script = SceneTextScript(source: """
        export function update(value) {
            const recurse = update;
            return recurse(value);
        }
        """)
        let evaluator = SceneScriptTextEvaluator(script: script)

        // When
        let result = evaluator.string(
            currentValue: "fallback",
            date: Date(timeIntervalSince1970: 0),
            runtime: SceneScriptRuntime(time: 0, frameTime: 1.0 / 60.0)
        )

        // Then
        XCTAssertEqual(result, "fallback")
    }
}
