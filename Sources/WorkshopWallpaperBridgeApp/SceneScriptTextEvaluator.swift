import Foundation
import JavaScriptCore
import WorkshopWallpaperCore

struct SceneScriptRuntime {
    let time: TimeInterval
    let frameTime: TimeInterval

    init(time: TimeInterval, frameTime: TimeInterval) {
        self.time = time
        self.frameTime = frameTime
    }
}

final class SceneScriptTextEvaluator {
    private let script: SceneTextScript
    private let context: JSContext
    private var hasCompileError = false
    private var isUnsupportedSource = false

    init(script: SceneTextScript) {
        self.script = script
        context = JSContext()
        context.exceptionHandler = { _, _ in }
        compile()
    }

    func string(
        currentValue: String,
        date: Date,
        runtime: SceneScriptRuntime
    ) -> String {
        guard !isUnsupportedSource,
              !hasCompileError,
              let update = context.objectForKeyedSubscript("update"),
              !update.isUndefined else {
            return currentValue
        }

        applyFrameGlobals(date: date, runtime: runtime)
        var didThrow = false
        context.exceptionHandler = { _, _ in
            didThrow = true
        }
        let result = update.call(withArguments: [currentValue])
        context.exceptionHandler = { _, _ in }
        guard !didThrow,
              let result,
              !result.isUndefined,
              !result.isNull else {
            return currentValue
        }
        return result.toString() ?? currentValue
    }

    private func compile() {
        let source = Self.normalizedSource(script.source)
        guard Self.isSupportedSource(source, propertyNames: Set(script.properties.keys)) else {
            isUnsupportedSource = true
            hasCompileError = true
            return
        }
        applyScriptProperties()
        context.exceptionHandler = { [weak self] _, _ in
            self?.hasCompileError = true
        }
        context.evaluateScript(source)
        context.exceptionHandler = { _, _ in }
        if context.objectForKeyedSubscript("update")?.isUndefined != false {
            hasCompileError = true
        }
    }

    private func applyScriptProperties() {
        context.setObject(
            script.properties.mapValues(Self.javascriptValue),
            forKeyedSubscript: "scriptProperties" as NSString
        )
    }

    private func applyFrameGlobals(date: Date, runtime: SceneScriptRuntime) {
        context.setObject(
            [
                "runtime": runtime.time,
                "frametime": runtime.frameTime,
                "timeOfDay": Self.normalizedTimeOfDay(for: date)
            ],
            forKeyedSubscript: "engine" as NSString
        )
        context.evaluateScript(Self.datePrelude(for: date))
    }

    private static func normalizedSource(_ source: String) -> String {
        source
            .replacingOccurrences(of: "export default function update", with: "function update")
            .replacingOccurrences(of: "export function update", with: "function update")
    }

    private static func isSupportedSource(_ source: String, propertyNames: Set<String>) -> Bool {
        guard source.utf8.count <= 16_384 else {
            return false
        }
        let unsupportedPatterns = [
            #"[\`\\]"#,
            #"\bwhile\s*\("#,
            #"\bfor\s*\("#,
            #"\bdo\s*\{"#,
            #"\[[^\]]*\]"#,
            #"\beval\s*\("#,
            #"\bFunction\s*\("#,
            #"\bconstructor\b"#,
            #"\bprototype\b"#,
            #"\b__proto__\b"#,
            #"\bglobalThis\b"#,
            #"\bthis\b"#,
            #"\bfunction\b(?!\s+update\b)"#,
            #"\bnew\s+(?!Date\b)\w+"#,
            #"\bsetTimeout\s*\("#,
            #"\bsetInterval\s*\("#,
            #"\bPromise\b"#,
            #"\bWebAssembly\b"#,
            #"\bReflect\b"#,
            #"\bProxy\b"#,
            #"\brepeat\s*\("#,
            #"\bimport\s*(?:\(|[{\w*])"#,
            #"=>"#,
            #"\bclass\s+\w+"#
        ]
        return !unsupportedPatterns.contains { pattern in
            source.range(of: pattern, options: .regularExpression) != nil
        } && hasOnlyAllowedIdentifiers(source, propertyNames: propertyNames)
    }

