import Dispatch
import Foundation

public enum VisionResizeError: Error, Sendable, Equatable {
    case invalidDimensions(srcWidth: Int, srcHeight: Int, dstWidth: Int, dstHeight: Int)
    case invalidBufferSize(expected: Int, actual: Int)
}

public enum VisionResize {
    private struct ResizeCoeff {
        let i0: Int
        let i1: Int
        let i2: Int
        let i3: Int
        let w0: Double
        let w1: Double
        let w2: Double
        let w3: Double
    }

    private static func cubicKernel(_ x: Double) -> Double {
        let a = -0.5
        let ax = abs(x)
        let ax2 = ax * ax
        let ax3 = ax2 * ax
        if ax <= 1 {
            return (a + 2) * ax3 - (a + 3) * ax2 + 1
        }
        if ax < 2 {
            return a * ax3 - 5 * a * ax2 + 8 * a * ax - 4 * a
        }
        return 0
    }

    private static func buildResizeCoeffs(src: Int, dst: Int) -> [ResizeCoeff] {
        precondition(src > 0 && dst > 0)

        let scale = Double(src) / Double(dst)
        var coeffs: [ResizeCoeff] = []
        coeffs.reserveCapacity(dst)

        func clampIndex(_ i: Int) -> Int {
            min(max(i, 0), src - 1)
        }

        for outIndex in 0..<dst {
            let inCoord = (Double(outIndex) + 0.5) * scale - 0.5
            let base = Int(floor(inCoord))
            let frac = inCoord - Double(base)

            let i0 = clampIndex(base - 1)
            let i1 = clampIndex(base)
            let i2 = clampIndex(base + 1)
            let i3 = clampIndex(base + 2)

            var w0 = cubicKernel(-1 - frac)
            var w1 = cubicKernel(-frac)
            var w2 = cubicKernel(1 - frac)
            var w3 = cubicKernel(2 - frac)

            let sum = w0 + w1 + w2 + w3
            if sum != 0 {
                w0 /= sum
                w1 /= sum
                w2 /= sum
                w3 /= sum
            }

            coeffs.append(ResizeCoeff(i0: i0, i1: i1, i2: i2, i3: i3, w0: w0, w1: w1, w2: w2, w3: w3))
        }

        return coeffs
    }

