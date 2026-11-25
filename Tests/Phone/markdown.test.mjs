import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';
import { markdown } from '../../Sources/Daemon/Resources/phone/js/md.js';

// Only the DOM operations used by the renderer. Bound allocations so a stalled parser fails promptly.
class Element {
  childNodes = [];
  constructor(localName) { this.localName = localName; }
  append(...children) { this.childNodes.push(...children); }
  get children() { return this.childNodes.filter(node => node instanceof Element); }
  get textContent() { return this.childNodes.map(node => node.textContent ?? node).join(''); }
}
beforeEach(() => {
  let count = 0;
  globalThis.document = {
    createDocumentFragment: () => new Element(),
    createElement(tag) {
      assert.ok(++count < 200, 'parser did not advance');
      return new Element(tag);
    },
  };
});
const tags = nodes => nodes.map(node => node.localName);

test('paragraphs advance past indented headings and heading-like prose', () => {
  const nodes = markdown('intro\r\n  ## Heading\r\nbody\ncontinued\n\t###### Last\n####### ordinary\n#nospace');
  assert.deepEqual(tags(nodes), ['p', 'h3', 'p', 'h6', 'p']);
  assert.deepEqual(nodes.map(n => n.textContent), ['intro', 'Heading', 'body\ncontinued', 'Last', '####### ordinary\n#nospace']);
});

test('local references retain names and locations as text, including angle-wrapped paths', () => {
  const [p] = markdown('[`md.js`](/repo/md.js:12) [a b](</My Files/a b#L8>) [source](src/app.js:4:2) [file](file:///tmp/file) [README](./README)');
  assert.equal(p.textContent, 'md.js:12 a b#L8 source (app.js:4:2) file README');
  assert.deepEqual(tags(p.children), ['code', 'code']);
});

test('bare filenames, encoded spaces and labels that already have the line stay readable', () => {
  const [p] = markdown('[main.js](main.js:19) [My File.md:2](file:///tmp/My%20File.md#L2) [server](localhost:3000)');
  assert.equal(p.textContent, 'main.js:19 My File.md:2 server (localhost:3000)');
  assert.deepEqual(p.children, []);
});

test('only HTTP and HTTPS destinations produce anchors', () => {
  const [p] = markdown('[HTTP](http://example.test/x) [**docs**](https://example.test/a_(b)) [go](custom://x) [mail](mailto:a@b) [run](javascript:void(0)) <script>');
  assert.equal(p.textContent, 'HTTP docs go (custom://x) mail (mailto:a@b) run (javascript:void(0)) <script>');
  assert.deepEqual(tags(p.children), ['a', 'a']);
  assert.deepEqual(p.children.map(a => a.href), ['http://example.test/x', 'https://example.test/a_(b)']);
  for (const a of p.children) {
    assert.equal(a.target, '_blank');
    assert.equal(a.rel, 'noopener noreferrer');
  }
  assert.deepEqual(tags(p.children[1].children), ['strong']);
});

test('mixed lists keep their nesting, continuations, blank lines and explicit numbers', () => {
  const nodes = markdown([
    '3) parent', '   wrapped', '   - nested', '     more', '     2. deep',
    '   6. nested ordered', '   parent again', '', '   another paragraph',
    '7) sibling', '- bullet', 'lazy continuation', '', 'outside',
  ].join('\n'));
  assert.deepEqual(tags(nodes), ['ol', 'ul', 'p']);
  const [ordered, bullets, outside] = nodes;
  assert.equal(ordered.start, 3);
  assert.equal(ordered.children.length, 2);
  const [parent, sibling] = ordered.children;
  assert.equal(sibling.value, 7);
  assert.equal(sibling.textContent, 'sibling');
  assert.deepEqual(tags(parent.children), ['p', 'ul', 'ol', 'p', 'p']);
  const [first, nested, nestedOrdered, continued, second] = parent.children;
  assert.equal(first.textContent, 'parent\nwrapped');
  const [nestedText, deep] = nested.children[0].children;
  assert.equal(nestedText.textContent, 'nested\nmore');
  assert.equal(deep.start, 2);
  assert.equal(deep.textContent, 'deep');
  assert.equal(nestedOrdered.start, 6);
  assert.equal(nestedOrdered.textContent, 'nested ordered');
  assert.equal(continued.textContent, 'parent again');
  assert.equal(second.textContent, 'another paragraph');
  assert.equal(bullets.textContent, 'bullet\nlazy continuation');
  assert.equal(outside.textContent, 'outside');
});

