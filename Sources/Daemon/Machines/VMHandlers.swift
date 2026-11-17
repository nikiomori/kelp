import Core
import Foundation

// The vm.* RPCs. VMService answers each of them.

extension VMList: Handled {
    static let agents = AgentAccess.reads
    func handle(_ vms: VMService) throws -> [VMInfo] { vms.list(sessions: true) }
}

// The screen's turn goes to the caller's session, as the caller's process tells it (`Sessions.asker`). That is nil
// only for a request sent from outside every session (the user's own terminal or window).
extension VMType: Handled {
    static let agents = AgentAccess.acts
    /// With no text, the request types the machine's password (Type Password) into whatever has the focus in the
    /// machine. Only the user may send it, because the user looks at what has the focus first.
    var fence: Fence {
        Fence(
            notForAgents: text == nil
                ? "Typing a machine's password is the user's: ask them to press Type Password at the top of its window "
                    + "(kelp vm show <name> opens it) or in its tab in Kelp." : nil)
    }
    func handle(_ vms: VMService) throws -> Done {
        try vms.type(name, text, session: Sessions.asker)
        return Done()
    }
}

extension VMScreen: Handled {
    static let agents = AgentAccess.acts
    func handle(_ vms: VMService) throws -> Done {
        _ = try vms.screen(name, args, session: Sessions.asker ?? session)
        return Done()
    }
}

extension VMUI: Handled {
    static let agents = AgentAccess.acts
    func handle(_ vms: VMService) throws -> String {
        try vms.screen(name, ["ui"] + (app.map { ["--app", $0] } ?? []), session: Sessions.asker)
    }
}

extension VMDetailRead: Handled {
    static let agents = AgentAccess.reads
    func handle(_ vms: VMService) throws -> VMDetail? { vms.detail(name) }
}

/// Making a machine downloads gigabytes and takes memory from every chat's budget, so the user decides. When an agent
/// asks, the question appears on the agent's row (Allow / Deny), as it does for a database change. When the user asks
/// (from Kelp's window or their own terminal), the machine is made at once.
extension VMCreate: AsyncHandled {
    // An agent may ask for a machine it needs, which is made only once the user allows it on the agent's row.
    static let agents = AgentAccess.acts
    func handle(_ asking: VMAsking, conn: Int) async throws -> VMInfo {
        if case .some(let session) = asking.asks.store.agent(origin: Sessions.asker) {
            guard let session, let ls = asking.asks.existing(session) else {
                throw RPCError.refused("Making a machine is the user's: tell them kelp vm create \(name) makes one.")
            }
            guard VMs.isName(name) else {   // the user isn't asked about a name that can't be made
                throw RPCError.invalidParams(
                    "A machine's name: up to 20 lowercase letters, digits and dashes, starting with a letter.")
            }
            let question = Self.question(name, image: image, file: file)
            ls.askForKelp(question)
            let answer = await asking.asks.permissions.waitForKelp(
                session, question: question, within: Self.answerWithin,
                asker: asking.asks.clients.connection(conn)?.peerPID)
            ls.kelpAsked(question)
            guard answer == "allow" else {
                throw RPCError.refused(
                    answer == "deny" ? "The user didn't allow making \(name)." : "Nobody answered: \(name) wasn't made."
                )
            }
        }
        return try await asking.offloads.run { [self] in try asking.vms.create(self) }
    }

    /// Returns the question the agent's row asks, such as "Allow making a machine, deb (Debian 13: about 0.2 GB to
    /// download)?".
    static func question(_ name: String, image: String?, file: String?) -> String {
        let what =
            switch file.map({ _ in "file" }) ?? image ?? "debian-13" {
            case "file": "from \((file.map { ($0 as NSString).lastPathComponent }) ?? "a file")"
            case "macos": "macOS: over 20 GB to download, 6 GB of memory while it runs"
            case "android": "Android, from your SDK"
            case "ios": "iOS, a simulator of your Xcode"
            default: "\(VMImage.named(image ?? "debian-13")?.title ?? "Linux"): about 0.2 GB to download"
            }
        return "Allow making a machine, \(name) (\(what))?"
    }
}

/// What `vm.create` is answered with: the machines, and the sessions whose rows ask the user on an agent's behalf.
struct VMAsking: Sendable {
    let vms: VMService, asks: AgentAsks, offloads: Slots
}

extension VMControl: Handled {
    static let agents = AgentAccess.acts
    /// Only the user may shut a machine down or delete it, because other chats run commands in it. An agent may put
    /// it to sleep, because the next command wakes it.
    var fence: Fence {
        Fence(
            notForAgents: [.stop, .delete].contains(action)
                ? "Shutting a machine down or deleting it is the user's: other chats may be running in it." : nil)
    }
    func handle(_ vms: VMService) throws -> VMInfo { try vms.control(name, action) }
}

extension VMConnect: Handled {
    static let agents = AgentAccess.acts
    // `cwd` is the folder a command runs in on the machine, which is the project's own folder on the Mac.
    var fence: Fence { Fence(writesInFolder: cwd) }
    func handle(_ vms: VMService) throws -> VMConnection { try vms.connect(name, cwd: cwd) }
}

extension Methods {
    static let vmMethods: [any Answered.Type] = [
        VMList.self, VMType.self, VMScreen.self, VMUI.self, VMDetailRead.self, VMCreate.self, VMControl.self,
        VMConnect.self
    ]
}
