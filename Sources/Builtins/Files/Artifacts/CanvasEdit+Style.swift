import Foundation

extension CanvasEdit {
    /// The CSS for what Kelp puts on the canvas: pins, the rows in the column, Pick, tweaks, and the strip shown while
    /// presenting.
    static let style = """
        .kelp-tools { top: 10px; left: 50%; transform: translateX(-50%); }
        .kelp-layer { position: absolute; inset: 0 auto auto 0; pointer-events: none; z-index: 10; }
        .kelp-sheet { position: fixed; inset: 0; display: none; cursor: crosshair; z-index: 15; }
        .kelp-with-col .kelp-sheet { right: 260px; }
        .kelp-outline { position: absolute; display: none; border: 1.5px solid var(--k-orange); border-radius: 3px; }
        .kelp-outline.kelp-outline-edit { border: 1px solid var(--k-accent); opacity: .6; }
        .kelp-pin { position: absolute; width: 18px; height: 18px; border-radius: 50%; background: var(--k-orange);
          color: #1d1d1f; font: 600 10px/18px -apple-system, sans-serif; text-align: center;
          box-shadow: 0 0 0 2px var(--k-card); }
        .kelp-num { width: 16px; height: 16px; border-radius: 50%; background: var(--k-orange); color: #1d1d1f;
          font: 600 10px/16px -apple-system, sans-serif; text-align: center; }
        .kelp-what { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .kelp-indent { padding-left: 36px; padding-top: 0; }
        .kelp-end { justify-content: flex-end; padding-top: 10px; }
        .kelp-field { flex: 1; min-width: 0; height: 22px; box-sizing: border-box; padding: 0 7px; border: 0;
          border-radius: 6px; background: var(--k-card); color: var(--k-label); font: inherit;
          box-shadow: inset 0 0 0 1px var(--k-sep); }
        .kelp-issue { align-items: flex-start; }
        .kelp-mark-warn { width: 14px; height: 14px; border-radius: 4px; color: var(--k-text-orange);
          font: 700 10px/14px -apple-system, sans-serif; text-align: center;
          box-shadow: 0 0 0 1px var(--k-orange); margin-top: 1px; }
        .kelp-pick, .kelp-tweaks { margin-left: 10px; border: 0; border-radius: 999px; padding: 1px 8px; font: inherit;
          font-weight: 500; background: var(--k-rest); color: inherit; opacity: 0; }
        .row h2:hover .kelp-pick, .kelp-tweaks { opacity: 1; }
        .kelp-panel { display: none; gap: 14px; flex-wrap: wrap; padding: 6px 0 4px; font-size: 11px; }
        .kelp-panel.open { display: flex; }
        .kelp-panel label { display: flex; gap: 6px; align-items: center; }
        .kelp-panel input[type=color] { width: 22px; height: 18px; border: 0; padding: 0; background: none; }
        .kelp-tseg { display: inline-flex; border-radius: 999px; background: var(--k-rest); padding: 1px; }
        .kelp-tseg button { border: 0; background: none; color: inherit; font: inherit; padding: 1px 7px;
          border-radius: 999px; }
        .kelp-tseg button.on { background: var(--k-card); box-shadow: 0 .5px 2px rgba(0,0,0,.12); }
        .kelp-strip { position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%); z-index: 40; display: none;
          align-items: center; gap: 8px; height: 34px; padding: 0 10px; border-radius: 999px; opacity: 0;
          background: rgba(40,40,40,.85); color: rgba(255,255,255,.85); font: 12px -apple-system, sans-serif;
          transition: opacity .17s ease-in; }
        .kelp-present .kelp-strip { display: flex; }
        .kelp-strip.on { opacity: 1; transition: opacity .12s ease-out; }
        .kelp-strip .kelp-ib { color: inherit; }
        .kelp-strip .kelp-sep { background: rgba(255,255,255,.2); }
        .kelp-where { font-variant-numeric: tabular-nums; }
        .kelp-esc { color: rgba(255,255,255,.6); }
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
        .kelp-label { position: absolute; padding: 1px 5px; border-radius: 3px; background: var(--k-orange);
          color: #1d1d1f; font: 600 11px/16px -apple-system, sans-serif; white-space: nowrap; pointer-events: none; }
        .kelp-label.kelp-n-sent { background: var(--k-quiet); }
        .kelp-label-field { position: absolute; z-index: 13; width: 140px; height: 20px; padding: 0 5px; border: 0;
          border-radius: 3px; background: var(--k-orange); color: #1d1d1f; font: 600 11px -apple-system, sans-serif;
          outline: none; }
        """
}
