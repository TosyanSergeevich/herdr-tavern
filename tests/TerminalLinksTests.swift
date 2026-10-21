import Foundation

@main struct TerminalLinksTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tavern-links-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Файл с пробелами.swift")
        let simple = root.appendingPathComponent("main.swift")
        try Data("fixture".utf8).write(to: file)
        try Data("fixture".utf8).write(to: simple)
        func target(_ text: String, on part: String, cwd: String? = root.path) -> URL? {
            TerminalLinks.target(in: text, utf16Offset: (text as NSString).range(of: part).location, cwd: cwd)
        }
        precondition(target("См. (https://example.com/a_(b)).", on: "example")?.absoluteString == "https://example.com/a_(b)")
        precondition(target("[ссылка](https://example.com/a)", on: "example")?.absoluteString == "https://example.com/a")
        precondition(target("[ссылка](https://example.com/a)", on: "ссылка") == nil)
        print("PASS: веб-адреса, Markdown и сбалансированные скобки")
        precondition(target("Открой main.swift:12:3", on: "main") == simple)
        precondition(target("Открой main.swift", on: "main", cwd: nil) == nil)
        precondition(target("missing.swift", on: "missing") == nil)
        precondition(target("\"\(file.path)\"", on: "пробелами") == file)
        precondition(TerminalLinks.explicitTarget(file.absoluteString, cwd: nil) == file)
        precondition(TerminalLinks.explicitTarget(simple.path, cwd: nil) == simple)
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        precondition(TerminalLinks.explicitTarget("~/", cwd: nil) == home)
        print("PASS: относительные и абсолютные пути, кириллица, пробелы, file URI и суффикс строки")
        for value in ["javascript:alert(1)", "ssh://example.com", "file://remote/tmp/test", "https://", "https://example.com\n"] {
            precondition(TerminalLinks.explicitTarget(value, cwd: root.path) == nil, value)
        }
        precondition(target("main.swift ", on: " ") == nil)
        print("PASS: неизвестные схемы, нелокальные file URI, управляющие символы и пробелы не открываются")
    }
}
