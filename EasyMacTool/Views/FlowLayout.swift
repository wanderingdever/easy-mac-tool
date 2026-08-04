import SwiftUI

/// A simple wrap layout that arranges subviews left-to-right and wraps to the
/// next row when the current row is full — like text wrapping. Used by the
/// switcher so all window thumbnails are always visible with NO scroll bar,
/// regardless of preview size or window count.
///
/// Based on SwiftUI's `Layout` protocol (macOS 13+).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    struct CacheData {
        var rows: [Row] = []
    }

    func makeCache(subviews: Subviews) -> CacheData {
        CacheData()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: maxWidth)
        cache.rows = rows
        guard !rows.isEmpty else { return .zero }

        let totalHeight = rows.reduce(CGFloat.zero) { partial, row in
            partial + row.height + (partial > 0 ? spacing : 0)
        }
        let totalWidth = rows.map { $0.width }.max() ?? 0
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        let rows = cache.rows
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let candidateWidth = rows[rows.count - 1].width
                + (rows[rows.count - 1].indices.isEmpty ? 0 : spacing)
                + size.width
            if candidateWidth > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let rowIdx = rows.count - 1
            rows[rowIdx].indices.append(index)
            if !rows[rowIdx].indices.isEmpty {
                rows[rowIdx].width += (rows[rowIdx].indices.count > 1 ? spacing : 0) + size.width
            }
            rows[rowIdx].height = max(rows[rowIdx].height, size.height)
        }
        return rows
    }
}
