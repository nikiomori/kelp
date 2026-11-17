import Foundation

/// The site a page belongs to, as far as a login reaches. It is the page's scheme and registered domain, so
/// `mail.example.com` and `www.example.com` are one site, and `example.org` is another. A country's second level
/// (`co.uk`, `com.au`) and a host that gives each customer a subdomain (`vercel.app`, `github.io`…) count as the
/// suffix, so `a.vercel.app` and `b.vercel.app` are two sites. An IP address or a one-label host (`localhost`) is its
/// own site, with its port.
/// Limit: no full public suffix list; a shared host missing from `sharedHosts` is one site.
enum PageOrigin {
    static func of(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let labels = host.split(separator: ".").map(String.init)
        let numeric = host.contains(":") || labels.allSatisfy { $0.allSatisfy(\.isNumber) }
        if numeric || labels.count < 2 { return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "") }
        let country =
            labels.last?.count == 2
            && ["co", "com", "net", "org", "gov", "ac", "edu", "ne", "or"].contains(labels[labels.count - 2])
        // The site is the longest shared suffix the host ends in (`s3.amazonaws.com` before `amazonaws.com`), or else
        // the country's two labels or the top level, plus one more label.
        let suffix =
            (1..<labels.count).reversed().first { sharedHosts.contains(labels.suffix($0).joined(separator: ".")) }
            ?? (country ? 2 : 1)
        return "\(scheme)://" + labels.suffix(suffix + 1).joined(separator: ".")
    }

    /// Hosts whose subdomains are different people's sites.
    static let sharedHosts: Set<String> = [
        "vercel.app", "netlify.app", "github.io", "gitlab.io", "pages.dev", "workers.dev", "web.app", "firebaseapp.com",
        "herokuapp.com", "onrender.com", "fly.dev", "railway.app", "glitch.me", "repl.co", "ngrok.io", "ngrok-free.app",
        "azurewebsites.net", "cloudfront.net", "amazonaws.com", "s3.amazonaws.com", "appspot.com", "blogspot.com",
        "surge.sh", "deno.dev"
    ]
}
