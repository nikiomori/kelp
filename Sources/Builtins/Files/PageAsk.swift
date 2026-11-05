import Foundation

/// On an agent's page, a button under the text you select: it posts the quote to `kelpSync` as `{kind: "ask", text}`, and
/// the tab types it into the chat that made the page for you to finish the question.
enum PageAsk {
    /// `label`: the button's words, already a JavaScript string literal.
    static func script(label: String) -> String {
        """
        <script>(function () {
          const b = document.createElement('button');
          b.textContent = \(label);
          b.style.cssText = 'position:absolute;z-index:2147483647;display:none;padding:4px 10px;border:0;border-radius:999px;'
            + 'font:500 12px -apple-system,BlinkMacSystemFont,sans-serif;background:#007aff;color:#fff;'
            + 'box-shadow:0 2px 6px rgba(0,0,0,.2);cursor:default';
          document.documentElement.appendChild(b);
          let quote = '';
          const hide = () => { b.style.display = 'none'; };
          addEventListener('mouseup', e => {
            if (e.target === b) return;
            setTimeout(() => {
              const s = getSelection();
              quote = String(s).trim();
              if (!quote || !s.rangeCount) return hide();
              const r = s.getRangeAt(0).getBoundingClientRect();
              b.style.left = (r.left + scrollX) + 'px'; b.style.top = (r.bottom + scrollY + 6) + 'px';
              b.style.display = 'block';
            }, 0);
          });
          addEventListener('mousedown', e => { if (e.target !== b) hide(); });
          b.addEventListener('mousedown', e => e.preventDefault());   // keeps the selection
          b.addEventListener('click', () => {
            webkit.messageHandlers.kelpSync?.postMessage({ kind: 'ask', text: quote });
            hide(); getSelection().removeAllRanges();
          });
        })();</script>
        """
    }
}
