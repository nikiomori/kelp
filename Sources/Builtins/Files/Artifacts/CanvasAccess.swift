import Foundation

/// What to do about Check's findings for VoiceOver (`CanvasScript.access`), under each one: a picture without words
/// gets Describe (Edit, with the picture chosen, where its Description is) and Decoration (alt="", written at once);
/// a button or a link without a name, a skipped heading level and a reading order turned by CSS get Mark (a mark on
/// the element with the finding as its note, for the agent).
enum CanvasAccess {
    /// A finding of Check's for VoiceOver: its board, what kind, and the element's data-id.
    static let finding =
        #"^(.+?)(?: \(dark\))?: (picture without a description|button without a name|link without a name|"#
        + #"h\d after h\d|reading order differs)\b.*? in \[data-id=([^\]]+)\]"#

    static func source(labels: [String: String]) -> String {
        "(function (L, FINDING) {\n" + body + "\n})(\(MarkdownTab.js(labels)), \(MarkdownTab.js(finding)));"
    }

    private static let body = """
          const K = window.kelpCanvas; if (!K) return;
          const finding = new RegExp(FINDING), before = window.kelpIssueFix;
          window.kelpIssueFix = (line, row) => {
            before?.(line, row);
            const m = line.match(finding); if (!m) return;
            const [, board, kind, id] = m, f = K.light(board);
            const e = f?.contentDocument?.querySelector('[data-id="' + CSS.escape(id) + '"]'); if (!e) return;
            const fix = K.el('div', 'kelp-ifix');
            const button = (title, act) => {
              const b = K.el('button', 'kelp-pill', title); b.onclick = act; fix.append(b);
            };
            if (kind.startsWith('picture')) {
              button(L.describe, () => { window.kelpEdit?.(true); window.kelpSelect?.(board, id); });
              button(L.decoration, () => {
                e.setAttribute('alt', '');
                K.post({ kind: 'attribute', board, id, name: 'alt', value: '' });
              });
            } else {
              button(L.mark, () => {
                K.setMode('mark');
                window.kelpMarks?.add(Object.assign({ kind: 'element', board, note: line.slice(board.length + 2) },
                  K.describe(e)));
              });
            }
            row.append(fix);
          };
        """
}