    private static func hasOnlyAllowedIdentifiers(_ source: String, propertyNames: Set<String>) -> Bool {
        let scrubbed = sourceWithoutStringsAndComments(source)
        guard identifierCount("update", in: scrubbed) == 1 else {
            return false
        }
        var allowed = Set([
            "function", "update", "value", "const", "let", "var", "return", "if", "else",
            "undefined", "null", "true", "false", "new", "Date", "Math", "engine",
            "runtime", "frametime", "timeOfDay", "scriptProperties", "String", "Number",
            "floor", "ceil", "round", "trunc", "abs", "min", "max", "sin", "cos", "tan",
            "pow", "sqrt", "getMinutes", "getHours", "getSeconds", "getMilliseconds",
            "getFullYear", "getMonth", "getDate", "getDay", "getTime", "toFixed",
            "toString", "length"
        ])
        allowed.formUnion(propertyNames)
        allowed.formUnion(declaredIdentifiers(in: scrubbed))

        for identifier in identifiers(in: scrubbed) where !allowed.contains(identifier) {
            return false
        }
        return true
    }

    private static func sourceWithoutStringsAndComments(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\"" || character == "'" {
                let quote = character
                result.append(" ")
                index = source.index(after: index)
                while index < source.endIndex, source[index] != quote {
                    result.append(" ")
                    index = source.index(after: index)
                }
                if index < source.endIndex {
                    result.append(" ")
                    index = source.index(after: index)
                }
            } else if character == "/",
                      source.index(after: index) < source.endIndex,
                      source[source.index(after: index)] == "/" {
                result.append("  ")
                index = source.index(index, offsetBy: 2)
                while index < source.endIndex, source[index] != "\n" {
                    result.append(" ")
                    index = source.index(after: index)
                }
            } else if character == "/",
                      source.index(after: index) < source.endIndex,
                      source[source.index(after: index)] == "*" {
                result.append("  ")
                index = source.index(index, offsetBy: 2)
                while source.index(after: index) < source.endIndex {
                    if source[index] == "*", source[source.index(after: index)] == "/" {
                        result.append("  ")
                        index = source.index(index, offsetBy: 2)
                        break
                    }
                    result.append(" ")
                    index = source.index(after: index)
                }
            } else {
                result.append(character)
                index = source.index(after: index)
            }
        }
        return result
    }

    private static func identifierCount(_ identifier: String, in source: String) -> Int {
        identifiers(in: source).filter { $0 == identifier }.count
    }

    private static func declaredIdentifiers(in source: String) -> Set<String> {
        Set(matches(for: #"\b(?:const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#, in: source, captureIndex: 1))
    }

    private static func identifiers(in source: String) -> [String] {
        matches(for: #"\b[A-Za-z_$][A-Za-z0-9_$]*\b"#, in: source, captureIndex: 0)
    }

    private static func matches(for pattern: String, in source: String, captureIndex: Int) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > captureIndex,
                  let matchRange = Range(match.range(at: captureIndex), in: source) else {
                return nil
            }
            return String(source[matchRange])
        }
    }

    private static func javascriptValue(_ value: SceneScriptPropertyValue) -> Any {
        switch value {
        case .bool(let bool):
            return bool
        case .number(let number):
            return number
        case .string(let string):
            return string
        }
    }

    private static func normalizedTimeOfDay(for date: Date) -> Double {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double(components.hour ?? 0) * 3600
            + Double(components.minute ?? 0) * 60
            + Double(components.second ?? 0)
            + Double(components.nanosecond ?? 0) / 1_000_000_000
        return max(0, min(seconds / 86_400, 1))
    }

    private static func datePrelude(for date: Date) -> String {
        let milliseconds = date.timeIntervalSince1970 * 1000
        let timestamp = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), milliseconds)
        return """
        var __wwbNow = \(timestamp);
        if (typeof __wwbNativeDate === "undefined") {
            var __wwbNativeDate = Date;
        }
        Date = function(year, month, day, hour, minute, second, millisecond) {
            if (arguments.length === 0) {
                return new __wwbNativeDate(__wwbNow);
            }
            if (arguments.length === 1) {
                return new __wwbNativeDate(year);
            }
            if (arguments.length === 2) {
                return new __wwbNativeDate(year, month);
            }
            if (arguments.length === 3) {
                return new __wwbNativeDate(year, month, day);
            }
            if (arguments.length === 4) {
                return new __wwbNativeDate(year, month, day, hour);
            }
            if (arguments.length === 5) {
                return new __wwbNativeDate(year, month, day, hour, minute);
            }
            if (arguments.length === 6) {
                return new __wwbNativeDate(year, month, day, hour, minute, second);
            }
            return new __wwbNativeDate(year, month, day, hour, minute, second, millisecond);
        };
        Date.now = function() {
            return __wwbNow;
        };
        Date.parse = __wwbNativeDate.parse;
        Date.UTC = __wwbNativeDate.UTC;
        Date.prototype = __wwbNativeDate.prototype;
        """
    }
}
