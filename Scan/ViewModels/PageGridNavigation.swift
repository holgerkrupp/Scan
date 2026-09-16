import Foundation

/// Keyboard navigation over the page grid, independent of SwiftUI so it can
/// be unit-tested: which page becomes selected for an arrow key, Home or End,
/// given the current selection and the number of columns on screen.
enum PageGridNavigation {
    enum Move: Equatable {
        case left, right, up, down, first, last
    }

    /// The index to select after `move`, or `nil` when there are no pages.
    /// Without a selection every move selects the first page, except End,
    /// which selects the last. Moving past an edge keeps the selection, and
    /// moving down from the last full row lands on the last page like the
    /// Finder's icon view.
    static func index(after current: Int?, move: Move, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }
        let columns = max(1, columns)
        guard let current, current >= 0, current < count else {
            return move == .last ? count - 1 : 0
        }
        switch move {
        case .first:
            return 0
        case .last:
            return count - 1
        case .left:
            return max(0, current - 1)
        case .right:
            return min(count - 1, current + 1)
        case .up:
            return current - columns >= 0 ? current - columns : current
        case .down:
            if current + columns < count { return current + columns }
            let lastRowStart = (count - 1) / columns * columns
            return current < lastRowStart ? count - 1 : current
        }
    }

    /// Columns of an adaptive grid: as many items of at least
    /// `minimumItemWidth` as fit into `width` with `spacing` between them.
    static func columnCount(forWidth width: Double, minimumItemWidth: Double, spacing: Double) -> Int {
        guard width > 0, minimumItemWidth > 0 else { return 1 }
        return max(1, Int((width + spacing) / (minimumItemWidth + spacing)))
    }
}
