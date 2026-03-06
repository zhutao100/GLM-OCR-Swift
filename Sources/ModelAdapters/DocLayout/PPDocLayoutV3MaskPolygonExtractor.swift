import CoreGraphics
import Foundation
import VLMRuntimeKit

public struct PPDocLayoutV3Mask: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var data: [UInt8]

    public init(width: Int, height: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.data = data
    }
}

enum PPDocLayoutV3MaskPolygonExtractor {
    private struct IntPoint: Hashable {
        var x: Int
        var y: Int
    }

    private struct IntDirection: Equatable {
        var dx: Int
        var dy: Int
    }

    private struct ContourState: Hashable {
        var point: IntPoint
        var backtrack: IntPoint
    }

    private struct PixelPoint: Equatable {
        var x: Double
        var y: Double
    }

    static func extractPolygon(
        bbox: OCRNormalizedBBox,
        mask: PPDocLayoutV3Mask,
        imageSize: CGSize,
        epsilonRatio: Double = 0.004
    ) -> [OCRNormalizedPoint]? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let pixelBox = (
            x1: Int((CGFloat(bbox.x1) * imageSize.width / 1000.0).rounded(.down)),
            y1: Int((CGFloat(bbox.y1) * imageSize.height / 1000.0).rounded(.down)),
            x2: Int((CGFloat(bbox.x2) * imageSize.width / 1000.0).rounded(.down)),
            y2: Int((CGFloat(bbox.y2) * imageSize.height / 1000.0).rounded(.down))
        )

        guard let pixelPolygon = extractPixelPolygon(
            boxPx: pixelBox,
            mask: mask,
            imageSize: (width: Int(imageSize.width), height: Int(imageSize.height)),
            epsilonRatio: epsilonRatio
        ) else {
            return nil
        }

