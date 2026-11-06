import Foundation

/// The site a page belongs to, as far as a login reaches: its scheme and its registered domain, so `mail.example.com`
/// and `www.example.com` are one site, `example.org` another. A country's second level (`co.uk`, `com.au`) and a host
/// that gives each customer a subdomain (`vercel.app`, `github.io`…) count as the suffix, so `a.vercel.app` and
/// `b.vercel.app` are two sites. An IP address or a one-label host (`localhost`) is itself, with its port. Limit: no full
/// public suffix list; a shared host missing from `shared` is one site.
public enum PageOrigin {
    public static func of(_ u: URL?) -> String? {
        guard let u, let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        let numeric = host.contains(":") || labels.allSatisfy { $0.allSatisfy(\.isNumber) }
        if numeric || labels.count < 2 { return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "") }
        let two = labels.suffix(2).joined(separator: ".")
        let country = labels.last?.count == 2 && ["co", "com", "net", "org", "gov", "ac", "edu", "ne", "or"].contains(labels[labels.count - 2])
        return "\(scheme)://" + labels.suffix(country || shared.contains(two) ? 3 : 2).joined(separator: ".")
    }

    /// Hosts whose subdomains are different people's sites.
    static let shared: Set<String> = [
        "vercel.app", "netlify.app", "github.io", "gitlab.io", "pages.dev", "workers.dev", "web.app", "firebaseapp.com",
        "herokuapp.com", "onrender.com", "fly.dev", "railway.app", "glitch.me", "repl.co", "ngrok.io", "ngrok-free.app",
        "azurewebsites.net", "cloudfront.net", "amazonaws.com", "appspot.com", "blogspot.com", "surge.sh", "deno.dev"
    ]
}
