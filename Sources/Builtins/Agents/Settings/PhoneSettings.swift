import AppKit
import Core
import CoreImage.CIFilterBuiltins
import DesignKit
import KelpKit
import SwiftUI

/// Settings › Phone: the agents on a phone's browser. The switch, the code a phone scans to pair (one phone, ten
/// minutes), the phones paired and whether the relay is reached. Watched (`phone`) while the page shows.
struct PhoneSettings: View {
    let app: AppModel
    @State private var watched: Watched?

    private var state: PhoneState? { app.latest(PhoneEvent.self)?.state }

    private var isOn: Bool { !app.settings[SettingKeys.phoneRelay].isEmpty }

    var body: some View {
        Section {
            Toggle(
                "Agents on your phone",
                isOn: Binding(
                    get: { isOn },
                    set: { app.settings.set(SettingKeys.phoneRelay, $0 ? SettingKeys.phoneRelayAddress : "") }))
        } footer: {
            Text(
                """
                See your agents, answer Allow or Deny, reply and start a new agent in a project from a phone’s \
                browser. What passes between the phone and this Mac is sealed with a key only the two hold: the \
                relay on the way can’t read it.
                """)
        }
        .task {
            // Let go with the page: `Watched` stops watching as this view's state goes.
            guard watched == nil else { return }
            let watching = Watched(.phone, in: app)
            watching.key = ""
            watched = watching
        }
        if isOn, let state, state.relay != nil {
            Section("Pair a Phone") {
                reached(state)
                if let link = state.link {
                    code(link, until: state.linkUntil)
                } else {
                    Button("Show Pairing Code") { Task { await pair() } }
                }
            }
            Section("Paired Phones") {
                if state.phones.isEmpty { Text("No phone is paired yet.").foregroundStyle(.secondary) }
                ForEach(state.phones) { phone in
                    HStack(spacing: Metrics.gap) {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: Metrics.lineGap) {
                            Text(phone.name)
                            Text(
                                phone.push
                                    ? String(localized: "Notifications on") : String(localized: "Notifications off")
                            )
                            .font(.ui(TextSize.caption)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Metrics.gap)
                        Button("Remove") {
                            Task { if await app.call(PhoneUnpair(device: phone.id)) != nil { app.watchAgain(.phone) } }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func pair() async { if await app.call(PhonePair()) != nil { app.watchAgain(.phone) } }

    private func reached(_ state: PhoneState) -> some View {
        let host = state.relay.flatMap { URL(string: $0)?.host } ?? ""
        return HStack(spacing: Metrics.gap) {
            Circle().fill(state.connected ? Color(nsColor: .systemGreen) : .secondary).frame(width: 7, height: 7)
            if state.connected {
                Text("Connected to \(host)")
            } else if let error = state.error {
                Text("Can’t reach \(host): \(error)").foregroundStyle(Color.textRed)
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

    /// The link as a QR code, a point a module: drawn larger without smoothing.
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
            keywords: ["Phone", "iPhone", "Android", "Pair", "QR", "Remote", "Notifications"], order: 52,
            tint: NSColor(hex: 0x34C759))
    }
}
