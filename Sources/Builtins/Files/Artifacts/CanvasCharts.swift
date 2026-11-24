import Foundation

/// A chart's numbers by hand: in Edit, a double click on a chart (`data-chart`) that keeps a `<table>`, or Numbers… in
/// its menu (`kelpChartNumbers`), sends its rows (`chartData`); once they are saved, the agent is asked to draw it
/// again from them.
enum CanvasCharts {
    static func source(labels: [String: String]) -> String {
        "(function (L) {\n" + body + "\n})(\(MarkdownTab.js(labels)));"
    }

    private static let body = """
          const K = window.kelpCanvas; if (!K) return;
          const numbers = (board, chart) => {
            const table = chart?.querySelector('table'); if (!table) return false;
            const rows = [...table.rows].map(r => [...r.cells].map(c => c.textContent.trim()));
            K.post({ kind: 'chartData', board, id: chart.getAttribute('data-id'), rows });
            return true;
          };
          K.sheet.addEventListener('dblclick', e => {
            if (K.mode() !== 'edit') return;
            const hit = K.under(e, true);
            const chart = hit?.e.closest('[data-chart][data-id]');
            if (hit && numbers(hit.f.dataset.board, chart)) e.stopImmediatePropagation();
          }, true);
          window.kelpChartNumbers = (board, id) => numbers(board,
            K.light(board)?.contentDocument?.querySelector('[data-chart][data-id="' + CSS.escape(id) + '"]'));
        """
}
