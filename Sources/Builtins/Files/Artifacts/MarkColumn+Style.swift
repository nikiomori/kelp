import Foundation

extension MarkColumn {
    static let style = """
        .kelp-example { display: flex; gap: 6px; align-items: center; margin-top: 6px; }
        .kelp-example img { width: 64px; height: 40px; object-fit: cover; border-radius: var(--k-radius-xs);
          box-shadow: 0 0 0 1px var(--k-sep); }
        .kelp-n-ask { background: var(--k-purple) !important; color: #fff !important; }
        .kelp-suggest { display: block; width: calc(100% - 24px); margin: 0 12px 6px; padding: 5px 8px; border: 0;
          border-radius: var(--k-radius-sm); background: var(--k-hover); color: var(--k-label);
          font: var(--k-text-row) -apple-system, sans-serif;
          text-align: left; }
        .kelp-suggest:hover { background: var(--k-sel); }
        .kelp-col-band { display: none; align-items: center; gap: 6px; padding: 6px 12px;
          font-size: var(--k-text-caption);
          background: color-mix(in srgb, var(--k-orange) 12%, transparent); }
        .kelp-busy-dot { flex: none; width: 6px; height: 6px; border-radius: 50%; background: var(--k-orange); }
        .kelp-grip { color: var(--k-quiet); cursor: grab; }
        .kelp-edit-swatch { display: inline-block; width: 10px; height: 10px; margin-right: 4px; border-radius: 3px;
          vertical-align: -1px; box-shadow: inset 0 0 0 1px var(--k-sep); }
        .kelp-marks { position: absolute; inset: 0 auto auto 0; pointer-events: none; z-index: 11; }
        .kelp-pin { position: absolute; width: 18px; height: 18px; border-radius: 50%; background: var(--k-orange);
          color: #1d1d1f; font: 600 var(--k-text-micro)/18px -apple-system, sans-serif; text-align: center;
          box-shadow: 0 0 0 2px var(--k-card); }
        .kelp-pin.kelp-n-sent { background: var(--k-quiet); color: #fff; }
        .kelp-num.kelp-n-sent { background: var(--k-quiet); color: #fff; }
        .kelp-num.kelp-n-done { background: var(--k-rest); color: var(--k-sec); }
        .kelp-area { position: absolute; border: 1.5px dashed var(--k-orange); border-radius: var(--k-radius-xs);
          box-sizing: border-box; }
        .kelp-area.kelp-n-sent { border-color: var(--k-quiet); }
        .kelp-stroke { position: absolute; overflow: visible; }
        .kelp-stroke path { fill: none; stroke: var(--k-orange); stroke-width: 2.5; stroke-linecap: round;
          stroke-linejoin: round; }
        .kelp-stroke.kelp-n-sent path { stroke: var(--k-quiet); }
        .kelp-composer { position: absolute; z-index: 25; width: 280px; padding: 8px; box-sizing: border-box;
          border-radius: var(--k-radius-lg); background: var(--k-float); color: var(--k-label);
          box-shadow: 0 0 0 .5px var(--k-sep), 0 6px 20px rgba(0,0,0,.25);
          font: var(--k-text-row) -apple-system, sans-serif; }
        .kelp-compose-field { display: block; width: 100%; box-sizing: border-box; resize: none; border: 0;
          border-radius: var(--k-radius-sm); padding: 6px 8px; background: var(--k-card); color: var(--k-label);
          font: inherit;
          box-shadow: inset 0 0 0 1px var(--k-sep); outline: none; }
        .kelp-compose-field:focus { box-shadow: inset 0 0 0 1px var(--k-accent); }
        .kelp-composer .kelp-hint { margin-top: 6px; }
        .kelp-current-box { position: absolute; border: 1.5px solid var(--k-orange);
          border-radius: var(--k-radius-xs); }
        .kelp-mark { margin: 0 8px; padding: 2px 4px 8px; border-radius: var(--k-radius-sm); }
        .kelp-mark .kelp-row { padding: 4px 0; }
        .kelp-mark.kelp-on { background: var(--k-sel); }
        .kelp-mark-body { padding-left: 24px; display: flex; flex-direction: column; gap: 5px; }
        .kelp-past { color: var(--k-sec); font-size: var(--k-text-caption); }
        .kelp-faded { color: var(--k-sec); }
        .kelp-reply { border-radius: var(--k-radius-sm); background: var(--k-rest); padding: 6px 8px; }
        .kelp-outcome { color: var(--k-sec); font-size: var(--k-text-caption); }
        .kelp-outcome.kelp-warn { color: var(--k-text-orange); }
        .kelp-spin { width: 10px; height: 10px; border-radius: 50%; border: 1.5px solid var(--k-sep);
          border-top-color: var(--k-sec); animation: kelp-spin 1s linear infinite; flex: none; margin-right: 6px; }
        @keyframes kelp-spin { to { transform: rotate(360deg); } }
        .kelp-edit { padding: 3px 12px 3px 16px; }
        .kelp-pen { width: 16px; text-align: center; color: var(--k-sec); flex: none; }
        .kelp-what-id { color: var(--k-sec); flex: none; }
        .kelp-fold { cursor: default; }
        .kelp-hint { color: var(--k-sec); font-size: var(--k-text-caption); }
        .kelp-present .kelp-marks { display: none !important; }
        @media print { .kelp-marks { display: none !important; } }
        """
}
