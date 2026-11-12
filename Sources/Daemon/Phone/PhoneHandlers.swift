import Core
import Foundation

// phone.*: Settings › Phone asks the bridge. Closed to agents (not in `AgentRules.methods`): a pairing link would let
// one answer its own questions.

extension PhoneStatus: AsyncHandled {
    func handle(_ phone: PhoneBridge) async throws -> PhoneState { await phone.state() }
}
extension PhonePair: AsyncHandled {
    func handle(_ phone: PhoneBridge) async throws -> PhoneState { try await phone.pair() }
}
extension PhoneUnpair: AsyncHandled {
    func handle(_ phone: PhoneBridge) async throws -> PhoneState { await phone.unpair(device) }
}

extension Methods {
    static let phoneMethods: [any Answered.Type] = [PhoneStatus.self, PhonePair.self, PhoneUnpair.self]
}
