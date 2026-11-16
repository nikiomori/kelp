import Foundation
import Testing

/// How many times `pattern` matches the code (comments and strings left out) of `dirs`.
func count(_ pattern: String, in dirs: [String]) throws -> Int {
    let re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    return sources(dirs).map { f in
        let code = codeOnly(f.text)
        return re.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }.reduce(0, +)
}

/// A kelp-vm machine's state moves in one place (`Lifecycle.move`): written here and there, its moves were where the
/// runtimes' races hid. Left: that one, and each runtime's first state read off its folder as it's made.
@Test func aMachinesStateMovesInOnePlace() throws {
    let writes = try count(#"(^|[^.\w])(self\.)?state = "#, in: ["Sources/KelpVM"])
    #expect(writes == 3, "state written \(writes) times in kelp-vm: through Lifecycle.move")
}
