import CoreGraphics
import Foundation

/// 꽉 채우기 모드의 모자이크 배치.
///
/// 영상들을 "좌우로 나란히(V)" 또는 "위아래로 쌓기(H)"로 묶는 이진 트리를
/// 만들면, 트리의 화면비는 V는 두 화면비의 합, H는 조화합으로 정해진다.
/// 트리 화면비가 화면 화면비와 일치하면 모든 영상이 원본 비율 그대로
/// 빈틈 없이 배치되고, 차이가 나는 만큼만 모든 영상이 균등하게 잘린다.
/// 따라서 화면 화면비에 가장 가까운 트리를 찾는 것이 목표다.
enum MosaicLayout {
    private indirect enum Node {
        case leaf(Int, CGFloat)
        case split(vertical: Bool, CGFloat, Int, Node, Node)

        var aspect: CGFloat {
            switch self {
            case .leaf(_, let aspect): return aspect
            case .split(_, let aspect, _, _, _): return aspect
            }
        }

        var leafCount: Int {
            switch self {
            case .leaf: return 1
            case .split(_, _, let count, _, _): return count
            }
        }

        static func combine(_ a: Node, _ b: Node, vertical: Bool) -> Node {
            let aspect = vertical
                ? a.aspect + b.aspect
                : (a.aspect * b.aspect) / (a.aspect + b.aspect)
            return .split(vertical: vertical, aspect, a.leafCount + b.leafCount, a, b)
        }
    }

    static func cells(for entries: [GridLayout.Entry], in size: CGSize) -> [GridLayout.Cell] {
        guard !entries.isEmpty, size.width > 0, size.height > 0 else { return [] }
        if entries.count == 1 {
            return [GridLayout.Cell(id: entries[0].id, rect: CGRect(origin: .zero, size: size))]
        }
        let root = bestTree(aspects: entries.map(\.aspect), target: size.width / size.height)
        var cells: [GridLayout.Cell] = []
        place(root, in: CGRect(origin: .zero, size: size), entries: entries, into: &cells)
        return cells
    }

    // MARK: - 트리 탐색

    private struct CacheKey: Hashable {
        let aspects: [CGFloat]
        let targetBucket: Int
    }

    private static var cache: [CacheKey: Node] = [:]
    private static var cacheOrder: [CacheKey] = []

    private static func bestTree(aspects: [CGFloat], target: CGFloat) -> Node {
        // 창 크기를 조절하는 동안 매 프레임 다시 탐색하지 않도록,
        // 영상 구성과 화면비 구간이 같으면 캐시를 쓴다.
        let key = CacheKey(aspects: aspects, targetBucket: Int((log2(target) * 10).rounded()))
        if let cached = cache[key] { return cached }

        let root = aspects.count <= 6
            ? exactBestTree(aspects: aspects, target: target)
            : stochasticBestTree(aspects: aspects, target: target, bucket: key.targetBucket)

        if cache.count >= 32, let oldest = cacheOrder.first {
            cache.removeValue(forKey: oldest)
            cacheOrder.removeFirst()
        }
        cache[key] = root
        cacheOrder.append(key)
        return root
    }

    /// 영상이 적으면 모든 이진 트리를 전수 탐색한다.
    /// 같은 화면비 조합은 한 번만 시도해 중복 영상을 가지치기한다.
    private static func exactBestTree(aspects: [CGFloat], target: CGFloat) -> Node {
        var best: Node?
        var bestScore = CGFloat.infinity

        func recurse(_ nodes: [Node]) {
            if nodes.count == 1 {
                let score = treeScore(nodes[0], target: target)
                if score < bestScore {
                    bestScore = score
                    best = nodes[0]
                }
                return
            }
            var seen = Set<UInt64>()
            for i in 0..<(nodes.count - 1) {
                for j in (i + 1)..<nodes.count {
                    let low = min(nodes[i].aspect, nodes[j].aspect)
                    let high = max(nodes[i].aspect, nodes[j].aspect)
                    for vertical in [true, false] {
                        var hash = Double(low).bitPattern &* 31 &+ Double(high).bitPattern
                        hash = hash &* 2 &+ (vertical ? 1 : 0)
                        guard seen.insert(hash).inserted else { continue }
                        var next = nodes
                        next.remove(at: j)
                        next.remove(at: i)
                        next.append(Node.combine(nodes[i], nodes[j], vertical: vertical))
                        recurse(next)
                    }
                }
            }
        }

        recurse(aspects.enumerated().map { .leaf($0.offset, $0.element) })
        return best!
    }

