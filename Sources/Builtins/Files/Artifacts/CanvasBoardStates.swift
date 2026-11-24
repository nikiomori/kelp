import Foundation

/// A board's states (Cursor's visual editor, Rive): an element with `data-states="default,hover,empty,error"` gets a
/// switcher in its board's name row, and the state chosen is written on it as `data-state` (the board styles each with
/// `[data-state=error] …`), on both themes' frames. A mark made on a board in a state other than its first remembers it
/// (`inState`), shows it in the column, sends it to the agent, and puts the board back in it when it's shown again.
enum CanvasBoardStates {
    static let source = """
        (function () {
          const K = window.kelpCanvas, M = window.kelpMarks; if (!K) return;
          const now = {};   // the state shown, by board
          const holder = f => f.contentDocument?.querySelector('[data-states]');
          const statesOf = f => (holder(f)?.dataset.states || '').split(',').map(s => s.trim()).filter(Boolean);
          function show(board, state) {
            now[board] = state;
            for (const f of K.frames.filter(f => f.dataset.board === board)) {
              holder(f)?.setAttribute('data-state', state);
            }
            for (const seg of document.querySelectorAll('.kelp-states[data-board="' + CSS.escape(board) + '"] button'))
              seg.classList.toggle('on', seg.textContent === state);
            K.hooks?.draw && window.kelpMarks?.draw();
          }
          function setUp(f) {
            const states = statesOf(f), name = f.closest('.frame')?.querySelector('.name');
            if (!states.length || !name || f.dataset.theme === 'dark') return;
            const board = f.dataset.board;
            name.querySelector('.kelp-states')?.remove();
            const seg = K.el('span', 'kelp-seg kelp-states');
            seg.dataset.board = board;
            for (const s of states) {
              const b = K.el('button', '', s);
              b.onclick = e => { e.stopPropagation(); show(board, s); };
              seg.append(b);
            }
            name.append(seg);
            show(board, now[board] || states[0]);
          }
          for (const f of K.frames) {
            f.addEventListener('load', () => setUp(f));
            if (f.contentDocument?.readyState === 'complete') setUp(f);
          }
          if (!M) return;
          // A mark remembers a state that isn't the board's first, and shows the board in it again.
          const add = M.add.bind(M);
          M.add = m => {
            const f = m.board && K.light(m.board), first = f ? statesOf(f)[0] : null;
            if (f && now[m.board] && now[m.board] !== first) m.inState = now[m.board];
            add(m);
          };
          const hooks = K.hooks, what = hooks.what, focus = hooks.focus;
          hooks.what = m => what(m) + (m.inState ? ' · ' + m.inState : '');
          hooks.focus = m => { if (m.inState && m.board) show(m.board, m.inState); focus(m); };
        })();
        """

    static let style = """
        .kelp-states { margin-left: 8px; vertical-align: middle; font-size: calc(10px / var(--z, 1)); }
        """
}
