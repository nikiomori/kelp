import Foundation

extension MarkColumn {
    static let style = """
        .kelp-col-band { display: none; align-items: center; gap: 6px; padding: 6px 12px; font-size: 11px;
          background: color-mix(in srgb, var(--k-orange) 12%, transparent); }
        .kelp-busy-dot { color: var(--k-orange); }
        .kelp-grip { color: var(--k-quiet); cursor: grab; font-size: 10px; letter-spacing: -2px; }
        .kelp-check { flex: none; width: 14px; height: 14px; padding: 0; border: 0; border-radius: 50%;
          background: none; box-shadow: inset 0 0 0 1.5px var(--k-quiet); }
        .kelp-check.on { background: var(--k-accent); box-shadow: inset 0 0 0 1.5px var(--k-accent); }
        .kelp-edit-swatch { display: inline-block; width: 10px; height: 10px; margin-right: 4px; border-radius: 3px;
          vertical-align: -1px; box-shadow: inset 0 0 0 1px var(--k-sep); }
        .kelp-marks { position: absolute; inset: 0 auto auto 0; pointer-events: none; z-index: 11; }
        .kelp-pin { position: absolute; width: 18px; height: 18px; border-radius: 50%; background: var(--k-orange);
          color: #1d1d1f; font: 600 10px/18px -apple-system, sans-serif; text-align: center;
          box-shadow: 0 0 0 2px var(--k-card); }
        .kelp-pin.kelp-n-sent { background: var(--k-quiet); color: #fff; }
        .kelp-num.kelp-n-sent { background: var(--k-quiet); color: #fff; }
        .kelp-num.kelp-n-done { background: var(--k-rest); color: var(--k-sec); }
        .kelp-area { position: absolute; border: 1.5px dashed var(--k-orange); border-radius: 4px;
          box-sizing: border-box; }
        .kelp-area.kelp-n-sent { border-color: var(--k-quiet); }
        .kelp-stroke { position: absolute; overflow: visible; }
        .kelp-stroke path { fill: none; stroke: var(--k-orange); stroke-width: 2.5; stroke-linecap: round;
          stroke-linejoin: round; }
        .kelp-stroke.kelp-n-sent path { stroke: var(--k-quiet); }
        .kelp-composer { position: absolute; z-index: 25; width: 280px; padding: 8px; box-sizing: border-box;
          border-radius: 10px; background: var(--k-float); color: var(--k-label);
          box-shadow: 0 0 0 .5px var(--k-sep), 0 6px 20px rgba(0,0,0,.25); font: 12px -apple-system, sans-serif; }
        .kelp-compose-field { display: block; width: 100%; box-sizing: border-box; resize: none; border: 0;
          border-radius: 6px; padding: 6px 8px; background: var(--k-card); color: var(--k-label); font: inherit;
          box-shadow: inset 0 0 0 1px var(--k-sep); outline: none; }
        .kelp-compose-field:focus { box-shadow: inset 0 0 0 1px var(--k-accent); }
        .kelp-composer .kelp-hint { margin-top: 6px; }
        .kelp-current-box { position: absolute; border: 1.5px solid var(--k-orange); border-radius: 4px; }
        .kelp-mark { margin: 0 8px; padding: 2px 4px 8px; border-radius: 6px; }
        .kelp-mark .kelp-row { padding: 4px 0; }
        .kelp-mark.kelp-on { background: var(--k-sel); }
        .kelp-mark-body { padding-left: 24px; display: flex; flex-direction: column; gap: 5px; }
        .kelp-past { color: var(--k-sec); font-size: 11px; }
        .kelp-faded { color: var(--k-sec); }
        .kelp-reply { border-radius: 6px; background: var(--k-rest); padding: 6px 8px; }
        .kelp-outcome { color: var(--k-sec); font-size: 11px; }
        .kelp-outcome.kelp-warn { color: var(--k-text-orange); }
        .kelp-spin { width: 10px; height: 10px; border-radius: 50%; border: 1.5px solid var(--k-sep);
          border-top-color: var(--k-sec); animation: kelp-spin 1s linear infinite; flex: none; margin-right: 6px; }
        @keyframes kelp-spin { to { transform: rotate(360deg); } }
        .kelp-edit { padding: 3px 12px 3px 16px; }
        .kelp-pen { width: 16px; text-align: center; color: var(--k-sec); flex: none; }
        .kelp-what-id { color: var(--k-sec); flex: none; }
        .kelp-fold { cursor: default; }
        .kelp-hint { color: var(--k-sec); font-size: 11px; }
        .kelp-present .kelp-marks { display: none !important; }
        @media print { .kelp-marks { display: none !important; } }
        """
}
