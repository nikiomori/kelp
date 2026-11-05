extension MarkdownHTML {
    /// Slides: a page from `render` cut at its rules (`---`) into 16:9 slides, one under the next, their text sized by
    /// the slide's width. ← → (and space, Page Up/Down) step through them; Print gives a landscape page each.
    public static let slides = """
    <style>
    html{background:var(--subtle)}
    .markdown-body{max-width:none;padding:24px}
    .slide{container-type:inline-size;position:relative;width:min(100%,1100px);aspect-ratio:16/9;margin:0 auto 24px;
      background:var(--bg);border:1px solid var(--border);border-radius:10px;overflow:hidden}
    .slide-body{position:absolute;inset:0;padding:6cqw 8cqw;display:flex;flex-direction:column;justify-content:center;font-size:2.6cqw;line-height:1.4}
    .slide-body h1,.slide-body h2{border:0;padding:0;margin:0 0 .5em}
    .slide-body h1{font-size:2.4em}.slide-body h2{font-size:1.7em}
    .slide-body>:last-child{margin-bottom:0}
    .slide::after{content:attr(data-n);position:absolute;right:2.4cqw;bottom:1.6cqw;font-size:1.3cqw;color:var(--muted)}
    @page{size:landscape;margin:0}
    @media print{html{background:none}.markdown-body{padding:0}
      .slide{width:100%;margin:0;border:0;border-radius:0;break-after:page}}
    </style>
    <script>(function () {
      const page = document.querySelector('.markdown-body');
      if (!page) return;
      const blocks = [...page.children], groups = [[]];
      for (const b of blocks) { if (b.tagName === 'HR') groups.push([]); else groups[groups.length - 1].push(b); }
      page.replaceChildren();
      const shown = groups.filter(g => g.some(b => !b.hasAttribute('data-line') || b.textContent.trim()));
      shown.forEach((g, i) => {
        const s = document.createElement('section'), body = document.createElement('div');
        s.className = 'slide'; body.className = 'slide-body'; s.dataset.n = (i + 1) + ' / ' + shown.length;
        body.append(...g); s.append(body); page.append(s);
      });
      const all = [...page.querySelectorAll('.slide')];
      addEventListener('keydown', e => {
        const d = { ArrowRight: 1, ArrowDown: 1, PageDown: 1, ' ': 1, ArrowLeft: -1, ArrowUp: -1, PageUp: -1 }[e.key];
        if (!d || !all.length) return;
        e.preventDefault();
        const top = s => s.getBoundingClientRect().top + scrollY - 24;
        const now = all.reduce((b, s, j) => Math.abs(top(s) - scrollY) < Math.abs(top(all[b]) - scrollY) ? j : b, 0);
        scrollTo({ top: top(all[Math.max(0, Math.min(all.length - 1, now + d))]), behavior: 'smooth' });
      });
    })();</script>
    """
}
