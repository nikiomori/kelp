import CoreGraphics
import Testing

@testable import BuiltinFiles

/// Each size gets its share of the area, inside the rectangle, none over another, and none a sliver when it needn't be.
@Test func treemapFillsTheRectangleInProportion() {
    let rect = CGRect(x: 10, y: 20, width: 600, height: 400), sizes: [Double] = [6.8, 5.0, 1.4, 0.27, 0.12, 0.08]
    let rects = Treemap.layout(sizes, in: rect), total = sizes.reduce(0, +)
    #expect(rects.count == sizes.count)
    for (r, size) in zip(rects, sizes) {
        #expect(abs(r.width * r.height - size / total * rect.width * rect.height) < 0.5)
        #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(r))
    }
    for i in rects.indices {
        for j in rects.indices where i < j {
            #expect(rects[i].intersection(rects[j]).width < 0.01 || rects[i].intersection(rects[j]).height < 0.01)
        }
    }
    #expect(max(rects[0].width / rects[0].height, rects[0].height / rects[0].width) < 2)   // the biggest stays squarish
    #expect(Treemap.layout([], in: rect).isEmpty && Treemap.layout([0, 0], in: rect) == [.zero, .zero])
}
