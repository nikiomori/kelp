import Foundation

/// The site a page belongs to, as far as a login reaches: its scheme and its domain's last two labels, so
/// `mail.example.com` and `www.example.com` are one site, `example.org` another. An IP address or a one-label host
/// (`localhost`) is itself, with its port. Limit: a two-part suffix (`co.uk`) counts as the domain, so every `x.co.uk`
/// is one site.
public enum PageOrigin {
    public static func of(_ u: URL?) -> String? {
        guard let u, let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".")
        let numeric = host.contains(":") || labels.allSatisfy { $0.allSatisfy(\.isNumber) }
        if numeric || labels.count < 2 { return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "") }
        return "\(scheme)://" + labels.suffix(2).joined(separator: ".")
    }
}
