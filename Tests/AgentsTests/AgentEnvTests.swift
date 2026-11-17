import Core
import Foundation
import TestSupport
import Testing

@testable import Agents

/// An agent's env value whose name says it's a secret goes to the Keychain, not settings.json; the rest stay in the file.
@Test func whatAnEnvNameSaysIsASecret() {
    for secret in ["ANTHROPIC_API_KEY", "GITHUB_TOKEN", "CLIENT_SECRET", "DB_PASSWORD", "PROXY_AUTH"] {
        #expect(AgentManifest.isSecret(secret), "\(secret)")
    }
    for plain in ["PATH", "HOME", "NODE_OPTIONS", "CLAUDE_CONFIG_DIR", "MODEL"] {
        #expect(!AgentManifest.isSecret(plain), "\(plain)")
    }
}

/// At launch a secret kept in the Keychain is read back in place of its marker; a plain value is passed as it is, and a
/// marker with nothing behind it is empty, not the marker.
@Test func aSecretInTheKeychainIsReadBackAtLaunch() throws {
    _ = TestIsolation.root   // never the real keys
    let id = "agent-\(UUID().uuidString.prefix(8))"
    let account = AgentManifest.secretAccount(agent: id, key: "API_KEY")
    defer { Keychain.delete(account) }
    try Keychain.set("sk-123", account: account)
    let marker = AgentManifest.keychainValue
    let m = AgentManifest(
        id: id, name: "A", command: "a", env: ["API_KEY": marker, "MODE": "fast", "OTHER_TOKEN": marker])
    #expect(m.resolvedEnv == ["API_KEY": "sk-123", "MODE": "fast", "OTHER_TOKEN": ""])
}
