import Foundation

struct TerminalLinkCandidate {
    let range: NSRange
    let targets: [URL]
}

/// Разрешает только веб-адреса и существующие локальные файлы; ничего не исполняет в shell.
enum TerminalLinks {
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #""[^"\r\n]+"|'[^'\r\n]+'|[^\s<>"']+"#)
    private static let locationSuffix = try! NSRegularExpression(pattern: #":\d+(?::\d+)?$"#)
    private static let closingBrackets: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    static func explicitTarget(_ value: String, cwd: String?) -> URL? {
        guard let candidate = explicitCandidate(value, cwd: cwd) else { return nil }
        return resolve(candidate, fileExists: FileManager.default.fileExists(atPath:))
    }

    static func explicitCandidate(_ value: String, cwd: String?) -> TerminalLinkCandidate? {
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let target: URL?
        if let url = URL(string: value), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                target = url.host?.isEmpty == false ? url : nil
            case "file":
                guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
                target = localFileCandidate(url.path, cwd: nil)
            default: return nil
            }
        } else {
            target = localFileCandidate(value, cwd: cwd)
        }
        guard let target else { return nil }
        return TerminalLinkCandidate(range: NSRange(location: 0, length: value.utf16.count), targets: [target])
    }

    static func resolve(_ candidate: TerminalLinkCandidate, fileExists: (String) -> Bool) -> URL? {
        guard let target = candidate.targets.first(where: { !$0.isFileURL || fileExists($0.path) }) else { return nil }
        return target.isFileURL ? target.standardizedFileURL : target
    }

    static func target(in text: String, utf16Offset: Int, cwd: String?) -> URL? {
        guard utf16Offset >= 0, utf16Offset < text.utf16.count else { return nil }
        guard let candidate = candidates(in: text, cwd: cwd).first(where: { NSLocationInRange(utf16Offset, $0.range) }) else { return nil }
        return resolve(candidate, fileExists: FileManager.default.fileExists(atPath:))
    }

    static func candidates(in text: String, cwd: String?) -> [TerminalLinkCandidate] {
        let source = text as NSString
        var result: [TerminalLinkCandidate] = []
        for match in tokenPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
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
            guard !value.isEmpty else { continue }
            let range = NSRange(location: match.range.location + leading, length: value.utf16.count)
            let lower = value.lowercased()
            if lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("file://") {
                if let candidate = explicitCandidate(value, cwd: cwd) {
                    result.append(TerminalLinkCandidate(range: range, targets: candidate.targets))
                }
                continue
            }
            // Не превращаем обычные слова в ссылки, даже если рядом есть одноимённый файл.
            guard value.contains("/") || value.contains(".") else { continue }
            var targets: [URL] = []
            if let literal = localFileCandidate(value, cwd: cwd) { targets.append(literal) }
            let suffixRange = NSRange(location: 0, length: value.utf16.count)
            let path = locationSuffix.stringByReplacingMatches(in: value, range: suffixRange, withTemplate: "")
            if path != value, let stripped = localFileCandidate(path, cwd: cwd) { targets.append(stripped) }
            if !targets.isEmpty { result.append(TerminalLinkCandidate(range: range, targets: targets)) }
        }
        return result
    }

    private static func localFileCandidate(_ path: String, cwd: String?) -> URL? {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") { url = URL(fileURLWithPath: expanded) }
        else {
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            url = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(expanded)
        }
        return url
    }
}
