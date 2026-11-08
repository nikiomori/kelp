import Testing

@testable import Agents

/// The hashes Codex 0.166 itself listed as trusted (`hooks/list`) for these two hooks: Kelp's must be the same, or
/// Codex would ask at start whether to trust them.
@Test func codexHookHashesAreCodexsOwn() {
    #expect(
        CodexHooks.hash(label: "stop", command: "kelp hook done")
            == "sha256:1ea1480a6e1ca32163cf49976d378c51eafaac28e393eee41978df4f080ee373")
    #expect(
        CodexHooks.hash(label: "user_prompt_submit", command: "kelp hook working")
            == "sha256:0b16a96cac37ba7c706231792a25f83b41e5f784cd61aede6227b1d595496a4a")
}

/// Each hook on its own `-c`, then one table trusting them all by key (a dotted key would split at "config.toml").
@Test func codexHookArgsTrustExactlyKelpsHooks() {
    let args = CodexHooks.args
    #expect(
        args.count == CodexHooks.events.count * 2 + 2
            && args.enumerated().allSatisfy { $0.offset % 2 == 1 || $0.element == "-c" })
    #expect(args.contains(#"hooks.Stop=[{hooks=[{type="command",command="kelp hook done"}]}]"#))
    let state = args.last ?? ""
    #expect(
        state.hasPrefix(#"hooks.state={"/<session-flags>/config.toml:user_prompt_submit:0:0"={trusted_hash="sha256:"#))
    #expect(state.components(separatedBy: "trusted_hash=").count - 1 == CodexHooks.events.count)
    #expect(args.contains { $0.contains("kelp hook waiting --no-answer") }, "Codex shows its menu only after the hook")
}
