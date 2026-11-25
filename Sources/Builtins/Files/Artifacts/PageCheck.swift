import Foundation

/// The check on an agent's doc or slides, as a canvas has (`CanvasScript`): links to files that aren't there (found in
/// the Markdown), and on the page drawn, pictures that don't load, links to a heading that isn't there and empty
/// headings (the page's own styles keep its text readable). The findings go where a canvas's go: `kelpSync` as
/// `{kind: "check", issues}`, and the Check tab of Mark's column (`kelp-check`).
enum PageCheck {
    /// The links in `markdown` to files in or beside `folder` that aren't there.
    static func missingFiles(_ markdown: String, folder: URL) -> [String] {
        markdown.matches(of: #/(!?)\[[^\]]*\]\(<?([^)\s>]+)>?(?:\s+"[^"]*")?\)/#).compactMap { match in
            let target = String(match.output.2)
            guard match.output.1.isEmpty, !target.contains("://"), !target.hasPrefix("#"), !target.hasPrefix("mailto:")
            else { return nil }
            let path = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
            let plain = path.removingPercentEncoding ?? path
            let file = plain.hasPrefix("/") ? URL(fileURLWithPath: plain) : folder.appendingPathComponent(plain)
            return FileManager.default.fileExists(atPath: file.standardizedFileURL.path)
                ? nil : "a link to \(target): no such file"
        }
    }

    static func source(known: [String]) -> String {
        """
        (function () {
          const known = \(MarkdownTab.js(known));
          const root = document.querySelector('.markdown-body') || document.body;
        \(body)
        })();
        """
    }

    private static let body = """
          function done() {
            const out = known.slice();
            for (const img of root.querySelectorAll('img'))
              if (img.complete && !img.naturalWidth) out.push('picture ' + img.getAttribute('src') + ": doesn't load");
            for (const a of root.querySelectorAll('a[href^="#"]')) {
              const id = decodeURIComponent(a.getAttribute('href').slice(1));
              if (id && !document.getElementById(id)) out.push('a link to #' + id + ': no heading there');
            }
            for (const h of root.querySelectorAll('h1, h2, h3, h4, h5, h6'))
              if (!h.textContent.trim()) out.push('an empty heading (' + h.tagName.toLowerCase() + ')');
            const issues = [...new Set(out)].slice(0, 40);
            window.kelpIssues = issues;
            dispatchEvent(new CustomEvent('kelp-check'));
            webkit.messageHandlers.kelpSync?.postMessage({ kind: 'check', issues });
          }
          if (document.readyState === 'complete') setTimeout(done, 50);
          else addEventListener('load', () => setTimeout(done, 50), { once: true });
        """
}
