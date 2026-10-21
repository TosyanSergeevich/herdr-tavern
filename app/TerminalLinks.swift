import Foundation

/// Разрешает только веб-адреса и существующие локальные файлы; ничего не исполняет в shell.
enum TerminalLinks {
    private static let candidates = try! NSRegularExpression(
        pattern: #""[^"\r\n]+"|'[^'\r\n]+'|[^\s<>"']+"#)
    private static let locationSuffix = try! NSRegularExpression(pattern: #":\d+(?::\d+)?$"#)
    private static let closingBrackets: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    static func explicitTarget(_ value: String, cwd: String?) -> URL? {
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                return url.host?.isEmpty == false ? url : nil
            case "file":
                guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
                return localFile(url.path, cwd: nil)
            default: return nil
            }
        }
        return localFile(value, cwd: cwd)
    }

    static func target(in text: String, utf16Offset: Int, cwd: String?) -> URL? {
        let source = text as NSString
        guard utf16Offset >= 0, utf16Offset < source.length else { return nil }
        for match in candidates.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard NSLocationInRange(utf16Offset, match.range) else { continue }
            var value = source.substring(with: match.range)
            var leading = 0
            if value.first == "\"" || value.first == "'" {
                value.removeFirst(); value.removeLast(); leading = 1
            } else {
                if let destination = value.range(of: "](") {
                    leading = value[..<destination.upperBound].utf16.count
                    value = String(value[destination.upperBound...])
                }
                while let first = value.first, "([{`".contains(first) { value.removeFirst(); leading += 1 }
                while let last = value.last {
                    if ".,;!?`".contains(last) { value.removeLast(); continue }
                    if let opening = closingBrackets[last], value.lazy.filter({ $0 == last }).count > value.lazy.filter({ $0 == opening }).count {
                        value.removeLast(); continue
                    }
                    break
                }
            }
            let offset = utf16Offset - match.range.location - leading
            guard offset >= 0, offset < value.utf16.count else { return nil }
            let lower = value.lowercased()
            if lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("file://") {
                return explicitTarget(value, cwd: cwd)
            }
            // Не превращаем обычные слова в ссылки, даже если рядом есть одноимённый файл.
            guard value.contains("/") || value.contains(".") else { return nil }
            if let file = localFile(value, cwd: cwd) { return file }
            let range = NSRange(location: 0, length: (value as NSString).length)
            let path = locationSuffix.stringByReplacingMatches(in: value, range: range, withTemplate: "")
            return localFile(path, cwd: cwd)
        }
        return nil
    }

    private static func localFile(_ path: String, cwd: String?) -> URL? {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") { url = URL(fileURLWithPath: expanded) }
        else {
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            url = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(expanded)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.standardizedFileURL
    }
}
