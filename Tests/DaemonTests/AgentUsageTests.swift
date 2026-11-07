import Foundation
import Testing

@testable import Daemon

/// The models with a native 1M window, as Claude Code's catalog has them; older ones are 200k unless seen past it.
@Test func nativeMillionModels() {
    for m in [
        "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5", "claude-sonnet-5",
        "claude-sonnet-5-5",
        "claude-haiku-5-5", "claude-fable-5-1"
    ] { #expect(AgentUsage.nativeMillion(m), "\(m)") }
    for m in [
        "claude-opus-4-6", "claude-opus-4-5-20251101", "claude-sonnet-4-20250514", "claude-sonnet-4-6",
        "claude-haiku-4-5-20251001",
        "claude-3-7-sonnet-20250219", "claude-3-5-sonnet-20241022", "claude-3-5-haiku-20241022", "<synthetic>", "m", ""
    ] { #expect(!AgentUsage.nativeMillion(m), "\(m)") }
}
