import Foundation

/// Typing over a text in Edit (a double click), on a board or a motion page's stage. A field of Kelp's own takes the
/// element's place in its font and colour (the board's frame runs no script, so typing in it is unheard). Words chosen
/// in it get a bar over them: a colour (the design system's first, then the page's own), B, I and U, each written as a
/// flat `<span style>`. ↩ keeps (⇧↩ breaks the line), Esc drops. Plain words go as `text`, styled ones as `html`, with
/// only spans, b, i, u, strong, em and br kept.
enum CanvasTypeOver {
    static let source = """
        (function () {
          const K = window.kelpCanvas, props = window.kelpProps; if (!K || !props) return;
          const inline = /^(SPAN|B|I|U|STRONG|EM|BR)$/;
          // An element of words alone, styled or not, which typing over can change.
          props.isText = e => !!e.textContent.trim() && [...e.querySelectorAll('*')].every(x => inline.test(x.tagName));
          const bar = K.el('div', 'kelp-ebar kelp-tbar');
          bar.style.display = 'none';
          document.body.append(bar);
          let field = null;
          const marker = '#010203';   // a colour no one picks, swapped for the token after the browser sets it
          function act(command, value) {
            document.execCommand('styleWithCSS', false, true);
            document.execCommand(command, false, value);
            if (value === marker) for (const s of field.querySelectorAll('[style*="rgb(1, 2, 3)"]'))
              s.style.color = field.dataset.colour;
          }
          function colours(e) {
            const items = props.menu('colour', e).filter(i => i.swatch);
            const row = K.el('span', 'kelp-tcolours');
            for (const it of items.slice(0, 10)) {
              const b = K.el('button', 'kelp-iswatch kelp-tswatch'); b.style.background = it.swatch; b.title = it.title;
              b.onmousedown = ev => { ev.preventDefault(); field.dataset.colour = it.value; act('foreColor', marker); };
              row.append(b);
            }
            return row;
          }
          function button(text, command, look) {
            const b = K.el('button', 'kelp-ebtn', text); b.style.cssText = look;
            b.onmousedown = ev => { ev.preventDefault(); act(command); };
            return b;
          }
          document.addEventListener('selectionchange', () => {
            const s = getSelection();
            const on = field && s.rangeCount && !s.isCollapsed && field.contains(s.anchorNode);
            bar.style.display = on ? 'flex' : 'none';
            if (!on) return;
            const r = s.getRangeAt(0).getBoundingClientRect();
            Object.assign(bar.style, { left: r.left + scrollX + 'px', top: r.top + scrollY - 38 + 'px' });
          });
          // What the field holds, as the page may keep it: words, and spans, b, i, u, strong, em, br with a style.
          function clean(node) {
            let out = '';
            for (const n of node.childNodes) {
              if (n.nodeType === 3) { out += n.textContent.replace(/&/g, '&amp;').replace(/</g, '&lt;'); continue; }
              if (n.nodeType !== 1) continue;
              const tag = n.tagName.toLowerCase();
              if (tag === 'div') { out += '<br>' + clean(n); continue; }   // a line the field broke
              if (!inline.test(n.tagName)) { out += clean(n); continue; }
              if (tag === 'br') { out += '<br>'; continue; }
              const style = n.getAttribute('style');
              const attr = style ? ' style="' + style.replace(/"/g, "'") + '"' : '';
              out += '<' + tag + attr + '>' + clean(n) + '</' + tag + '>';
            }
            return out;
          }
          window.kelpTypeOver = hit => {
            const e = hit.e, look = e.ownerDocument.defaultView.getComputedStyle(e), b = K.box(hit.f, e);
            const k = b.w / (e.getBoundingClientRect().width || 1);
            const oldText = e.textContent.trim(), oldHTML = e.innerHTML;
            field = K.el('div', 'kelp-type');
            field.contentEditable = 'true';
            field.innerHTML = oldHTML;
            Object.assign(field.style, {
              left: b.x + 'px', top: b.y + 'px', minWidth: Math.max(b.w, 60) + 'px',
              minHeight: Math.max(b.h, 20) + 'px',
              fontFamily: look.fontFamily, fontWeight: look.fontWeight, fontSize: parseFloat(look.fontSize) * k + 'px',
              lineHeight: (parseFloat(look.lineHeight) || parseFloat(look.fontSize) * 1.3) * k + 'px',
              color: look.color, textAlign: look.textAlign, letterSpacing: look.letterSpacing
            });
            bar.replaceChildren(colours(e), K.el('span', 'kelp-esep'), button('B', 'bold', 'font-weight: 700'),
              button('I', 'italic', 'font-style: italic'), button('U', 'underline', 'text-decoration: underline'));
            document.body.append(field);
            e.style.visibility = 'hidden';
            field.focus();
            getSelection().selectAllChildren(field);
            const done = keep => {
              if (!field || !field.isConnected) return;
              const f = field; field = null; f.remove();
              bar.style.display = 'none';
              e.style.visibility = '';
              if (!keep) return;
              const html = clean(f).trim(), text = f.textContent.trim();
              const board = hit.f.dataset.board, id = K.need(hit.f, e);
              if (!text || html === oldHTML.trim()) return;
              if (html === text.replace(/&/g, '&amp;').replace(/</g, '&lt;') && !/[<]/.test(oldHTML)) {
                e.textContent = text;
                K.post({ kind: 'text', board, id, old: oldText, text });
              } else {
                e.innerHTML = html;
                K.post({ kind: 'html', board, id, old: oldText, html, text });
              }
              window.kelpOutline?.();
            };
            field.addEventListener('keydown', ev => {
              ev.stopPropagation();
              if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); done(true); }
              if (ev.key === 'Escape') { ev.preventDefault(); done(false); }
            });
            field.addEventListener('blur', () => setTimeout(() => {
              if (document.activeElement !== field) done(true);
            }));
          };
        })();
        """

    /// The bar over words chosen, and its swatches.
    static let style = """
        .kelp-tbar { z-index: 30; }
        .kelp-tcolours { display: flex; gap: 3px; padding: 0 4px; align-items: center; }
        .kelp-tswatch { border: 0; padding: 0; width: 14px; height: 14px; margin: 0; cursor: default; }
        """
}
