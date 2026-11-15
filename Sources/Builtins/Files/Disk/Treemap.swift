import CoreGraphics

/// Rectangles for sizes (biggest first) that fill a rectangle, each as near a square as the rest allow: the squarified
/// treemap (Bruls, Huizing, van Wijk). A row of them is laid along the free space's shorter side until the next would
/// make the row's worst one longer.
enum Treemap {
    static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
        let areas = sizes.map { $0 * rect.width * rect.height / total }
        var out: [CGRect] = [], free = rect, row: [Double] = [], index = 0
        while index < areas.count {
            let side = min(free.width, free.height), longer = row + [areas[index]]
            if row.isEmpty || worst(longer, side) <= worst(row, side) {
                row = longer
                index += 1
            } else {
                let placed = place(row, in: free)
                out += placed.rects
                free = placed.free
                row = []
            }
        }
        return out + place(row, in: free).rects
    }

    /// The longest side over the shortest of the row's most elongated rectangle.
    private static func worst(_ row: [Double], _ side: Double) -> Double {
        let sum = row.reduce(0, +), most = row.max() ?? 0, least = row.min() ?? 0
        guard sum > 0, least > 0 else { return .infinity }
        return max(side * side * most / (sum * sum), sum * sum / (side * side * least))
    }

    /// The row along the free space's shorter side, and what's left of it.
    private static func place(_ row: [Double], in free: CGRect) -> (rects: [CGRect], free: CGRect) {
        let sum = row.reduce(0, +)
        guard sum > 0 else { return (row.map { _ in .zero }, free) }
        var rects: [CGRect] = []
        if free.width >= free.height {   // a column at the left
            let width = sum / free.height
            var y = free.minY
            for area in row {
                rects.append(CGRect(x: free.minX, y: y, width: width, height: area / width))
                y += area / width
            }
            return (rects, CGRect(x: free.minX + width, y: free.minY, width: free.width - width, height: free.height))
        }
        let height = sum / free.width   // a row at the top
        var x = free.minX
        for area in row {
            rects.append(CGRect(x: x, y: free.minY, width: area / height, height: height))
            x += area / height
        }
        return (rects, CGRect(x: free.minX, y: free.minY + height, width: free.width, height: free.height - height))
    }
}
