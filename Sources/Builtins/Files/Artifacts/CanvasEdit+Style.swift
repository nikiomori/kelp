import Foundation

extension CanvasEdit {
    /// The CSS for what Kelp puts on the canvas: pins, the rows in the column, Pick, tweaks, and the strip shown while
    /// presenting.
    static let style = """
        .kelp-tools { bottom: 14px; left: 50%; transform: translateX(-50%); }
        .kelp-with-col .kelp-tools { left: calc((100% - 260px) / 2); }
        .kelp-layer { position: absolute; inset: 0 auto auto 0; pointer-events: none; z-index: 10; }
        .kelp-sheet { position: fixed; inset: 0; display: none; cursor: crosshair; z-index: 15; }
        .kelp-with-col .kelp-sheet { right: 260px; }
        .kelp-outline { position: absolute; display: none; border: 1.5px solid var(--k-orange);
          border-radius: var(--k-radius-xs); }
        .kelp-outline.kelp-outline-edit { border: 1px solid var(--k-accent); opacity: .6; }
        .kelp-num { width: 16px; height: 16px; border-radius: 50%; background: var(--k-orange);
          color: var(--k-on-orange); font: 600 var(--k-text-micro)/16px -apple-system, sans-serif; text-align: center; }
        .kelp-what { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .kelp-indent { padding-left: 36px; padding-top: 0; }
        .kelp-end { justify-content: flex-end; padding-top: 10px; }
        .kelp-field { flex: 1; min-width: 0; height: 22px; box-sizing: border-box; padding: 0 7px; border: 0;
          border-radius: var(--k-radius-sm); background: var(--k-card); color: var(--k-label); font: inherit;
          box-shadow: inset 0 0 0 1px var(--k-sep); }
        .kelp-issue { align-items: flex-start; }
        .kelp-mark-warn { width: 14px; height: 14px; border-radius: var(--k-radius-xs); color: var(--k-text-orange);
          display: flex; align-items: center; justify-content: center;
          box-shadow: 0 0 0 1px var(--k-orange); margin-top: 1px; }
        .kelp-pick, .kelp-tweaks { margin-left: 10px; border: 0; border-radius: var(--k-radius-capsule);
          padding: 1px 8px; font: inherit;
          font-weight: 500; background: var(--k-rest); color: inherit; opacity: 0; }
        .row h2:hover .kelp-pick, .kelp-tweaks { opacity: 1; }
        .kelp-panel { display: none; gap: 14px; flex-wrap: wrap; padding: 6px 0 4px; font-size: var(--k-text-caption); }
        .kelp-panel.open { display: flex; }
        .kelp-panel label { display: flex; gap: 6px; align-items: center; }
        .kelp-panel input[type=color] { width: 22px; height: 18px; border: 0; padding: 0; background: none; }
        .kelp-strip { position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%); z-index: 40; display: none;
          align-items: center; gap: 8px; height: 34px; padding: 0 10px; border-radius: var(--k-radius-capsule);
          opacity: 0; background: var(--k-hud); color: var(--k-on-hud);
          font: var(--k-text-row) -apple-system, sans-serif;
          transition: opacity var(--k-slow) ease-in; }
        .kelp-present .kelp-strip { display: flex; }
        .kelp-present .kelp-sheet { z-index: 35; right: 0; cursor: default; }   /* over the board shown: its links */
        .kelp-strip.on { opacity: 1; transition: opacity var(--k-fast) ease-out; }
        .kelp-strip .kelp-ib { color: inherit; }
        .kelp-strip .kelp-ib:disabled { color: var(--k-hud-sep); background: none; }
        .kelp-strip .kelp-sep { background: var(--k-hud-sep); }
        .kelp-where { font-variant-numeric: tabular-nums; }
        .kelp-esc { color: var(--k-on-hud-sec); }
        .kelp-present { overflow: hidden; }
        .kelp-present #kelp-canvas { transform: none !important; }
        .kelp-present .row h2, .kelp-present .name, .kelp-present .kelp-layer,
          .kelp-present .kelp-panel, .kelp-present .frame { display: none !important; }
        .kelp-present .frame.kelp-current { display: flex !important; position: fixed; inset: 0; z-index: 30;
          align-items: center; justify-content: center; background: #000; padding-bottom: 64px;
          box-sizing: border-box; }
        .kelp-present .kelp-current iframe { flex: none; box-shadow: none; border-radius: 0; }
        @media print {
          #kelp-canvas { transform: none !important; }
          .name, .kelp-pick, .kelp-tweaks, .kelp-layer, .kelp-panel, .kelp-col, .kelp-float, .kelp-issues,
            .frame:has(iframe[data-theme="dark"]) { display: none !important; }
          .frame { break-after: page; }
        }
        .kelp-label { position: absolute; padding: 1px 5px; border-radius: var(--k-radius-xs);
          background: var(--k-orange); color: var(--k-on-orange);
          font: 600 var(--k-text-caption)/16px -apple-system, sans-serif; white-space: nowrap;
          pointer-events: none; }
        .kelp-label.kelp-n-sent { background: var(--k-quiet); }
        .kelp-label-field { position: absolute; z-index: 13; width: 140px; height: 20px; padding: 0 5px; border: 0;
          border-radius: var(--k-radius-xs); background: var(--k-orange); color: var(--k-on-orange);
          font: 600 var(--k-text-caption) -apple-system, sans-serif;
          outline: none; }
        """
}
