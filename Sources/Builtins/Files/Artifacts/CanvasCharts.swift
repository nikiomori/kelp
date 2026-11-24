import Foundation

/// A chart's numbers by hand: in Edit, a double click on a chart (`data-chart`) that keeps a `<table>` sends its rows
/// (`chartData`); once they are saved, a mark on the chart asks the agent to draw it again from them.
enum CanvasCharts {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));"
    }

    private static let body = """
          const K = window.kelpCanvas; if (!K) return;
          K.sheet.addEventListener('dblclick', e => {
            if (K.mode() !== 'edit') return;
            const hit = K.under(e, true), chart = hit?.e.closest('[data-chart][data-id]');
            const table = chart?.querySelector('table'); if (!table) return;
            e.stopImmediatePropagation();
            const rows = [...table.rows].map(r => [...r.cells].map(c => c.textContent.trim()));
            K.post({ kind: 'chartData', board: hit.f.dataset.board, id: chart.getAttribute('data-id'), rows });
          }, true);
          window.kelpChartChanged = (board, id) => {
            const e = K.light(board)?.contentDocument?.querySelector('[data-id="' + CSS.escape(id) + '"]');
            if (e) window.kelpMarks?.add(Object.assign({ kind: 'element', board, note: L.redraw }, K.describe(e)));
          };
        """
}