    private static func stochasticBestTree(aspects: [CGFloat], target: CGFloat, bucket: Int) -> Node {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for aspect in aspects { seed = seed &* 31 &+ Double(aspect).bitPattern }
        var rng = SplitMix64(state: seed ^ UInt64(bitPattern: Int64(bucket)))

        // 행/열 기반 구성을 하한선으로 깔아 두고, 무작위 탐색은
        // 그보다 좋은 트리를 찾았을 때만 채택한다
        var best = structuredBestTree(aspects: aspects, target: target)
        var bestScore = best.map { treeScore($0, target: target) } ?? .infinity
        let restarts = max(300, min(800, 8000 / aspects.count))
        for restart in 0..<restarts {
            // 절반은 화면비 우선, 절반은 타일 크기 균형 우선으로 탐색해서
            // 최종 점수가 좋은 쪽을 고른다
            let balanceWeight: CGFloat = restart % 2 == 0 ? 0.12 : 0
            let root = randomGreedyTree(aspects: aspects, target: target, balanceWeight: balanceWeight, rng: &rng)
            let score = treeScore(root, target: target)
            if score < bestScore {
                bestScore = score
                best = root
            }
        }
        return best!
    }

    /// 화면비 순으로 정렬한 영상들을 연속 구간으로 묶는 모든 분할에 대해
    /// "행 구성"(구간을 가로로 잇고 행끼리 쌓기)과 "열 구성"(구간을 세로로
    /// 쌓고 열끼리 잇기)을 평가해 가장 좋은 트리를 돌려준다.
    private static func structuredBestTree(aspects: [CGFloat], target: CGFloat) -> Node? {
        let n = aspects.count
        guard n >= 2, n <= 16 else { return nil }
        let leaves: [Node] = aspects.enumerated()
            .sorted { $0.element > $1.element }
            .map { .leaf($0.offset, $0.element) }

        var best: Node?
        var bestScore = CGFloat.infinity
        for mask in 0..<(1 << (n - 1)) {
            // 비트 k가 켜져 있으면 k번째와 k+1번째 사이를 자른다
            var groups: [[Node]] = [[]]
            for (index, leaf) in leaves.enumerated() {
                groups[groups.count - 1].append(leaf)
                if index < n - 1, (mask >> index) & 1 == 1 { groups.append([]) }
            }
            let rowsRoot = chain(groups.map { chain($0, vertical: true) }, vertical: false)
            let colsRoot = chain(groups.map { chain($0, vertical: false) }, vertical: true)
            for root in [rowsRoot, colsRoot] {
                let score = treeScore(root, target: target)
                if score < bestScore {
                    bestScore = score
                    best = root
                }
            }
        }
        return best
    }

    private static func chain(_ nodes: [Node], vertical: Bool) -> Node {
        nodes.dropFirst().reduce(nodes[0]) { Node.combine($0, $1, vertical: vertical) }
    }

