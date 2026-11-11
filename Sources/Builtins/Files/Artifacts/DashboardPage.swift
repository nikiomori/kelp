import Foundation

/// A dashboard's canvas as a page of data (`CanvasPage.View.dashboard`): its boards fill the pane one view at a time
/// (a switch at the top right when there's more than one), in the window's theme, and the pointer over a figure shows
/// where it came from and when (its `data-source`), through the sheet `CanvasEdit` puts over the boards (their frames
/// run no script), on in View as well.
enum DashboardPage {
    /// `noSource`: what a figure without a source says. JavaScript, after `CanvasEdit` and `CanvasEditMode`.
    static func source(noSource: String) -> String {
        """
        (function () {
          const K = window.kelpCanvas; if (!K) return;
          const frames = [...document.querySelectorAll('.frame')].filter(f => f.querySelector('iframe'));
          if (frames.length > 1) {
            const seg = K.el('span', 'kelp-seg'), views = K.el('div', 'kelp-float kelp-views');
            const show = i => {
              frames.forEach((f, j) => f.classList.toggle('kelp-off', j !== i));
              [...seg.children].forEach((b, j) => b.classList.toggle('on', j === i));
              window.kelpFit?.();
            };
            frames.forEach((f, i) => {
              const b = K.el('button', null, (f.querySelector('.name')?.textContent || '').split(' · ')[0]);
              b.onclick = () => show(i);
              seg.append(b);
            });
            views.append(seg);
            document.body.append(views);
            show(0);
          }
          const tip = K.el('div', 'kelp-src');
          document.body.append(tip);
          const peek = () => {
            if (!K.mode()) K.setMode('peek');
            K.sheet.style.cursor = K.mode() === 'peek' ? 'default' : '';
          };
          const mark = window.kelpMark, edit = window.kelpEdit;
          window.kelpMark = on => { mark(on); peek(); };
          if (edit) window.kelpEdit = on => { edit(on); peek(); };
          K.sheet.addEventListener('mousemove', e => {
            const at = K.mode() === 'peek' && K.under(e, true), v = at && at.e.closest('[data-value]');
            if (!v) return tip.style.display = 'none';
            const b = K.box(at.f, v);
            tip.textContent = v.getAttribute('data-source') || \(MarkdownTab.js(noSource));
            tip.classList.toggle('kelp-src-none', !v.hasAttribute('data-source'));
            Object.assign(tip.style, { display: 'block', left: b.x + 'px', top: (b.y + b.h + 6) + 'px' });
          });
          K.sheet.addEventListener('mouseleave', () => { tip.style.display = 'none'; });
          peek();
        })();
        """
    }

    static let style = """
        body.kelp-dash { padding: 0 0 40px; background: var(--k-card); }
        .kelp-dash #kelp-canvas { gap: 0; margin: 0 auto; }
        .kelp-dash .row h2, .kelp-dash .name { display: none; }
        .kelp-dash .boards { gap: 0; }
        .kelp-dash iframe { border-radius: 0; box-shadow: none; }
        .kelp-dash .frame.kelp-off { display: none; }
        .kelp-views { top: 10px; right: 14px; }
        .kelp-with-col .kelp-views { right: 274px; }
        .kelp-src { position: absolute; z-index: 25; display: none; max-width: 280px; padding: 6px 9px;
          border-radius: 8px;
          background: var(--k-float); color: var(--k-label); font: 12px/1.35 -apple-system, sans-serif;
          box-shadow: 0 0 0 .5px var(--k-sep), 0 4px 14px rgba(0,0,0,.18); pointer-events: none; }
        .kelp-src-none { color: var(--k-text-orange); }
        """
}
