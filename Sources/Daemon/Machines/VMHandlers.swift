import Core
import Foundation

// vm.*: the RPCs, each answered by VMService.

extension VMList: Handled {
    func handle(_ vms: VMService) throws -> [VMInfo] { vms.list(sessions: true) }
}

// Whose turn the screen is: the caller's session as its process says (`Sessions.asker`), what was sent only from outside
// every session (the user's own terminal or window).
extension VMType: Handled {
    /// No text types the machine's password (Type Password): into whatever has its focus, which the user looks at first.
    var notForAgents: String? {
        text == nil
            ? "Typing a machine's password is the user's: ask them to press Type Password at the top of its window "
                + "(kelp vm show <name> opens it) or in its tab in Kelp." : nil
    }
    func handle(_ vms: VMService) throws -> Done {
        try vms.type(name, text, session: Sessions.asker)
        return Done()
    }
}

extension VMScreen: Handled {
    func handle(_ vms: VMService) throws -> Done {
        _ = try vms.screen(name, args, session: Sessions.asker ?? session)
        return Done()
    }
}

extension VMUI: Handled {
    func handle(_ vms: VMService) throws -> String {
        try vms.screen(name, ["ui"] + (app.map { ["--app", $0] } ?? []), session: Sessions.asker)
    }
}

extension VMDetailRead: Handled {
    func handle(_ vms: VMService) throws -> VMDetail? { vms.detail(name) }
}

/// It downloads gigabytes and takes memory from every chat's budget: the user's to decide. An agent's asks them on its
/// row (Allow / Deny), as a database change does; the user's own (Kelp's window, their terminal) makes it at once.
extension VMCreate: AsyncHandled {
    func handle(_ asking: VMAsking, conn: Int) async throws -> VMInfo {
        if case .some(let session) = asking.sessions.store.agent(origin: Sessions.asker) {
            guard let session, let ls = asking.sessions.existing(session) else {
                throw RPCError.refused("Making a machine is the user's: tell them kelp vm create \(name) makes one.")
            }
            guard VMs.isName(name) else {   // not asked for one that can't be made
                throw RPCError.invalidParams(
                    "A machine's name: up to 20 lowercase letters, digits and dashes, starting with a letter.")
            }
            let question = Self.question(name, image: image, file: file)
            ls.askForKelp(question)
            let answer = await asking.sessions.permissions.waitForKelp(
                session, question: question, within: Self.answerWithin,
                asker: asking.sessions.clients.connection(conn)?.peerPID)
            ls.kelpAsked(question)
            guard answer == "allow" else {
                throw RPCError.refused(
                    answer == "deny" ? "The user didn't allow making \(name)." : "Nobody answered: \(name) wasn't made."
                )
            }
        }
        return try await asking.offloads.run { [self] in try asking.vms.create(self) }
    }

    /// What the agent's row asks: "Allow making a machine, deb (Debian 13: about 0.2 GB to download)?".
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

/// What answers `vm.create`: the machines, and the sessions whose rows ask the user for an agent's.
struct VMAsking: Sendable {
    let vms: VMService, sessions: Sessions, offloads: Slots
}

extension VMControl: Handled {
    /// Other chats run commands in it: shutting it down or deleting it is the user's (sleeping is fine: the next command wakes it).
    var notForAgents: String? {
        [.stop, .delete].contains(action)
            ? "Shutting a machine down or deleting it is the user's: other chats may be running in it." : nil
    }
    func handle(_ vms: VMService) throws -> VMInfo { try vms.control(name, action) }
}

extension VMConnect: Handled {
    func handle(_ vms: VMService) throws -> VMConnection { try vms.connect(name, cwd: cwd) }
}

extension Methods {
    static let vmMethods: [any Answered.Type] = [
        VMList.self, VMType.self, VMScreen.self, VMUI.self, VMDetailRead.self, VMCreate.self, VMControl.self,
        VMConnect.self
    ]
}
