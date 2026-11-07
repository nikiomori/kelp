import Foundation
import Testing
import WorkbenchKit

/// A login reaches a domain's subdomains, not another domain or scheme; a local server is its port.
@Test func aPagesSiteIsItsDomain() {
    func site(_ s: String) -> String? { PageOrigin.of(URL(string: s)) }
    #expect(site("https://mail.Example.com/inbox") == site("https://www.example.com"))
    #expect(site("https://example.com") != site("https://example.org"))
    #expect(site("https://example.com") != site("http://example.com"))
    #expect(site("http://localhost:3000") != site("http://localhost:4000"))
    #expect(site("http://127.0.0.1:3000/a") == "http://127.0.0.1:3000")
    #expect(site("about:blank") == nil)
    // A shared host's customers, and a country's second level, are each their own site.
    #expect(
        site("https://a.vercel.app") != site("https://b.vercel.app")
            && site("https://x.a.vercel.app") == site("https://a.vercel.app"))
    #expect(
        site("https://shop.co.uk") != site("https://bank.co.uk") && site("https://www.bbc.co.uk") == "https://bbc.co.uk"
    )
    #expect(site("https://a.s3.amazonaws.com") != site("https://b.s3.amazonaws.com"))
}