        return pixelPolygon.map { point in
            OCRNormalizedPoint(
                x: clampNormalized(Int((point.x * 1000.0 / imageSize.width).rounded(.toNearestOrEven))),
                y: clampNormalized(Int((point.y * 1000.0 / imageSize.height).rounded(.toNearestOrEven)))
            )
        }
    }

    private static func clampNormalized(_ value: Int) -> Int {
        max(0, min(1000, value))
    }

    private static func extractPixelPolygon(
        boxPx: (x1: Int, y1: Int, x2: Int, y2: Int),
        mask: PPDocLayoutV3Mask,
        imageSize: (width: Int, height: Int),
        epsilonRatio: Double
    ) -> [PixelPoint]? {
        let boxW = boxPx.x2 - boxPx.x1
        let boxH = boxPx.y2 - boxPx.y1
        guard boxW > 0, boxH > 0 else { return nil }
        guard mask.width > 0, mask.height > 0 else { return nil }
        guard mask.data.count == mask.width * mask.height else { return nil }

        func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(value, hi)) }
        func roundToEvenInt(_ value: Double) -> Int { Int(value.rounded(.toNearestOrEven)) }

        let scaleW = Double(mask.width) / Double(max(imageSize.width, 1))
        let scaleH = Double(mask.height) / Double(max(imageSize.height, 1))

        let xStart = clamp(roundToEvenInt(Double(boxPx.x1) * scaleW), 0, mask.width)
        let xEnd = clamp(roundToEvenInt(Double(boxPx.x2) * scaleW), 0, mask.width)
        let yStart = clamp(roundToEvenInt(Double(boxPx.y1) * scaleH), 0, mask.height)
        let yEnd = clamp(roundToEvenInt(Double(boxPx.y2) * scaleH), 0, mask.height)

        let xs = min(xStart, xEnd)
        let xe = max(xStart, xEnd)
        let ys = min(yStart, yEnd)
        let ye = max(yStart, yEnd)

        let cropMaskW = xe - xs
        let cropMaskH = ye - ys
        guard cropMaskW > 0, cropMaskH > 0 else { return nil }

        var cropped = [UInt8](repeating: 0, count: cropMaskW * cropMaskH)
        for y in 0..<cropMaskH {
            let srcRow = (ys + y) * mask.width + xs
            let dstRow = y * cropMaskW
            for x in 0..<cropMaskW {
                cropped[dstRow + x] = mask.data[srcRow + x]
            }
        }

        var resized = [UInt8](repeating: 0, count: boxW * boxH)
        for y in 0..<boxH {
            let srcY = Int(Double(y) * Double(cropMaskH) / Double(boxH))
            let srcRow = min(max(srcY, 0), cropMaskH - 1) * cropMaskW
            let dstRow = y * boxW
            for x in 0..<boxW {
                let srcX = Int(Double(x) * Double(cropMaskW) / Double(boxW))
                let value = cropped[srcRow + min(max(srcX, 0), cropMaskW - 1)]
                resized[dstRow + x] = value
            }
        }

        guard let start = largestComponentBoundaryStart(mask: resized, width: boxW, height: boxH) else {
            return nil
        }
        let rawContour = traceContour(mask: resized, width: boxW, height: boxH, start: start)
        guard !rawContour.isEmpty else { return nil }

        let contour = chainApproxSimple(
            rotateContourStartOpenCVLike(ensureOpenCVExternalContourOrientation(rawContour)))
        guard !contour.isEmpty else { return nil }

        let arc = arcLength(contour, closed: true)
        let simplified = approxPolyDPClosedOpenCV(contour, epsilon: max(0, epsilonRatio * arc))
        let polygon = extractCustomVertices(simplified)

        return polygon.map { point in
            PixelPoint(x: point.x + Double(boxPx.x1), y: point.y + Double(boxPx.y1))
        }
    }

    private static func largestComponentBoundaryStart(mask: [UInt8], width: Int, height: Int) -> IntPoint? {
        guard width > 0, height > 0, mask.count == width * height else { return nil }

        func idx(_ x: Int, _ y: Int) -> Int { y * width + x }
        func isInside(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < width && y >= 0 && y < height }
        func isBoundary(_ x: Int, _ y: Int) -> Bool {
            guard mask[idx(x, y)] != 0 else { return false }
            let neighbors4 = [(0, -1), (1, 0), (0, 1), (-1, 0)]
            for (dx, dy) in neighbors4 {
                let nx = x + dx
                let ny = y + dy
                if !isInside(nx, ny) || mask[idx(nx, ny)] == 0 {
                    return true
                }
            }
            return false
        }

        var visited = [UInt8](repeating: 0, count: width * height)
        var bestArea = 0
        var bestStart: IntPoint?
        let neighbors8 = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        for y in 0..<height {
            for x in 0..<width {
                let startIdx = idx(x, y)
                guard mask[startIdx] != 0, visited[startIdx] == 0 else { continue }

                var queue: [Int] = [startIdx]
                visited[startIdx] = 1
                var head = 0
                var area = 0
                var componentBoundary: IntPoint?

                while head < queue.count {
                    let current = queue[head]
                    head += 1
                    area += 1
                    let cx = current % width
                    let cy = current / width

                    if isBoundary(cx, cy) {
                        let point = IntPoint(x: cx, y: cy)
                        if let existing = componentBoundary {
                            if point.y < existing.y || (point.y == existing.y && point.x < existing.x) {
                                componentBoundary = point
                            }
                        } else {
                            componentBoundary = point
                        }
                    }

                    for (dx, dy) in neighbors8 {
                        let nx = cx + dx
                        let ny = cy + dy
                        guard isInside(nx, ny) else { continue }
                        let next = idx(nx, ny)
                        guard mask[next] != 0, visited[next] == 0 else { continue }
                        visited[next] = 1
                        queue.append(next)
                    }
                }

                if area > bestArea, let componentBoundary {
                    bestArea = area
                    bestStart = componentBoundary
                }
            }
        }

        return bestStart
    }

    private static func traceContour(mask: [UInt8], width: Int, height: Int, start: IntPoint) -> [PixelPoint] {
        guard width > 0, height > 0, mask.count == width * height else { return [] }

        func at(_ x: Int, _ y: Int) -> UInt8 {
            guard x >= 0, x < width, y >= 0, y < height else { return 0 }
            return mask[y * width + x]
        }

        let dirs = [
            IntDirection(dx: 1, dy: 0),
            IntDirection(dx: 1, dy: 1),
            IntDirection(dx: 0, dy: 1),
            IntDirection(dx: -1, dy: 1),
            IntDirection(dx: -1, dy: 0),
            IntDirection(dx: -1, dy: -1),
            IntDirection(dx: 0, dy: -1),
            IntDirection(dx: 1, dy: -1),
        ]

        let startBacktrack = IntPoint(x: start.x - 1, y: start.y)
        var visitedStates: Set<ContourState> = [ContourState(point: start, backtrack: startBacktrack)]
        var contour: [PixelPoint] = [PixelPoint(x: Double(start.x), y: Double(start.y))]
        contour.reserveCapacity(width * height)

        var point = start
        var backtrack = startBacktrack

        while true {
            let startDirection = firstDirectionIndex(from: point, backtrack: backtrack, directions: dirs)
            var found: (next: IntPoint, newBacktrack: IntPoint)?

            for offset in 0..<dirs.count {
                let index = (startDirection + offset) % dirs.count
                let nx = point.x + dirs[index].dx
                let ny = point.y + dirs[index].dy
                if at(nx, ny) != 0 {
                    let prevIndex = (index + 7) % dirs.count
                    found = (
                        IntPoint(x: nx, y: ny),
                        IntPoint(x: point.x + dirs[prevIndex].dx, y: point.y + dirs[prevIndex].dy)
                    )
                    break
                }
            }

            guard let found else { break }
            point = found.next
            backtrack = found.newBacktrack
            contour.append(PixelPoint(x: Double(point.x), y: Double(point.y)))

            if point == start && backtrack == startBacktrack {
                break
            }

            let state = ContourState(point: point, backtrack: backtrack)
            if !visitedStates.insert(state).inserted {
                break
            }
        }

        if contour.count >= 2, contour.first == contour.last {
            contour.removeLast()
        }
        return contour
    }

    private static func firstDirectionIndex(
        from point: IntPoint,
        backtrack: IntPoint,
        directions: [IntDirection]
    ) -> Int {
        let dx = backtrack.x - point.x
        let dy = backtrack.y - point.y
        if let index = directions.firstIndex(where: { $0.dx == dx && $0.dy == dy }) {
            return (index + 1) % directions.count
        }
        return 0
    }

    private static func chainApproxSimple(_ contour: [PixelPoint]) -> [PixelPoint] {
        let deduped = removeConsecutiveDuplicates(contour)
        guard deduped.count >= 2 else { return deduped }
        if deduped.count == 2 { return deduped }

        var output: [PixelPoint] = [deduped[0]]
        output.reserveCapacity(deduped.count)

        var previousDirection = direction(from: deduped[0], to: deduped[1])
        for index in 1..<deduped.count {
            let current = deduped[index]
            let next = deduped[(index + 1) % deduped.count]
            let currentDirection = direction(from: current, to: next)
            if currentDirection != previousDirection {
                output.append(current)
            }
            previousDirection = currentDirection
        }

        return removeConsecutiveDuplicates(output)
    }

    private static func removeConsecutiveDuplicates(_ points: [PixelPoint]) -> [PixelPoint] {
        guard !points.isEmpty else { return [] }
        var output: [PixelPoint] = []
        output.reserveCapacity(points.count)
        for point in points {
            if let last = output.last, last == point { continue }
            output.append(point)
        }
        if output.count >= 2, output.first == output.last {
            output.removeLast()
        }
        return output
    }

    private static func direction(from a: PixelPoint, to b: PixelPoint) -> IntDirection {
        IntDirection(dx: signum(b.x - a.x), dy: signum(b.y - a.y))
    }

    private static func signum(_ value: Double) -> Int {
        if value > 0 { return 1 }
        if value < 0 { return -1 }
        return 0
    }

    private static func ensureOpenCVExternalContourOrientation(_ points: [PixelPoint]) -> [PixelPoint] {
        guard points.count >= 3 else { return points }
        if signedArea(points) > 0 {
            return Array(points.reversed())
        }
        return points
    }

    private static func rotateContourStartOpenCVLike(_ points: [PixelPoint]) -> [PixelPoint] {
        guard points.count >= 2 else { return points }

        var bestIndex = 0
        var best = points[0]
        for index in 1..<points.count {
            let point = points[index]
            if point.y < best.y || (point.y == best.y && point.x < best.x) {
                bestIndex = index
                best = point
            }
        }

        guard bestIndex != 0 else { return points }
        return Array(points[bestIndex...] + points[..<bestIndex])
    }

    private static func signedArea(_ points: [PixelPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in 0..<points.count {
            let next = (index + 1) % points.count
            area += points[index].x * points[next].y
            area -= points[next].x * points[index].y
        }
        return area * 0.5
    }

    private static func approxPolyDPClosedOpenCV(_ points: [PixelPoint], epsilon: Double) -> [PixelPoint] {
        let count0 = points.count
        guard count0 > 0 else { return [] }
        if count0 <= 2 { return points }

        struct Slice {
            var start: Int
            var end: Int
        }

        let eps = epsilon * epsilon
        var stack: [Slice] = []
        stack.reserveCapacity(count0)
        var output: [PixelPoint] = []
        output.reserveCapacity(count0)

        var slice = Slice(start: 0, end: 0)
        var rightSlice = Slice(start: 0, end: 0)
        var position = 0
        let initIters = 3
        var leEps = false
        var startPoint = points[0]
        var endPoint = points[0]
        var point = points[0]

        func readSource(_ position: inout Int) -> PixelPoint {
            let point = points[position]
            position += 1
            if position >= count0 { position = 0 }
            return point
        }

        func readOutput(_ position: inout Int, count: Int) -> PixelPoint {
            let point = output[position]
            position += 1
            if position >= count { position = 0 }
            return point
        }

        rightSlice.start = 0
        for _ in 0..<initIters {
            var maxDist = 0.0
            position = (position + rightSlice.start) % count0
            startPoint = readSource(&position)
            for index in 1..<count0 {
                _ = index
                point = readSource(&position)
                let dx = point.x - startPoint.x
                let dy = point.y - startPoint.y
                let distance = dx * dx + dy * dy
                if distance > maxDist {
                    maxDist = distance
                    rightSlice.start = index
                }
            }
            leEps = maxDist <= eps
        }

        if !leEps {
            let start = position % count0
            slice.start = start
            rightSlice.end = start
            rightSlice.start = (rightSlice.start + slice.start) % count0
            slice.end = rightSlice.start
            stack.append(rightSlice)
            stack.append(slice)
        } else {
            output.append(startPoint)
        }

        while let current = stack.popLast() {
            slice = current
            endPoint = points[slice.end]
            position = slice.start
            startPoint = readSource(&position)

            if position != slice.end {
                let dx = endPoint.x - startPoint.x
                let dy = endPoint.y - startPoint.y
                let segmentLen2 = dx * dx + dy * dy
                if segmentLen2 > 0 {
                    var maxDist2MulSegmentLen2 = 0.0
                    while position != slice.end {
                        point = readSource(&position)
                        let px = point.x - startPoint.x
                        let py = point.y - startPoint.y
                        let projection = px * dx + py * dy
                        let distance2MulSegmentLen2: Double
                        if projection < 0 {
                            distance2MulSegmentLen2 = (px * px + py * py) * segmentLen2
                        } else if projection > segmentLen2 {
                            let ex = point.x - endPoint.x
                            let ey = point.y - endPoint.y
                            distance2MulSegmentLen2 = (ex * ex + ey * ey) * segmentLen2
                        } else {
                            let distance = py * dx - px * dy
                            distance2MulSegmentLen2 = distance * distance
                        }
                        if distance2MulSegmentLen2 > maxDist2MulSegmentLen2 {
                            maxDist2MulSegmentLen2 = distance2MulSegmentLen2
                            rightSlice.start = (position + count0 - 1) % count0
                        }
                    }
                    leEps = maxDist2MulSegmentLen2 <= eps * segmentLen2
                } else {
                    leEps = true
                }
            } else {
                leEps = true
                startPoint = points[slice.start]
            }

            if leEps {
                output.append(startPoint)
            } else {
                rightSlice.end = slice.end
                slice.end = rightSlice.start
                stack.append(rightSlice)
                stack.append(slice)
            }
        }

        let count = output.count
        if count <= 2 { return output }

        var positionOut = count - 1
        startPoint = readOutput(&positionOut, count: count)
        var writePosition = positionOut
        point = readOutput(&positionOut, count: count)

        var newCount = count
        var index = 0
        while index < count && newCount > 2 {
            endPoint = readOutput(&positionOut, count: count)
            let dx = endPoint.x - startPoint.x
            let dy = endPoint.y - startPoint.y
            let distance = abs((point.x - startPoint.x) * dy - (point.y - startPoint.y) * dx)
            let successiveInnerProduct =
                (point.x - startPoint.x) * (endPoint.x - point.x) +
                (point.y - startPoint.y) * (endPoint.y - point.y)

            if distance * distance <= 0.5 * eps * (dx * dx + dy * dy) && dx != 0 && dy != 0
                && successiveInnerProduct >= 0
            {
                newCount -= 1
                output[writePosition] = endPoint
                startPoint = endPoint
                writePosition += 1
                if writePosition >= count { writePosition = 0 }
                point = readOutput(&positionOut, count: count)
                index += 2
                continue
            }

            output[writePosition] = point
            startPoint = point
            writePosition += 1
            if writePosition >= count { writePosition = 0 }
            point = endPoint
            index += 1
        }

        if newCount < count {
            output = Array(output[0..<newCount])
        }
        return output
    }

    private static func arcLength(_ points: [PixelPoint], closed: Bool) -> Double {
        guard points.count >= 2 else { return 0 }
        var sum = 0.0
        for index in 1..<points.count {
            let dx = points[index].x - points[index - 1].x
            let dy = points[index].y - points[index - 1].y
            sum += (dx * dx + dy * dy).squareRoot()
        }
        if closed, let first = points.first, let last = points.last {
            let dx = first.x - last.x
            let dy = first.y - last.y
            sum += (dx * dx + dy * dy).squareRoot()
        }
        return sum
    }

    private static func extractCustomVertices(_ polygon: [PixelPoint], sharpAngleThresh: Double = 45.0)
        -> [PixelPoint]
    {
        let count = polygon.count
        guard count > 0 else { return [] }

        var result: [PixelPoint] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            let previousPoint = polygon[(index - 1 + count) % count]
            let currentPoint = polygon[index]
            let nextPoint = polygon[(index + 1) % count]

            let vector1x = previousPoint.x - currentPoint.x
            let vector1y = previousPoint.y - currentPoint.y
            let vector2x = nextPoint.x - currentPoint.x
            let vector2y = nextPoint.y - currentPoint.y
            let crossProductValue = (vector1y * vector2x) - (vector1x * vector2y)

            if crossProductValue < 0 {
                let norm1 = (vector1x * vector1x + vector1y * vector1y).squareRoot()
                let norm2 = (vector2x * vector2x + vector2y * vector2y).squareRoot()
                let denom = norm1 * norm2

                var angle = Double.nan
                if denom > 0 {
                    let dot = vector1x * vector2x + vector1y * vector2y
                    let angleCos = max(-1.0, min(1.0, dot / denom))
                    angle = acos(angleCos) * 180.0 / .pi
                }

                if angle.isFinite, abs(angle - sharpAngleThresh) < 1.0, norm1 > 0, norm2 > 0 {
                    var directionX = vector1x / norm1 + vector2x / norm2
                    var directionY = vector1y / norm1 + vector2y / norm2
                    let directionNorm = (directionX * directionX + directionY * directionY).squareRoot()

                    if directionNorm > 0 {
                        directionX /= directionNorm
                        directionY /= directionNorm
                        let stepSize = (norm1 + norm2) / 2.0
                        result.append(
                            PixelPoint(
                                x: currentPoint.x + directionX * stepSize,
                                y: currentPoint.y + directionY * stepSize
                            ))
                    } else {
                        result.append(currentPoint)
                    }
                } else {
                    result.append(currentPoint)
                }
            }
        }

        return result
    }
}
