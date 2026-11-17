import Foundation

/// A virtual machine that Kelp runs for agents on Apple Virtualization. It has a folder of its own under
/// `<home>/vms/<name>` (its disk, keys, sockets) and is run by a `kelp-vm` process, the only one with the
/// virtualization entitlement. Agents reach it over SSH through that process (vsock, with no network address), with one
/// connection for each command. When no connection is open, the machine pauses and then sleeps to disk, and it wakes on
/// the next one.
public struct VMMachine: Codable, Sendable, Equatable {
    public var name: String
    /// The kind of machine as the wire and machine.json write it: `linux`, `macos`, `android` or `ios` (`kind`).
    public var os: String
    /// The `VMImage.id` of the image the machine was made from.
    public var image: String
    public var cpus: Int, memoryMiB: Int, diskGiB: Int
    /// The account inside the machine. It uses the Mac user's name, so paths and prompts read the same.
    public var user: String
    /// Whether x86-64 Linux programs run through Rosetta (when the Mac has it).
    public var rosetta: Bool
    public var network: Bool
    /// A UUID set when the machine is made, which tells apart machines made under the same name. A machine deleted and
    /// made again under its name is a different one, so the first machine's making stops rather than going on in the
    /// new machine's folder. Nil for machines made before this field.
    public var made: String?

    public init(
        name: String, os: String = "linux", image: String, cpus: Int, memoryMiB: Int, diskGiB: Int, user: String,
        rosetta: Bool = true, network: Bool = true
    ) {
        self.name = name
        self.os = os
        self.image = image
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.diskGiB = diskGiB
        self.user = user
        self.rosetta = rosetta
        self.network = network
    }
}

extension VMMachine {
    public var kind: VMKind { VMKind(os) }
}

/// The kind of machine (`VMMachine.os` and `VMImage.os` on the wire), and what follows from it.
public enum VMKind: String, Sendable, CaseIterable {
    case linux, macos, android, ios

    /// Reads a kind from its wire name. A name this build doesn't know reads as Linux, as it always has.
    public init(_ os: String) { self = VMKind(rawValue: os) ?? .linux }

    /// Whether the machine has a screen of its own, shown in a window (`vm.control` show) and read and driven by agents
    /// (`vm.screen`).
    public var hasScreen: Bool { self != .linux }
    /// Whether the machine's processors, memory and disk can change after it is made (`vm.configure`). An Android or
    /// iOS device has fixed ones of its own.
    public var resizable: Bool { self == .linux || self == .macos }
    /// Whether Mac folders are shared into the machine: a project at its own path, and the exchange folder
    /// (`VMInfo.files`). Android and iOS machines take files through adb and simctl instead.
    public var sharesFolders: Bool { self == .linux || self == .macos }
    /// The memory the machine may be given, in GB: up to half the Mac's (`macGiB`), and at least what it needs (4 for
    /// macOS).
    public func memoryRange(macGiB: Int = Int(ProcessInfo.processInfo.physicalMemory >> 30)) -> ClosedRange<Int> {
        let least = self == .macos ? 4 : 1
        return least...max(least, macGiB / 2)
    }
}

public enum VMState: String, Codable, Sendable, CaseIterable {
    /// The machine's image is downloading or its disk is being made (`VMInfo.detail` says how far).
    case creating
    /// The machine is shut down, and the next command boots it (a few seconds).
    case off
    /// The machine is saved to disk and holds none of the Mac's memory. The next command wakes it in under a second.
    case sleeping
    case starting, running
    /// The machine is stopped where it was and still holds its memory, so it wakes at once.
    case paused
    case error

    /// Whether the machine holds the Mac's memory: running, paused, or starting.
    public var isUp: Bool { self == .running || self == .paused || self == .starting }
}

public enum VMs {
    /// Whether `name` is a valid machine name. It is a host name, a folder name and part of socket paths, so it must be
    /// short and lowercase, with no dots.
    public static func isName(_ name: String) -> Bool {
        (1...20).contains(name.count) && name.first?.isLetter == true
            && name.allSatisfy { ("a"..."z").contains(String($0)) || $0.isNumber || $0 == "-" }
    }

    /// Returns a Linux account name made from the Mac user's name, or "kelp" when that doesn't work.
    public static func user(_ mac: String) -> String {
        let ok =
            !mac.isEmpty && mac.count <= 32 && mac.first.map { $0.isLowercase || $0 == "_" } == true
            && mac.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-" } && mac != "root"
        return ok ? mac : "kelp"
    }

    /// Rosetta's binfmt line (Apple's "Running Intel binaries in Linux VMs with Rosetta").
    static let rosettaBinfmt =
        #":rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/rosetta/rosetta:CF"#