    /// Resize `RGBA8` input to an `RGB8` output using a deterministic CPU bicubic kernel.
    ///
    /// - Returns: `RGB8Image` where `data.count == dstWidth * dstHeight * 3`.
    public static func bicubicRGB(from rgba: RGBA8Image, toWidth dstWidth: Int, toHeight dstHeight: Int) throws
        -> RGB8Image
    {
        let srcWidth = rgba.width
        let srcHeight = rgba.height

        guard srcWidth > 0, srcHeight > 0, dstWidth > 0, dstHeight > 0 else {
            throw VisionResizeError.invalidDimensions(
                srcWidth: srcWidth,
                srcHeight: srcHeight,
                dstWidth: dstWidth,
                dstHeight: dstHeight
            )
        }

        let expectedBytes = srcWidth * srcHeight * 4
        guard rgba.data.count == expectedBytes else {
            throw VisionResizeError.invalidBufferSize(expected: expectedBytes, actual: rgba.data.count)
        }

        if srcWidth == dstWidth && srcHeight == dstHeight {
            var out = Data(count: dstWidth * dstHeight * 3)
            out.withUnsafeMutableBytes { outPtr in
                rgba.data.withUnsafeBytes { srcPtr in
                    guard let outBase = outPtr.bindMemory(to: UInt8.self).baseAddress,
                        let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress
                    else { return }

                    var dstIndex = 0
                    var srcIndex = 0
                    for _ in 0..<(srcWidth * srcHeight) {
                        outBase[dstIndex] = srcBase[srcIndex]
                        outBase[dstIndex + 1] = srcBase[srcIndex + 1]
                        outBase[dstIndex + 2] = srcBase[srcIndex + 2]
                        dstIndex += 3
                        srcIndex += 4
                    }
                }
            }
            return RGB8Image(data: out, width: dstWidth, height: dstHeight)
        }

        let xCoeffs = buildResizeCoeffs(src: srcWidth, dst: dstWidth)
        let yCoeffs = buildResizeCoeffs(src: srcHeight, dst: dstHeight)

        var out = Data(count: dstWidth * dstHeight * 3)

        try out.withUnsafeMutableBytes { outPtr in
            try rgba.data.withUnsafeBytes { srcPtr in
                guard let outBase = outPtr.bindMemory(to: UInt8.self).baseAddress,
                    let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress
                else {
                    throw VisionResizeError.invalidBufferSize(expected: expectedBytes, actual: rgba.data.count)
                }

                func readRGB(y: Int, x: Int) -> (Double, Double, Double) {
                    let idx = (y * srcWidth + x) * 4
                    return (
                        Double(srcBase[idx]),
                        Double(srcBase[idx + 1]),
                        Double(srcBase[idx + 2])
                    )
                }

                let rowElementCount = dstWidth * 3

                func horizontalResampleRow(_ srcY: Int, into dstRow: inout [Double]) {
                    var outIndex = 0
                    for xOut in 0..<dstWidth {
                        let c = xCoeffs[xOut]
                        let (r0, g0, b0) = readRGB(y: srcY, x: c.i0)
                        let (r1, g1, b1) = readRGB(y: srcY, x: c.i1)
                        let (r2, g2, b2) = readRGB(y: srcY, x: c.i2)
                        let (r3, g3, b3) = readRGB(y: srcY, x: c.i3)

                        dstRow[outIndex] = c.w0 * r0 + c.w1 * r1 + c.w2 * r2 + c.w3 * r3
                        dstRow[outIndex + 1] = c.w0 * g0 + c.w1 * g1 + c.w2 * g2 + c.w3 * g3
                        dstRow[outIndex + 2] = c.w0 * b0 + c.w1 * b1 + c.w2 * b2 + c.w3 * b3
                        outIndex += 3
                    }
                }

                func clampToByte(_ value: Double) -> UInt8 {
                    if value <= 0 { return 0 }
                    if value >= 255 { return 255 }
                    return UInt8(Int(value + 0.5))
                }

                let outBaseAddress = Int(bitPattern: outBase)
                let srcBaseAddress = Int(bitPattern: srcBase)

                let shouldParallelize =
                    (ProcessInfo.processInfo.activeProcessorCount >= 4
                        && (dstWidth * dstHeight) >= 1_000_000)

                if !shouldParallelize {
                    let rowCacheSize = 8
                    var rowCacheSourceY = Array(repeating: Int.min, count: rowCacheSize)
                    var rowCacheRows = Array(
                        repeating: [Double](repeating: 0, count: rowElementCount),
                        count: rowCacheSize
                    )
                    var rowCacheNextSlot = 0

                    @inline(__always)
                    func cachedHorizontalRowSlot(_ srcY: Int) -> Int {
                        for idx in 0..<rowCacheSize where rowCacheSourceY[idx] == srcY {
                            return idx
                        }

                        let slot = rowCacheNextSlot
                        rowCacheNextSlot = (rowCacheNextSlot + 1) % rowCacheSize
                        horizontalResampleRow(srcY, into: &rowCacheRows[slot])
                        rowCacheSourceY[slot] = srcY
                        return slot
                    }

                    for yOut in 0..<dstHeight {
                        let c = yCoeffs[yOut]
                        let row0Slot = cachedHorizontalRowSlot(c.i0)
                        let row1Slot = cachedHorizontalRowSlot(c.i1)
                        let row2Slot = cachedHorizontalRowSlot(c.i2)
                        let row3Slot = cachedHorizontalRowSlot(c.i3)

                        let rowOffset = yOut * rowElementCount
                        for i in 0..<rowElementCount {
                            let v =
                                c.w0 * rowCacheRows[row0Slot][i]
                                + c.w1 * rowCacheRows[row1Slot][i]
                                + c.w2 * rowCacheRows[row2Slot][i]
                                + c.w3 * rowCacheRows[row3Slot][i]
                            outBase[rowOffset + i] = clampToByte(v)
                        }
                    }
                } else {
                    let chunkHeight = 32
                    let chunkCount = (dstHeight + chunkHeight - 1) / chunkHeight

                    DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
                        guard let outBase = UnsafeMutablePointer<UInt8>(bitPattern: outBaseAddress),
                            let srcBase = UnsafePointer<UInt8>(bitPattern: srcBaseAddress)
                        else { return }

                        @inline(__always)
                        func readRGB(y: Int, x: Int) -> (Double, Double, Double) {
                            let idx = (y * srcWidth + x) * 4
                            return (
                                Double(srcBase[idx]),
                                Double(srcBase[idx + 1]),
                                Double(srcBase[idx + 2])
                            )
                        }

                        @inline(__always)
                        func horizontalResampleRow(_ srcY: Int, into dstRow: inout [Double]) {
                            var outIndex = 0
                            for xOut in 0..<dstWidth {
                                let c = xCoeffs[xOut]
                                let (r0, g0, b0) = readRGB(y: srcY, x: c.i0)
                                let (r1, g1, b1) = readRGB(y: srcY, x: c.i1)
                                let (r2, g2, b2) = readRGB(y: srcY, x: c.i2)
                                let (r3, g3, b3) = readRGB(y: srcY, x: c.i3)

                                dstRow[outIndex] = c.w0 * r0 + c.w1 * r1 + c.w2 * r2 + c.w3 * r3
                                dstRow[outIndex + 1] = c.w0 * g0 + c.w1 * g1 + c.w2 * g2 + c.w3 * g3
                                dstRow[outIndex + 2] = c.w0 * b0 + c.w1 * b1 + c.w2 * b2 + c.w3 * b3
                                outIndex += 3
                            }
                        }

                        @inline(__always)
                        func clampToByte(_ value: Double) -> UInt8 {
                            if value <= 0 { return 0 }
                            if value >= 255 { return 255 }
                            return UInt8(Int(value + 0.5))
                        }

                        let yStart = chunkIndex * chunkHeight
                        let yEnd = min(yStart + chunkHeight, dstHeight)
                        guard yStart < yEnd else { return }

                        let rowCacheSize = 8
                        var rowCacheSourceY = Array(repeating: Int.min, count: rowCacheSize)
                        var rowCacheRows = Array(
                            repeating: [Double](repeating: 0, count: rowElementCount),
                            count: rowCacheSize
                        )
                        var rowCacheNextSlot = 0

                        @inline(__always)
                        func cachedHorizontalRowSlot(_ srcY: Int) -> Int {
                            for idx in 0..<rowCacheSize where rowCacheSourceY[idx] == srcY {
                                return idx
                            }

                            let slot = rowCacheNextSlot
                            rowCacheNextSlot = (rowCacheNextSlot + 1) % rowCacheSize
                            horizontalResampleRow(srcY, into: &rowCacheRows[slot])
                            rowCacheSourceY[slot] = srcY
                            return slot
                        }

                        for yOut in yStart..<yEnd {
                            let c = yCoeffs[yOut]
                            let row0Slot = cachedHorizontalRowSlot(c.i0)
                            let row1Slot = cachedHorizontalRowSlot(c.i1)
                            let row2Slot = cachedHorizontalRowSlot(c.i2)
                            let row3Slot = cachedHorizontalRowSlot(c.i3)

                            let rowOffset = yOut * rowElementCount
                            for i in 0..<rowElementCount {
                                let v =
                                    c.w0 * rowCacheRows[row0Slot][i]
                                    + c.w1 * rowCacheRows[row1Slot][i]
                                    + c.w2 * rowCacheRows[row2Slot][i]
                                    + c.w3 * rowCacheRows[row3Slot][i]
                                outBase[rowOffset + i] = clampToByte(v)
                            }
                        }
                    }
                }
            }
        }

        return RGB8Image(data: out, width: dstWidth, height: dstHeight)
    }
}
