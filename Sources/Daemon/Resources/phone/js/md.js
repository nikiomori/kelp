// A small Markdown reader that builds DOM nodes and nothing else: the agent's text is untrusted, so there is no
// innerHTML here, HTML in the text stays text, and a link is a link only when it is http(s).
// ponytail: lists are flat (nesting shows as one level), images stay as typed, a table's cells can't hold a `|`.

const el = (tag, ...children) => {
  const node = document.createElement(tag);
  node.append(...children);
  return node;
};

const INLINE = /`([^`]+)`|\*\*(.+?)\*\*|\*([^*\s][^*]*?)\*|\[([^\]]+)\]\(([^)\s]+)\)/g;

function inline(text) {
  const out = [];
  let last = 0;
  for (const m of text.matchAll(INLINE)) {
    out.push(text.slice(last, m.index));
    last = m.index + m[0].length;
    if (m[1] != null) out.push(el('code', m[1]));
    else if (m[2] != null) out.push(el('strong', ...inline(m[2])));
    else if (m[3] != null) out.push(el('em', ...inline(m[3])));
    else out.push(link(m[4], m[5]) ?? m[0]);
  }
  out.push(text.slice(last));
  return out;
}

function link(text, href) {
  let url;
  try { url = new URL(href); } catch { return null; }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
  const a = el('a', ...inline(text));
  a.href = url.href;
  a.rel = 'noopener noreferrer';
  a.target = '_blank';
  return a;
}

const ITEM = /^\s*(?:[-*+]|(\d+)[.)])\s+(.*)$/;
// A table: a row of cells between pipes, then its rule (| --- | :---: |), then its rows.
const ROW = /^\s*\|.*\|\s*$/, RULE = /^\s*\|(\s*:?-{3,}:?\s*\|)+\s*$/;
const tableAt = (lines, i) => ROW.test(lines[i]) && RULE.test(lines[i + 1] ?? '');
const cells = (line, tag) => line.trim().slice(1, -1).split('|').map(cell => el(tag, ...inline(cell.trim())));

export function markdown(source) {
  const lines = source.replace(/\r/g, '').split('\n');
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    const fence = line.match(/^\s*(```|~~~)/);
    if (fence) {
      const code = [];
      for (i++; i < lines.length && !lines[i].trim().startsWith(fence[1]); i++) code.push(lines[i]);
      i++;
      out.push(el('pre', el('code', code.join('\n'))));
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.*)$/);
    if (heading) {
      // The screen's own title is the h1: the reply's headings start below it.
      out.push(el('h' + Math.min(heading[1].length + 1, 6), ...inline(heading[2])));
      i++;
      continue;
    }
    if (tableAt(lines, i)) {
      const head = el('tr', ...cells(line, 'th')), body = el('tbody');
      for (i += 2; i < lines.length && ROW.test(lines[i]); i++) body.append(el('tr', ...cells(lines[i], 'td')));
      const box = el('div', el('table', el('thead', head), body));
      box.className = 'table';   // it scrolls sideways on its own, as a code block does
      out.push(box);
      continue;
    }
    const item = line.match(ITEM);
    if (item) {
      const list = el(item[1] ? 'ol' : 'ul');
      for (let m; i < lines.length && (m = lines[i].match(ITEM)); i++) list.append(el('li', ...inline(m[2])));
      out.push(list);
      continue;
    }
    const para = [];
    for (; i < lines.length && lines[i].trim() && !/^\s*(```|~~~|#{1,6}\s)/.test(lines[i]) && !ITEM.test(lines[i]) && !tableAt(lines, i); i++) {
      para.push(lines[i].trim());
    }
    out.push(el('p', ...inline(para.join('\n'))));
  }
  return out;
}