test('repeated one markers number automatically across blank lines', () => {
  const [list] = markdown('1. one\n\n1. two\n1. three');
  assert.equal(list.localName, 'ol');
  assert.deepEqual(list.children.map(li => li.value), [undefined, undefined, undefined]);
});

test('a code fence inside a list keeps literal markers and is followed by normal blocks', () => {
  const nodes = markdown('- item\n  ```\n  # literal\n  - literal\n  ```\n\n| head |\n| --- |\n| cell |\n# End');
  assert.deepEqual(tags(nodes), ['ul', 'div', 'h2']);
  const [paragraph, pre] = nodes[0].children[0].children;
  assert.equal(paragraph.textContent, 'item');
  assert.equal(pre.localName, 'pre');
  assert.equal(pre.textContent, '# literal\n- literal');
  assert.equal(nodes[1].children[0].textContent, 'headcell');
});

test('left-margin lines stay in the fenced code of the first step', () => {
  const nodes = markdown([
    '1. Write the file', '   ```text', '   Sample text', '- literal', '     indented',
    '', 'left margin', '2. literal', '   ```', '2. Read it', '', 'Outside the list',
  ].join('\n'));
  assert.deepEqual(tags(nodes), ['ol', 'p']);
  const [list, outside] = nodes;
  assert.deepEqual(tags(list.children), ['li', 'li']);
  const [first, second] = list.children;
  assert.deepEqual(tags(first.children), ['p', 'pre']);
  const [paragraph, pre] = first.children;
  assert.equal(paragraph.textContent, 'Write the file');
  assert.deepEqual(tags(pre.children), ['code']);
  assert.equal(pre.textContent, 'Sample text\n- literal\n  indented\n\nleft margin\n2. literal');
  assert.equal(second.textContent, 'Read it');
  assert.equal(outside.textContent, 'Outside the list');
});

test('an unfinished list fence ends when the next sibling starts', () => {
  const [list] = markdown('- ```js\n  code\n    indented\n- next');
  const [first, next] = list.children;
  assert.equal(first.children[0].textContent, 'code\n  indented');
  assert.equal(next.textContent, 'next');
});

test('an unfinished fence leaves the next step its own fenced block', () => {
  for (const [second, expected] of [
    ['2. ```sh', ['second']],
    ['2. Run it\n   ```sh', ['Run it', 'second']],
    ['2. Run it\n   ```', ['Run it', 'second']],
  ]) {
    const nodes = markdown(['1. ```js', '   first', second, '   second', '   ```'].join('\n'));
    assert.deepEqual(tags(nodes), ['ol']);
    const [list] = nodes;
    assert.deepEqual(tags(list.children), ['li', 'li']);
    const [first, next] = list.children;
    assert.deepEqual(tags(first.children), ['pre']);
    assert.equal(first.textContent, 'first');
    assert.deepEqual(next.children.map(node => node.textContent), expected);
    assert.equal(next.children.at(-1).localName, 'pre');
  }
});

test('a fence in a list keeps code at the margin and ends at its closing line', () => {
  const nodes = markdown('1. Run:\n   ```bash\nmake\n   ```\n2. Next\n\nAfter');
  assert.deepEqual(tags(nodes), ['ol', 'p']);
  const [run, next] = nodes[0].children;
  assert.equal(run.children[1].textContent, 'make');
  assert.equal(next.textContent, 'Next');
  assert.equal(nodes[1].textContent, 'After');
});