    /// 매 단계 모든 (쌍, 방향) 후보 중 목표 화면비에 가까운 상위 후보에서
    /// 무작위로 하나를 골라 합친다. 시드가 고정이라 같은 입력이면 결과도 같다.
    private static func randomGreedyTree(aspects: [CGFloat], target: CGFloat, balanceWeight: CGFloat, rng: inout SplitMix64) -> Node {
        var nodes: [Node] = aspects.enumerated().map { .leaf($0.offset, $0.element) }

        // 중간 블록은 나중에 c개 열(화면비/c)이나 r개 행(화면비×r)으로
        // 합쳐질 수 있으므로, 화면비의 약수·배수에 가까워도 좋은 후보다.
        let multipliers: [CGFloat] = [0.25, 1.0 / 3.0, 0.5, 1.0, 2.0, 3.0, 4.0]
        let anchors = multipliers.map { target * $0 }
        func distance(to combined: CGFloat) -> CGFloat {
            anchors.map { abs(log(combined / $0)) }.min()!
        }

        while nodes.count > 1 {
            var candidates: [(i: Int, j: Int, vertical: Bool, distance: CGFloat)] = []
            let isLast = nodes.count == 2
            for i in 0..<(nodes.count - 1) {
                for j in (i + 1)..<nodes.count {
                    // 잎 개수가 비슷한 블록끼리 합쳐야 타일 크기가 고르게 나온다
                    let balance = abs(log(CGFloat(nodes[i].leafCount) / CGFloat(nodes[j].leafCount)))
                    for vertical in [true, false] {
                        let combined = vertical
                            ? nodes[i].aspect + nodes[j].aspect
                            : (nodes[i].aspect * nodes[j].aspect) / (nodes[i].aspect + nodes[j].aspect)
                        // 마지막 합치기는 곧 루트이므로 화면비 자체에 맞아야 한다
                        let dist = isLast ? abs(log(combined / target)) : distance(to: combined)
                        candidates.append((i, j, vertical, dist + balanceWeight * balance))
                    }
                }
            }
            candidates.sort { $0.distance < $1.distance }
            let pool = min(candidates.count, 3 + nodes.count / 2)
            // 상위 후보일수록 잘 뽑히도록 제곱 분포로 선택
            let r = CGFloat(rng.next() >> 11) * 0x1.0p-53
            let pick = candidates[min(pool - 1, Int(CGFloat(pool) * r * r))]
            let merged = Node.combine(nodes[pick.i], nodes[pick.j], vertical: pick.vertical)
            nodes.remove(at: pick.j)
            nodes.remove(at: pick.i)
            nodes.append(merged)
        }
        return nodes[0]
    }

    /// 화면비 불일치(= 모든 영상의 균등 크롭량)가 주 비용.
    /// 타일 간 면적 편차는 4배까지는 허용하고 그 이상부터 가파르게 벌점.
    private static func treeScore(_ root: Node, target: CGFloat) -> CGFloat {
        var areas: [CGFloat] = []
        collectAreas(root, area: 1, into: &areas)
        let imbalance = log((areas.max() ?? 1) / max(areas.min() ?? 1, 0.0001))
        return abs(log(root.aspect / target))
            + 0.02 * imbalance
            + 0.3 * max(0, imbalance - log(4))
    }

    private static func collectAreas(_ node: Node, area: CGFloat, into areas: inout [CGFloat]) {
        switch node {
        case .leaf:
            areas.append(area)
        case .split(let vertical, _, _, let a, let b):
            let shareA = vertical
                ? a.aspect / (a.aspect + b.aspect)
                : (1 / a.aspect) / (1 / a.aspect + 1 / b.aspect)
            collectAreas(a, area: area * shareA, into: &areas)
            collectAreas(b, area: area * (1 - shareA), into: &areas)
        }
    }

    // MARK: - 배치

    private static func place(_ node: Node, in rect: CGRect, entries: [GridLayout.Entry], into cells: inout [GridLayout.Cell]) {
        switch node {
        case .leaf(let index, _):
            cells.append(GridLayout.Cell(id: entries[index].id, rect: rect))
        case .split(let vertical, _, _, let a, let b):
            if vertical {
                let widthA = rect.width * a.aspect / (a.aspect + b.aspect)
                place(a, in: CGRect(x: rect.minX, y: rect.minY, width: widthA, height: rect.height),
                      entries: entries, into: &cells)
                place(b, in: CGRect(x: rect.minX + widthA, y: rect.minY, width: rect.width - widthA, height: rect.height),
                      entries: entries, into: &cells)
            } else {
                let heightA = rect.height * (1 / a.aspect) / (1 / a.aspect + 1 / b.aspect)
                place(a, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: heightA),
                      entries: entries, into: &cells)
                place(b, in: CGRect(x: rect.minX, y: rect.minY + heightA, width: rect.width, height: rect.height - heightA),
                      entries: entries, into: &cells)
            }
        }
    }
}

/// 결정적 결과가 필요해서 시드를 직접 주는 간단한 난수 생성기
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
