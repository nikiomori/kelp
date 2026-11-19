import Foundation
import TestSupport
import Testing

@testable import AgentData

private func limitsLine(_ at: String, _ used: Int) -> String {
    #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(used),"window_minutes":300}}}}"#
        + "\n"
}

/// A rollout's newest limits come from its end; past a megabyte of other lines, from the whole file. Written to again,
/// it's read again (that an unchanged file isn't is `StatMemo`'s, in StatMemoTests).
@Test func aRolloutsLimitsAreReadFromItsEndAndAgainOnceItGrew() throws {
    let file = tmp().appendingPathComponent("rollout-2026-11-01T00-00-00-x.jsonl")
    let filler = String(
        repeating: #"{"type":"response_item","payload":{"type":"message","role":"assistant"}}"# + "\n", count: 20_000)
    try (limitsLine("2026-11-01T00:00:00.000Z", 10) + filler).write(to: file, atomically: false, encoding: .utf8)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0 > 1 << 20)
    #expect(CodexUsage.latest(in: file)?.primaryUsedPercent == 10)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(limitsLine("2026-11-01T01:00:00.000Z", 20).utf8))
    try handle.close()
    #expect(CodexUsage.latest(in: file)?.primaryUsedPercent == 20)
}

/// The index forgets files gone, or last written before the furthest any read goes back: no read would look at them.
@Test func theUsageIndexForgetsFilesNoReadReaches() throws {
    let dir = tmp(), old = dir.appendingPathComponent("old.jsonl"), new = dir.appendingPathComponent("new.jsonl")
    for file in [old, new] { try "{}\n".write(to: file, atomically: false, encoding: .utf8) }
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-UsageIndex.horizon - 86400)], ofItemAtPath: old.path)
    var known: [String: UsageIndex.FileState] = [
        old.path: .init(offset: 3, born: 0), new.path: .init(offset: 3, born: 0),
        dir.appendingPathComponent("gone.jsonl").path: .init(offset: 3, born: 0)
    ]
    UsageIndex.forget(&known, before: Date().addingTimeInterval(-UsageIndex.horizon))
    #expect(Array(known.keys) == [new.path])
}
