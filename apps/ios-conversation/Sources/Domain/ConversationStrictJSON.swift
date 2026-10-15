import Foundation

/// Bounded structural validation before typed decoding; escaped duplicate keys are rejected.
public enum ConversationStrictJSON {
    public static func object(_ data:Data,maxBytes:Int=1_500_000) throws -> [String:Any] {
        guard !data.isEmpty,data.count<=maxBytes else {throw ConversationSessionError.invalidEvent}
        var scanner=Scanner(bytes:Array(data));try scanner.value(depth:0);scanner.space()
        guard scanner.index==scanner.bytes.count,let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw ConversationSessionError.invalidEvent}
        return value
    }
    private struct Scanner {
        let bytes:[UInt8]
        var index=0
        mutating func space(){while index<bytes.count && [9,10,13,32].contains(bytes[index]) {index += 1}}
        mutating func value(depth:Int) throws {
            guard depth<=64 else {throw ConversationSessionError.invalidEvent};space();guard index<bytes.count else {throw ConversationSessionError.invalidEvent}
            switch bytes[index] {
            case 123:try object(depth:depth+1)
            case 91:try array(depth:depth+1)
            case 34:_=try string()
            case 116:try literal([116,114,117,101])
            case 102:try literal([102,97,108,115,101])
            case 110:try literal([110,117,108,108])
            default:try number()
            }
        }
        mutating func object(depth:Int) throws {
            guard depth<=64 else {throw ConversationSessionError.invalidEvent};index += 1;space();if take(125){return}
            // JSON member names compare decoded code units, without Unicode normalization.
            var keys=Set<[UInt16]>()
            while true {
                space();let range=try string()
                guard let key=try JSONSerialization.jsonObject(with:Data(bytes[range]),options:.fragmentsAllowed) as? String,keys.insert(Array(key.utf16)).inserted else {throw ConversationSessionError.invalidEvent}
                space();guard take(58) else {throw ConversationSessionError.invalidEvent};try value(depth:depth);space()
                if take(125){return};guard take(44) else {throw ConversationSessionError.invalidEvent}
            }
        }
        mutating func array(depth:Int) throws {
            guard depth<=64 else {throw ConversationSessionError.invalidEvent};index += 1;space();if take(93){return}
            while true {try value(depth:depth);space();if take(93){return};guard take(44) else {throw ConversationSessionError.invalidEvent}}
        }
        mutating func string() throws -> Range<Int> {
            let start=index;guard take(34) else {throw ConversationSessionError.invalidEvent}
            while index<bytes.count {
                let byte=bytes[index];index += 1
                if byte==34 {return start..<index}
                guard byte>=32 else {throw ConversationSessionError.invalidEvent}
                if byte==92 {
                    guard index<bytes.count else {throw ConversationSessionError.invalidEvent};let escaped=bytes[index];index += 1
                    if escaped==117 {guard index+4<=bytes.count,bytes[index..<index+4].allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}) else {throw ConversationSessionError.invalidEvent};index += 4}
                    else {guard [34,47,92,98,102,110,114,116].contains(escaped) else {throw ConversationSessionError.invalidEvent}}
                }
            }
            throw ConversationSessionError.invalidEvent
        }
        mutating func number() throws {
            let start=index
            _=take(45);guard index<bytes.count else {throw ConversationSessionError.invalidEvent}
            if take(48) {} else {guard (49...57).contains(bytes[index]) else {throw ConversationSessionError.invalidEvent};digits()}
            if take(46) {let start=index;digits();guard index>start else {throw ConversationSessionError.invalidEvent}}
            if take(101)||take(69) {_=take(43)||take(45);let start=index;digits();guard index>start else {throw ConversationSessionError.invalidEvent}}
            guard let number=Double(String(decoding:bytes[start..<index],as:UTF8.self)),number.isFinite else {throw ConversationSessionError.invalidEvent}
        }
        mutating func digits(){while index<bytes.count && (48...57).contains(bytes[index]) {index += 1}}
        mutating func literal(_ expected:[UInt8]) throws {guard index+expected.count<=bytes.count,Array(bytes[index..<index+expected.count])==expected else {throw ConversationSessionError.invalidEvent};index += expected.count}
        mutating func take(_ byte:UInt8)->Bool {guard index<bytes.count,bytes[index]==byte else {return false};index += 1;return true}
    }
}
