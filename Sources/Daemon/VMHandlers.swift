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
        try vms.screen(name, args, session: Sessions.asker ?? session)
        return Done()
    }
}

extension VMDetailRead: Handled {
    func handle(_ vms: VMService) throws -> VMDetail? { vms.detail(name) }
}

extension VMCreate: Handled {
    /// It downloads gigabytes and takes memory from every chat's budget: the user's to decide.
    var notForAgents: String? { "Making a machine is the user's: they run kelp vm create in a terminal of theirs." }
    func handle(_ vms: VMService) throws -> VMInfo { try vms.create(self) }
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
    static let vmMethods: [any Handled.Type] = [
        VMList.self, VMCreate.self, VMControl.self, VMConnect.self, VMDetailRead.self, VMType.self,
        VMScreen.self, VMConfigure.self
    ]
}
