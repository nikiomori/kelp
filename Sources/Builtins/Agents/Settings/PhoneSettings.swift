import AppKit
import Core
import CoreImage.CIFilterBuiltins
import DesignKit
import KelpKit
import SwiftUI

/// The Settings › Phone page, which puts the agents in a phone's browser. It holds the switch, the code a phone scans
/// to pair (good for one phone, for ten minutes), how the phone reaches this Mac and whether that is ready, and the
/// paired phones. The page watches the `phone` topic while it shows.
struct PhoneSettings: View {
    let app: AppModel
    @State private var watched: Watched?

    private var state: PhoneState? { app.latest(PhoneEvent.self)?.state }

    /// How the phone reaches this Mac. It is what `phone.via` says, or else the relay when a relay is named (the way
    /// Kelp 0.14 stored it).
    private var via: String {
        let via = app.settings[SettingKeys.phoneVia]
        return via.isEmpty && !app.settings[SettingKeys.phoneRelay].isEmpty ? "relay" : via
    }
    private var isOn: Bool { !via.isEmpty }

    /// What the switch turns on and how it is kept private, behind the row's ⓘ.
    private static var what: String {
        String(
            localized:
                """
                See your agents, answer Allow or Deny and reply from a phone’s browser. What passes between the \
                phone and this Mac is sealed with a key only the two hold: nothing on the way can read it.
                """)
    }

