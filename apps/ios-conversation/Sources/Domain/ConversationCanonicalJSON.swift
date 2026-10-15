import Foundation
import JavaScriptCore

/// Deterministic protocol encoding only. The engine evaluates one fixed local
/// function; JSON is passed as an argument, never interpolated into source.
/// There are no host objects, file/network bridges or model-authored programs.
public enum ConversationCanonicalJSON {
    public enum Failure:Error {case invalidInput,engineUnavailable,encodingFailed}
    private static let functionSource = #"""
    (function(raw) {
        "use strict";
        function canonical(value) {
            if (value === null || ["string", "boolean"].includes(typeof value)) return JSON.stringify(value);
            if (typeof value === "number") {
                if (!Number.isFinite(value)) throw new Error("invalid_json_number");
                return JSON.stringify(value);
            }
            if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
            if (!value || Object.getPrototypeOf(value) !== Object.prototype) throw new Error("invalid_json_object");
            return "{" + Object.keys(value).sort().map(function(key) {
                return JSON.stringify(key) + ":" + canonical(value[key]);
            }).join(",") + "}";
        }
        return canonical(JSON.parse(raw));
    })
    """#
    public static func data(_ input:Data,maxBytes:Int=16_000) throws -> Data {
        // Validate the original bytes, not a re-encoded Swift dictionary. Swift
        // key equality normalizes Unicode; the wire contract compares UTF-16.
        _=try ConversationStrictJSON.object(input,maxBytes:maxBytes)
        guard let raw=String(data:input,encoding:.utf8) else {throw Failure.invalidInput}
        guard let context=JSContext() else {throw Failure.engineUnavailable}
        guard let function=context.evaluateScript(functionSource),context.exception==nil,!function.isUndefined,
              let value=function.call(withArguments:[raw]),context.exception==nil,value.isString,
              let canonical=value.toString() else {throw Failure.encodingFailed}
        return Data(canonical.utf8)
    }
    public static func hash(_ input:Data,maxBytes:Int=16_000) throws -> String {bytesHash(try data(input,maxBytes:maxBytes))}
}
