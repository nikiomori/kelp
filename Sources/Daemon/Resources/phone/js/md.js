// A small Markdown reader that builds DOM nodes and nothing else: the agent's text is untrusted, so there is no
// innerHTML here, HTML in the text stays text, and a link is a link only when it is http(s).
// A table's cells can't hold a `|`.

const el = (tag, ...children) => {
  const node = document.createElement(tag);
  node.append(...children);
  return node;
};

const INLINE = /`([^`]+)`|\*\*(.+?)\*\*|\*([^*\s][^*]*?)\*|\[([^\]\n]+)\]\((?:<([^<>\n]+)>|((?:[^()\s]|\([^()\s]*\))+))\)/g;

function inline(text) {
  const out = [];
  let last = 0;
  for (const m of text.matchAll(INLINE)) {
    out.push(text.slice(last, m.index));
    last = m.index + m[0].length;
    if (m[1] != null) out.push(el('code', m[1]));
    else if (m[2] != null) out.push(el('strong', ...inline(m[2])));
    else if (m[3] != null) out.push(el('em', ...inline(m[3])));
    else out.push(...link(m[4], m[5] ?? m[6]));
  }
  out.push(text.slice(last));
  return out;
}

function link(text, href) {
  const label = inline(text);
  let url;
  try { url = new URL(href); } catch { /* Relative paths have no URL on the phone. */ }
  if (url?.protocol === 'http:' || url?.protocol === 'https:') {
    const a = el('a', ...label);
    a.href = url.href;
    a.rel = 'noopener noreferrer';
    a.target = '_blank';
    return [a];
  }
  if (!url || url.protocol === 'file:' || /^[A-Za-z]:[\\/]|^[\w.-]+:\d+(?::\d+)?$/.test(href)) {
    let file = href.split(/[\\/]/).pop();
    try { file = decodeURIComponent(file); } catch { /* Keep a literal percent sign. */ }
    const [, name, location] = file.match(/^(.*?)(:\d+(?::\d+)?|#L\d+(?:-L?\d+)?)?$/s);
    const plain = text.replace(/`/g, '');
    if (name && !plain.includes(name)) label.push(' (', el('code', file), ')');
    else if (location && !plain.replace(/#L(?=\d)/g, ':').endsWith(location.replace('#L', ':'))) label.push(location);
  }
  return label;
}

const ITEM = /^(\s*)(?:[-*+]|(\d{1,9})[.)])\s+(.*)$/;
const FENCE = /^\s*(```|~~~)/, HEADING = /^\s*(#{1,6})\s+(.*)$/;
// A table: a row of cells between pipes, then its rule (| --- | :---: |), then its rows.
const ROW = /^\s*\|.*\|\s*$/, RULE = /^\s*\|(\s*:?-{3,}:?\s*\|)+\s*$/;
const tableAt = (lines, i) => ROW.test(lines[i]) && RULE.test(lines[i + 1] ?? '');
const cells = (line, tag) => line.trim().slice(1, -1).split('|').map(cell => el(tag, ...inline(cell.trim())));

export function markdown(source) {
  const lines = source.replace(/\r/g, '').split('\n');
  const root = document.createDocumentFragment();
  const lists = [];
  let i = 0;
  while (i < lines.length) {
    let line = lines[i];
    if (!line.trim()) { i++; continue; }
    const item = line.match(ITEM);
    const indent = line.search(/\S/);
    while (lists.length && (indent < lists.at(-1).indent || (!item && indent === lists.at(-1).indent))) lists.pop();
    if (item) {
      const tag = item[2] ? 'ol' : 'ul';
      let level = lists.at(-1);
      if (level?.indent === indent && level.list.localName !== tag) {
        lists.pop();
        level = lists.at(-1);
      }
      const number = Number(item[2]);
      if (level?.indent !== indent) {
        const list = el(tag);
        if (tag === 'ol' && number !== 1) list.start = number;
        (level?.li ?? root).append(list);
        level = { indent, list };
        lists.push(level);
      }
      const li = el('li');
      // Repeated "1." markers use the browser's numbering.
      if (item[2] && level.li && !(number === 1 && level.previous === 1)) li.value = number;
      level.list.append(li);
      level.li = li;
      level.previous = number;
      line = item[3];
    }
    const parent = lists.at(-1)?.li ?? root;
    const fence = line.match(FENCE);
    if (fence) {
      const code = [];
      const margin = item ? item[0].length - line.length : indent;
      for (i++; i < lines.length; i++) {
        const next = lines[i], spaces = next.length - next.trimStart().length;
        if (lists.length && spaces < next.length && spaces <= lists.at(-1).indent) break;
        if (next.trim().startsWith(fence[1])) { i++; break; }
        code.push(lists.length ? next.slice(Math.min(margin, spaces)) : next);
      }
      parent.append(el('pre', el('code', code.join('\n'))));
      continue;
    }
    const heading = line.match(HEADING);
    if (heading) {
      // The screen's own title is the h1: the reply's headings start below it.
      parent.append(el('h' + Math.min(heading[1].length + 1, 6), ...inline(heading[2])));
      i++;
      continue;
    }
    if (tableAt(lines, i)) {
      const head = el('tr', ...cells(line, 'th')), body = el('tbody');
      for (i += 2; i < lines.length && ROW.test(lines[i]); i++) body.append(el('tr', ...cells(lines[i], 'td')));
      const box = el('div', el('table', el('thead', head), body));
      box.className = 'table';   // it scrolls sideways on its own, as a code block does
      parent.append(box);
      continue;
    }
    const para = [line.trim()];
    for (i++; i < lines.length; i++) {
      const next = lines[i];
      if (!next.trim() || FENCE.test(next) || HEADING.test(next) || ITEM.test(next) || tableAt(lines, i)) break;
      if (lists.length > 1 && next.search(/\S/) <= lists.at(-1).indent) break;
      para.push(next.trim());
    }
    parent.append(el('p', ...inline(para.join('\n'))));
  }
  return [...root.childNodes];
}
