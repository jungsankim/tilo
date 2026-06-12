import CoreGraphics
import Foundation

enum GridLayout {
    struct Entry {
        let id: UUID
        let aspect: CGFloat
    }

    struct Cell {
        let id: UUID
        let rect: CGRect
    }

    /// 원본 비율 유지 모드의 배치. 영상들의 실제 화면비를 기준으로,
    /// 순서를 바꿔 가며 검은 빈 공간이 최소가 되는 행 배치를 찾는다.
    /// 각 행은 화면 너비를 가득 채우고, 행 높이는 행에 속한 영상들의
    /// 화면비 합으로 정해진다.
    static func cells(for entries: [Entry], in size: CGSize) -> [Cell] {
        guard !entries.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let sorted = entries.sorted { $0.aspect > $1.aspect }
        let rows = bestPartition(of: sorted, in: size)
        return place(rows: rows, in: size)
    }

    // MARK: - 행 분할 탐색

    /// 분할의 표시 면적. 각 행이 너비를 채울 때 필요한 높이의 합(total)이
    /// 화면 높이를 넘으면 전체를 축소해야 하므로, total이 화면 높이에
    /// 가까울수록 좋다.
    private static func coverage(rowSums: [CGFloat], in size: CGSize) -> CGFloat {
        let total = rowSums.reduce(CGFloat(0)) { $0 + size.width / $1 }
        let scale = min(1, size.height / total)
        return scale * scale * size.width * total
    }

    private static func bestPartition(of entries: [Entry], in size: CGSize) -> [[Entry]] {
        if entries.count > 12 {
            return greedyPartition(of: entries, in: size)
        }

        // 화면비 내림차순 목록을 연속 구간으로 자르는 모든 분할을 탐색한다.
        // 2^(n-1)가지지만 n ≤ 12라서 충분히 빠르다.
        var bestRanges: [Range<Int>] = [0..<entries.count]
        var bestCoverage = -CGFloat(1)
        var current: [Range<Int>] = []

        func search(from index: Int) {
            if index == entries.count {
                let sums = current.map { range in
                    entries[range].reduce(CGFloat(0)) { $0 + $1.aspect }
                }
                let c = coverage(rowSums: sums, in: size)
                if c > bestCoverage {
                    bestCoverage = c
                    bestRanges = current
                }
                return
            }
            for end in (index + 1)...entries.count {
                current.append(index..<end)
                search(from: end)
                current.removeLast()
            }
        }
        search(from: 0)
        return bestRanges.map { Array(entries[$0]) }
    }

    /// 영상이 많을 때의 대안: 행 수를 전부 시도하되, 각 행의 화면비 합이
    /// 비슷해지도록 넓은 것부터 가장 가벼운 행에 배정한다.
    private static func greedyPartition(of entries: [Entry], in size: CGSize) -> [[Entry]] {
        var best: [[Entry]] = [entries]
        var bestCoverage = -CGFloat(1)

        for rowCount in 1...entries.count {
            var rows = Array(repeating: [Entry](), count: rowCount)
            var sums = Array(repeating: CGFloat(0), count: rowCount)
            for entry in entries {
                let target = sums.indices.min { sums[$0] < sums[$1] }!
                rows[target].append(entry)
                sums[target] += entry.aspect
            }
            let nonEmpty = rows.filter { !$0.isEmpty }
            let c = coverage(
                rowSums: nonEmpty.map { $0.reduce(CGFloat(0)) { $0 + $1.aspect } },
                in: size
            )
            if c > bestCoverage {
                bestCoverage = c
                best = nonEmpty
            }
        }
        return best
    }

    // MARK: - 배치

    private static func place(rows: [[Entry]], in size: CGSize) -> [Cell] {
        let sums = rows.map { $0.reduce(CGFloat(0)) { $0 + $1.aspect } }
        let naturalHeights = sums.map { size.width / $0 }
        let total = naturalHeights.reduce(0, +)

        // 원본 비율 유지: 전체가 화면을 넘으면 축소하고 가운데 정렬한다.
        var cells: [Cell] = []
        let scale = min(1, size.height / total)
        var y = (size.height - total * scale) / 2
        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = naturalHeights[rowIndex] * scale
            var x = (size.width - size.width * scale) / 2
            for entry in row {
                let width = rowHeight * entry.aspect
                cells.append(Cell(id: entry.id, rect: CGRect(x: x, y: y, width: width, height: rowHeight)))
                x += width
            }
            y += rowHeight
        }
        return cells
    }
}
