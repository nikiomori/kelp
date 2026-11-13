// Liquid Glass that answers the finger: the pane under it leans toward it a little and springs back, and its light
// sits where the finger is. The ideas of liquid-glass-react (elasticity, a highlight that follows, a tunable fringe),
// done on the page's own lens, which also works in Safari, where that library's bending doesn't show.

const root = document.documentElement;
const still = matchMedia('(prefers-reduced-motion: reduce)');
/** What answers a press: the floating controls, and the rows of the agents' cards. */
const PANES = '.glass, #quick button, .group ul > li';

/** The lens's strength, colour fringe and softness, read from app.css (--lens-bend, --lens-fringe, --lens-soft): the
    one place to tune them. The filter's three displacements bend red, green and blue a little more each. */
export function tuneLens() {
  const css = getComputedStyle(root);
  const read = (name, fallback) => parseFloat(css.getPropertyValue(name)) || fallback;
  const bend = read('--lens-bend', 32), fringe = read('--lens-fringe', 5), soft = read('--lens-soft', 2.5);
  document.querySelectorAll('#lens feDisplacementMap').forEach((map, i) => map.setAttribute('scale', `${bend + fringe * i}`));
  document.querySelector('#lens feGaussianBlur[in="SourceGraphic"]')?.setAttribute('stdDeviation', `${soft}`);
}

/** Follows every press on the page, wherever it lands. */
export function follow() {
  let held = null;
  const light = (pane, e) => {
    const box = pane.getBoundingClientRect();
    if (!box.width || !box.height) return;
    const x = Math.min(Math.max((e.clientX - box.left) / box.width, 0), 1);
    const y = Math.min(Math.max((e.clientY - box.top) / box.height, 0), 1);
    pane.style.setProperty('--hx', `${(x * 100).toFixed(1)}%`);
    pane.style.setProperty('--hy', `${(y * 100).toFixed(1)}%`);
    if (still.matches) return;
    // At most a few points toward the finger, less for a wide pane: liquid, not loose.
    const reach = Math.min(4, 120 / Math.max(box.width, box.height) * 4);
    pane.style.setProperty('--lean-x', `${((x - 0.5) * reach).toFixed(2)}px`);
    pane.style.setProperty('--lean-y', `${((y - 0.5) * reach).toFixed(2)}px`);
  };
  const letGo = () => {
    if (!held) return;
    held.classList.remove('held');
    held.style.removeProperty('--lean-x');
    held.style.removeProperty('--lean-y');
    held = null;
  };
  addEventListener('pointerdown', e => {
    const pane = e.target.closest?.(PANES);
    if (!pane || pane.matches(':disabled')) return;
    letGo();
    held = pane;
    light(pane, e);
    pane.classList.add('held');
  }, { passive: true });
  addEventListener('pointermove', e => { if (held) light(held, e); }, { passive: true });
  for (const end of ['pointerup', 'pointercancel', 'blur']) addEventListener(end, letGo, { passive: true });
  // A scroll that starts on a row isn't a press of it.
  addEventListener('scroll', letGo, { passive: true, capture: true });
}