    /// Returns cloud-init's user-data for the first boot: the account with its key, the mount for the shared folders,
    /// and Rosetta.
    public static func userData(_ machine: VMMachine, publicKey: String, timeZone: String) -> String {
        var config = """
            #cloud-config
            hostname: \(machine.name)
            timezone: \(timeZone)
            ssh_pwauth: false
            users:
              - name: \(machine.user)
                sudo: ALL=(ALL) NOPASSWD:ALL
                shell: /bin/bash
                ssh_authorized_keys:
                  - \(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))

            """
        if machine.rosetta {
            config += """
                mounts:
                  - [rosetta, /mnt/rosetta, virtiofs, "defaults,nofail", "0", "0"]
                write_files:
                  - path: /etc/binfmt.d/rosetta.conf
                    content: |
                      \(rosettaBinfmt)
                runcmd:
                  - [systemctl, restart, systemd-binfmt]

                """
        }
        return config
    }

    /// Returns the machine's ssh_config, used with `ssh -F` so the user's own config plays no part. `<name>` is for
    /// agents and people, with a connection each, and counts as use. `<name>-own` is for kelp-vm's own reads (the
    /// clock, memory) and doesn't count.
    public static func sshConfig(_ machine: VMMachine, folder: VMFolder) -> String {
        func host(_ alias: String, _ socket: URL) -> String {
            """
            Host \(alias)
              HostName \(machine.name)
              User \(machine.user)
              IdentityFile "\(folder.key.path)"
              IdentitiesOnly yes
              UserKnownHostsFile "\(folder.knownHosts.path)"
              StrictHostKeyChecking accept-new
              ProxyCommand /usr/bin/nc -U \(ShellQuote.word(socket.path))
              ServerAliveInterval 15
              LogLevel ERROR

            """
        }
        // Kelp's own reads come every few seconds while the machine is watched, so they share one connection kept for
        // a minute instead of a handshake each.
        let reuse = """
              ControlMaster auto
              ControlPath "\(folder.file("own.cm").path)"
              ControlPersist 60

            """
        return host(machine.name, folder.ssh) + host(machine.name + "-own", folder.own) + reuse
    }

    /// How many folders can be shared at once. Each gets its own virtio-fs device (tag `kelp<n>`), because giving one
    /// device a new set of folders leaves every handle the guest holds on it stale. A ninth folder takes the slot used
    /// longest ago.
    public static let shareSlots = 8

