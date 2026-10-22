import Foundation
public enum CSVParser {
    public static func parse(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closedQuote = false
        let chars = Array(text); var index = 0
        func finishField() { row.append(field); field = ""; closedQuote = false }
        func finishRow() { finishField(); rows.append(row); row = [] }
        while index < chars.count {
            let c = chars[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closedQuote = true }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": guard field.isEmpty && !closedQuote else { throw catError.invalid("CSV 引号位置无效。") }; quoted = true
                case ",": finishField()
                case "\n", "\r\n": finishRow()
                case "\r": if index + 1 < chars.count && chars[index + 1] == "\n" { index += 1 }; finishRow()
                default: guard !closedQuote else { throw catError.invalid("CSV 引号后存在多余字符。") }; field.append(c)
                }
            }
            index += 1
        }
        guard !quoted else { throw catError.invalid("CSV 引号未闭合。") }
        if !field.isEmpty || !row.isEmpty || closedQuote { finishRow() }
        return rows
    }
}
