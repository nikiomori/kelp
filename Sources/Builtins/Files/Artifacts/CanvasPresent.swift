import Foundation

/// Present (`kelpPresent(true)`) on a canvas: the boards one at a time, each as large as the pane, with a strip at the
/// foot that says where you are. ← → step through them and Esc ends (`present` to `kelpSync`).
enum CanvasPresent {
    static func source(labels: CanvasEdit.Labels) -> String {
        """
        (function () {
          const K = window.kelpCanvas; if (!K) return;
          const { el, frames, light, post } = K, L = \(MarkdownTab.js(labels));
        \(body)
        })();
        """
    }

    private static let body = """
          const slides = [...new Set(frames.map(f => f.dataset.board))].map(light);
          let at = -1, quiet = null;
          // A strip at the foot while presenting: where you are, ‹ ›, and how to end; it fades when the pointer rests.
          const strip = el('div', 'kelp-strip');
          const back = el('button', 'kelp-ib'), next = el('button', 'kelp-ib');
          back.innerHTML = \(PageSymbols.span("chevron.left"));
          next.innerHTML = \(PageSymbols.span("chevron.right"));
          const where = el('span', 'kelp-where');
          back.onclick = () => { at = Math.max(at - 1, 0); present(); moved(); };
          next.onclick = () => { at = Math.min(at + 1, slides.length - 1); present(); moved(); };
          // A deck's boards for Present with Notes (`Presenter`), which follows where this one is.
          const moved = () => post({ kind: 'slideAt', at });
          window.kelpSlides = slides;
          Object.defineProperty(window, 'kelpAt', { get: () => Math.max(at, 0), configurable: true });
          window.kelpGo = i => { if (at < 0) return; at = Math.max(0, Math.min(slides.length - 1, i)); present(); };
          strip.append(back, where, next, el('span', 'kelp-sep'), el('span', 'kelp-esc', L.escEnds));
          document.body.append(strip);
          const wake = () => {
            strip.classList.add('on'); clearTimeout(quiet);
            quiet = setTimeout(() => strip.classList.remove('on'), 2000);
          };
          addEventListener('mousemove', () => { if (at >= 0) wake(); });
          function present() {
            slides.forEach((f, i) => f.closest('.frame').classList.toggle('kelp-current', i === at));
            const f = slides[at];
            back.disabled = at <= 0; next.disabled = at >= slides.length - 1;
            const fits = f && Math.min(innerWidth / f.offsetWidth, (innerHeight - 64) / f.offsetHeight);
            if (f) f.style.transform = 'scale(' + fits + ')';
            if (f) {
              const name = K.nameOf(f);
              where.textContent = name + ' · ' + (at + 1) + ' ' + L.of + ' ' + slides.length;
              wake();
            }
          }
          let was = null;   // the mode before presenting, back after it
          window.kelpPresent = on => {
            if (on && K.mode() !== 'present') { was = K.mode(); K.setMode('present'); }
            if (!on && K.mode() === 'present') K.setMode(was);
            at = on ? 0 : -1;
            document.body.classList.toggle('kelp-present', on);
            if (!on) for (const f of slides) f.style.transform = '';
            present();
          };
          // While presenting, a board's link shows the board it goes to (`CanvasLinks`); false when not presenting.
          window.kelpGoTo = board => { const i = slides.findIndex(f => f.dataset.board === board);
            if (at < 0 || i < 0) return false; at = i; present(); return true; };
          addEventListener('keydown', e => {
            if (at < 0) return;
            if (['ArrowRight', 'ArrowDown', 'PageDown', ' '].includes(e.key)) at = Math.min(at + 1, slides.length - 1);
            else if (['ArrowLeft', 'ArrowUp', 'PageUp'].includes(e.key)) at = Math.max(at - 1, 0);
            else if (e.key === 'Escape') { kelpPresent(false); post({ kind: 'present' }); return; }
            else return;
            e.preventDefault(); present(); moved();
          });
          addEventListener('resize', () => { if (at >= 0) present(); });
        """
}