    /// Returns the command line run inside the machine. It mounts `folder` at its own path from its slot (again when
    /// that path holds another slot or went stale), then changes to `cwd`, then runs the command.
    public static func prefix(slot: Int, folder: String, cwd: String, os: VMKind = .linux) -> String {
        let dir = ShellQuote.word(folder), tag = "kelp\(slot)", cd = "cd \(ShellQuote.word(cwd)) || exit 1; "
        guard os == .macos else {
            return "{ [ \"$(findmnt -n -o SOURCE --mountpoint \(dir))\" = \(tag) ] && ls \(dir) >/dev/null 2>&1; } "
                + "|| { sudo umount -l \(dir) 2>/dev/null; sudo mount --mkdir -t virtiofs \(tag) \(dir); } || exit 1; "
                + cd
        }
        // On macOS, mount(8) lists the share as "kelp3 on /path (virtiofs, …)", and mount_virtiofs needs the folder
        // to exist first.
        return "{ mount | grep -qF \(ShellQuote.word("\(tag) on \(folder) (")) && ls \(dir) >/dev/null 2>&1; } "
            + "|| { sudo umount -f \(dir) 2>/dev/null; sudo mkdir -p \(dir) && sudo mount_virtiofs \(tag) \(dir); } || exit 1; "
            + cd
    }

    /// The memory the guest keeps beyond what it uses, so a build that starts doesn't wait for memory.
    public static let headroomMiB = 1024

    /// Returns the balloon's next target in MiB: what the guest uses plus `headroomMiB`, at least 1 GiB and at most the
    /// machine's whole memory. When the guest runs short, it adds a GiB at once. A change of less than 256 MiB leaves
    /// the target as it was. The guest counts the balloon's share as used.
    public static func memoryTarget(totalMiB: Int, availableMiB: Int, targetMiB: Int, machineMiB: Int) -> Int {
        let used = totalMiB - availableMiB - (machineMiB - targetMiB)
        var want = max(1024, used + headroomMiB)
        if availableMiB < 512 { want = max(want, targetMiB + 1024) }
        want = min(machineMiB, want)
        return abs(want - targetMiB) < 256 ? targetMiB : want
    }

    /// Returns what runs after `prefix`: the command (or a login shell when it is empty) under bash's login profile.
    /// The bash is named `kelp-vm-run:<session>` in argv[0] ("-" with no session), which `detailScript` finds with ps
    /// on both Linux and macOS. The EXIT trap keeps that bash alive, because without one bash would exec a lone command
    /// in its place and lose the name.
    public static func command(_ command: String, session: String?) -> String {
        let id = (session ?? "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let run = "exec -a kelp-vm-run:\(id.isEmpty ? "-" : id) bash -l"
        return command.isEmpty ? run : run + " -c " + ShellQuote.word(trapped + command)
    }
    static let trapped = "trap : EXIT; "

    /// A script run inside the machine over `<name>-own`, on Linux and macOS. It prints the machine's address, the TCP
    /// ports the account's own programs listen on (leaving out the system's DNS), then each `kelp vm run` still going
    /// (pid, elapsed time, argv). Sections are split by "@".
    public static let detailScript = #"""
        { hostname -I 2>/dev/null || ipconfig getifaddr en0; } | cut -d' ' -f1
        echo @
        if command -v ss >/dev/null; then ss -ltnpH 2>/dev/null | grep 'users:' | awk '{n=split($4,a,":"); print a[n]}'
        else lsof -nP -iTCP -sTCP:LISTEN -a -u "$(id -u)" 2>/dev/null | awk 'NR>1 {n=split($9,a,":"); print a[n]}'; fi | sort -un
        echo @
        ps -U "$(id -u)" -o pid=,etime=,args= | awk '$3 ~ /^kelp-vm-run:/'
        g="$HOME/Applications/KelpGuest.app/Contents/MacOS/KelpGuest"
        [ -x "$g" ] && { echo @; "$g" status 2>&1 || echo "not running"; }
        """#

    public static func parseDetail(_ text: String) -> VMDetail {
        // Sections are separated by a line holding "@", so an empty section is two such lines in a row.
        var parts: [[String]] = [[]]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "@" { parts.append([]) } else if !line.isEmpty { parts[parts.count - 1].append(String(line)) }
        }
        let lines = { (index: Int) in parts.count > index ? parts[index] : [] }
        var detail = VMDetail(address: lines(0).first.flatMap { $0.isEmpty ? nil : $0 })
        detail.ports = lines(1).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        detail.runs = lines(2).compactMap(run)
        if parts.count > 3 {
            // Kelp Guest reports only whether it may read controls. kelp-vm reports whose turn it is on the screen
            // (`VMService.detail`).
            let guest = lines(3)
            detail.guest = .init(
                running: !guest.contains("not running") && !guest.isEmpty,
                accessibility: guest.contains("accessibility: on"))
        }
        return detail
    }

    /// Parses a ps line like "  812     01:02:41 kelp-vm-run:abc -l -c npm test" into pid, seconds, session and
    /// command.
    static func run(_ line: String) -> VMDetail.Run? {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 3, let pid = Int(fields[0]), fields[2].hasPrefix("kelp-vm-run:") else { return nil }
        let argv = fields[2].dropFirst("kelp-vm-run:".count)
        let session = String(argv.prefix { $0 != " " })
        var command = argv.dropFirst(session.count).trimmingCharacters(in: .whitespaces)
        for flags in ["-l -c " + trapped, "-l -c ", "-l"] where command.hasPrefix(flags) {
            command = String(command.dropFirst(flags.count))
            break
        }
        return VMDetail.Run(
            pid: pid, seconds: seconds(fields[1]), session: session == "-" ? nil : session, command: command)
    }

    /// Converts ps's elapsed time, "[[dd-]hh:]mm:ss", into seconds.
    static func seconds(_ etime: String) -> Int {
        let dayParts = etime.split(separator: "-")
        let days = dayParts.count == 2 ? Int(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Int($0) }
        return days * 86400 + clock.reduce(0) { $0 * 60 + $1 }
    }

    /// The tag of the exchange folder's share. A macOS guest mounts it by itself under /Volumes/My Shared Files/Kelp,
    /// and a Linux guest mounts it by the tag. Either way, `filesSetup` makes it `~/Kelp` as the machine boots.
    public static let filesTag = "kelpfiles"
    public static func filesSetup(os: VMKind) -> String {
        os == .macos
            ? #"[ -e ~/Kelp ] || ln -s "/Volumes/My Shared Files/Kelp" ~/Kelp"#
            : "mountpoint -q ~/Kelp || { mkdir -p ~/Kelp && sudo mount -t virtiofs \(filesTag) ~/Kelp; }"
    }

    /// The path of Kelp Guest's program inside a macOS machine (`kelp vm ui`, `press`), which runs over SSH.
    public static let guestProgram = "\"$HOME/Applications/KelpGuest.app/Contents/MacOS/KelpGuest\""

    /// Whether `path` may be shared with a machine: a folder below the home folder, not the home folder itself or above.
    public static func mayShare(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        func inside(_ candidate: String) -> Bool {
            candidate.hasPrefix(home + "/")
                && ![".ssh", ".kelp", "Library"].contains(
                    candidate.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) ?? "")
        }
        // Check where the path really is too, because a link in a project to ~/.ssh would share ~/.ssh.
        return inside(URL(fileURLWithPath: path).standardizedFileURL.path) && Paths.real(path).map(inside) != false
    }
}