    var body: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { isOn },
                    set: { on in
                        app.settings.set(SettingKeys.phoneVia, on ? "tailscale" : "")
                        if !on { app.settings.set(SettingKeys.phoneRelay, "") }
                    })
            ) {
                // One line, as every row of Settings is: what it does and how it is kept private is behind the ⓘ.
                HStack(spacing: Metrics.gap) {
                    Text("Agents on your phone")
                    HelpMark(text: Self.what)
                }
            }
        }
        .task {
            // The watch ends with the page, because `Watched` stops watching when this view's state goes away.
            guard watched == nil else { return }
            let watching = Watched(.phone, in: app)
            watching.key = ""
            watched = watching
        }
        if !isOn, let error = state?.error { Text(error).foregroundStyle(Color.textRed) }
        if isOn {
            way
            Section {
                Toggle(
                    "Start agents from the phone",
                    isOn: Binding(
                        get: { app.settings[SettingKeys.phoneStartAgents] },
                        set: { app.settings.set(SettingKeys.phoneStartAgents, $0) }))
            } footer: {
                Text("Off: a phone reads, answers, writes to and stops the agents that run, and starts none.")
            }
        }
        if isOn, let state {
            TitledSection("Pair a Phone") {
                reached(state)
                if let link = state.link {
                    code(link, until: state.linkUntil)
                } else {
                    Button("Show Pairing Code") { Task { await pair() } }.disabled(state.address == nil)
                }
            }
        }
        if isOn, let state, state.via != nil {
            TitledSection("Paired Phones") {
                if state.phones.isEmpty {
                    EmptyState(String(localized: "No Phone Paired Yet"), symbol: "iphone", lifted: false)
                }
                ForEach(state.phones) { phone in
                    HStack(spacing: Metrics.gap) {
                        Image(systemName: "iphone").font(.symbol()).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: Metrics.lineGap) {
                            Text(phone.name)
                            Text(
                                phone.push
                                    ? String(localized: "Notifications on") : String(localized: "Notifications off")
                            )
                            .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Metrics.gap)
                        Button("Remove…") {
                            Task {
                                let sure = await confirm(
                                    String(localized: "Remove “\(phone.name)”?"),
                                    detail: String(localized: "It can’t reach this Mac until it is paired again."),
                                    action: String(localized: "Remove"), destructive: true)
                                guard sure else { return }
                                if await app.call(PhoneUnpair(device: phone.id)) != nil { app.watchAgain(.phone) }
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func pair() async { if await app.call(PhonePair()) != nil { app.watchAgain(.phone) } }

    /// The picker for how the phone reaches this Mac: Tailscale, an address of the user's own, or Kelp's relay. Each
    /// choice says what it needs.
    @ViewBuilder private var way: some View {
        let port = UInt16(exactly: app.settings[SettingKeys.phonePort]) ?? 0
        Section {
            Picker(
                "How the phone reaches this Mac",
                selection: Binding(get: { via }, set: { app.settings.set(SettingKeys.phoneVia, $0) })
            ) {
                Text("Tailscale").tag("tailscale")
                Text("Your Own Address").tag("address")
                Text("Kelp’s Relay").tag("relay")
            }
            if via == "tailscale", let steps = state?.tailscale { tailscale(steps) }
            if via == "address" {
                TextField(
                    "Address",
                    text: Binding(
                        get: { app.settings[SettingKeys.phoneAddress] },
                        set: { app.settings.set(SettingKeys.phoneAddress, $0) }),
                    prompt: Text(verbatim: "https://mac.example.com"))
            }
        } footer: {
            switch via {
            case "tailscale":
                Text(
                    """
                    The phone needs access to this Mac on port 8443 under your Tailscale access rules. \
                    Scan a pairing code to use Kelp.
                    """)
            case "address" where port != 0:
                Text(
                    """
                    Kelp serves the phone’s page itself at http://127.0.0.1:\(Int(port)). Point your tunnel or proxy \
                    there and give the HTTPS address the phone opens.
                    """)
            case "address": Text("Set phone.port to a whole number from 1 to 65535.")
            default:
                Text(
                    """
                    The page and the sealed calls go through Kelp’s server at phone.kelpide.com. It can’t read the \
                    calls, but the page your phone runs comes from it.
                    """)
            }
        }
    }

    /// Tailscale's three steps, each ticked once Kelp sees it done, with a link or hint for the first step that isn't.
    @ViewBuilder private func tailscale(_ steps: TailscaleSteps) -> some View {
        step(String(localized: "Tailscale is installed"), done: steps.installed) {
            link(String(localized: "Download Tailscale"), TailscaleSteps.download)
        }
        step(String(localized: "Signed in to Tailscale"), done: steps.signedIn, next: steps.installed) {
            Text("Open Tailscale and sign in").foregroundStyle(.secondary)
        }
        step(String(localized: "Tailscale serves this Mac over HTTPS"), done: steps.serving, next: steps.signedIn) {
            link(String(localized: "HTTPS settings"), TailscaleSteps.certificates)
        }
    }

    /// `next` is true when the steps before this one are done, so this is the step to do now.
    private func step(_ title: String, done: Bool, next: Bool = true, @ViewBuilder todo: () -> some View)
        -> some View
    {
        HStack(spacing: Metrics.gap) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.symbol())
                .foregroundStyle(.secondary)   // done is the filled mark: the shape says it, not a colour
            Text(title).foregroundStyle(done || next ? .primary : .secondary)
            Spacer(minLength: Metrics.gap)
            if !done, next { todo().font(.ui(TextSize.caption)) }
        }
    }

    private func link(_ title: String, _ address: String) -> some View {
        URL(string: address).map { Link(title, destination: $0).buttonStyle(.kelpLink) }
    }

    private func reached(_ state: PhoneState) -> some View {
        let host = (state.address ?? state.relay).flatMap { URL(string: $0)?.host } ?? ""
        return HStack(spacing: Metrics.gap) {
            // Reached is a filled dot and not reached a ring, as an integration's is; red when it failed.
            StateDot(state.error != nil ? .broken : state.connected && state.address != nil ? .on : .off)
            if let error = state.error {
                Text(error).foregroundStyle(Color.textRed)
            } else if state.address == nil && !state.connected && via != "relay" {
                Text("Starting the phone server…").foregroundStyle(.secondary)
            } else if state.address == nil {
                Text("Give the address the phone opens.").foregroundStyle(.secondary)
            } else if state.connected {
                Text("Ready at \(host)")
            } else {
                Text("Connecting to \(host)…").foregroundStyle(.secondary)
            }
        }
        .font(.ui(TextSize.caption))
    }

    private func code(_ link: String, until: Date?) -> some View {
        HStack(alignment: .top, spacing: Metrics.inset) {
            if let image = Self.qr(link) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 148, height: 148)
                    .padding(Metrics.gapWide).background(.white, in: RoundedRectangle(cornerRadius: Metrics.radiusMD))
                    .accessibilityLabel("Pairing code")
            }
            VStack(alignment: .leading, spacing: Metrics.gapWide) {
                Text("Scan it with the phone’s camera, or open the link there.")
                if let until {
                    Text("For one phone, until \(until.formatted(date: .omitted, time: .shortened)).")
                        .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                }
                Text(link).font(.uiMono(TextSize.caption)).foregroundStyle(.secondary).lineLimit(2)
                    .truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: Metrics.gapWide) {
                    Button("Copy Link") { copyText(link) }
                    Button("New Code") { Task { await pair() } }
                }
                .controlSize(.small)
            }
        }
    }

    /// Returns the link as a QR code at one point per module, so it is drawn larger without smoothing.
    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let image = NSImage(size: output.extent.size)
        image.addRepresentation(NSCIImageRep(ciImage: output))
        return image
    }
}

extension PhoneEvent: Pushed {
    package var key: String { "" }
    package static var forgottenWith: WatchTopic? { .phone }
}

extension Builtins {
    /// Settings › Phone.
    static func phoneSection(_ app: AppModel) -> SettingsSection {
        SettingsSection(
            id: "phone", title: "Phone", icon: "iphone", specs: [], custom: { AnyView(PhoneSettings(app: app)) },
            keywords: ["Phone", "iPhone", "Android", "Pair", "QR", "Remote", "Notifications"], order: 52)
    }
}
