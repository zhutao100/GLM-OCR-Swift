import Foundation
import VLMRuntimeKit

public enum PPDocLayoutV3PostprocessError: Error, Sendable, Equatable {
    case invalidRawCounts(scores: Int, labels: Int, boxes: Int)
}

/// Deterministic PP-DocLayout-V3 post-processing helpers (NMS, containment merge, ordering).
public enum PPDocLayoutV3Postprocess {
    public enum MergeMode: String, Sendable, Codable, Equatable {
        case union
        case large
        case small
    }

    public struct UnclipRatio: Sendable, Equatable {
        public var widthRatio: Float
        public var heightRatio: Float

        public init(widthRatio: Float, heightRatio: Float) {
            self.widthRatio = widthRatio
            self.heightRatio = heightRatio
        }

        fileprivate var isIdentity: Bool { widthRatio == 1 && heightRatio == 1 }
    }

    public struct RawDetections: Sendable, Equatable {
        public var scores: [Float]
        public var labels: [Int]
        public var boxes: [OCRNormalizedBBox]
        public var orderSeq: [Int]?
        public var polygons: [[OCRNormalizedPoint]]?

        public init(
            scores: [Float],
            labels: [Int],
            boxes: [OCRNormalizedBBox],
            orderSeq: [Int]? = nil,
            polygons: [[OCRNormalizedPoint]]? = nil
        ) {
            self.scores = scores
            self.labels = labels
            self.boxes = boxes
            self.orderSeq = orderSeq
            self.polygons = polygons
        }
    }

    public struct Options: Sendable, Equatable {
        public var applyNMS: Bool
        public var iouSameClass: Float
        public var iouDifferentClass: Float
        public var mergeMode: MergeMode?
        public var mergeModeByClassID: [Int: MergeMode]?
        public var unclipRatio: UnclipRatio?
        public var unclipRatioByClassID: [Int: UnclipRatio]?

        public init(
            applyNMS: Bool = true,
            iouSameClass: Float = 0.6,
            iouDifferentClass: Float = 0.98,
            mergeMode: MergeMode? = nil,
            mergeModeByClassID: [Int: MergeMode]? = nil,
            unclipRatio: UnclipRatio? = nil,
            unclipRatioByClassID: [Int: UnclipRatio]? = nil
        ) {
            self.applyNMS = applyNMS
            self.iouSameClass = iouSameClass
            self.iouDifferentClass = iouDifferentClass
            self.mergeMode = mergeMode
            self.mergeModeByClassID = mergeModeByClassID
            self.unclipRatio = unclipRatio
            self.unclipRatioByClassID = unclipRatioByClassID
        }
    }

    public struct ProcessedRegion: Sendable, Equatable {
        public var index: Int
        public var classID: Int
        public var nativeLabel: String
        public var score: Float
        public var order: Int?
        public var taskType: LayoutTaskType
        public var bbox: OCRNormalizedBBox
        public var polygon: [OCRNormalizedPoint]

        public init(
            index: Int,
            classID: Int,
            nativeLabel: String,
            score: Float,
            order: Int?,
            taskType: LayoutTaskType,
            bbox: OCRNormalizedBBox,
            polygon: [OCRNormalizedPoint]
        ) {
            self.index = index
            self.classID = classID
            self.nativeLabel = nativeLabel
            self.score = score
            self.order = order
            self.taskType = taskType
            self.bbox = bbox
            self.polygon = polygon
        }
    }

    /// Default containment merge policy mirrored from the official `glmocr/config.yaml`
    /// (`pipeline.layout.layout_merge_bboxes_mode`).
    public static let defaultMergeModeByClassID: [Int: MergeMode] = [
        0: .large, // abstract
        1: .large, // algorithm
        2: .large, // aside_text
        3: .large, // chart
        4: .large, // content
        5: .large, // display_formula
        6: .large, // doc_title
        7: .large, // figure_title
        8: .large, // footer
        9: .large, // footer_image
        10: .large, // footnote
        11: .large, // formula_number
        12: .large, // header
        13: .large, // header_image
        14: .large, // image
        15: .large, // inline_formula
        16: .large, // number
        17: .large, // paragraph_title
        18: .small, // reference
        19: .large, // reference_content
        20: .large, // seal
        21: .large, // table
        22: .large, // text
        23: .large, // vertical_text
        24: .large, // vision_footnote
    ]

    /// Apply deterministic post-processing and return ordered regions + diagnostics notes.
    public static func apply(
        _ raw: RawDetections,
        config: PPDocLayoutV3Config,
        options: Options = .init()
    ) throws -> (regions: [ProcessedRegion], diagnostics: [String]) {
        let count = raw.scores.count
        guard raw.labels.count == count, raw.boxes.count == count else {
            throw PPDocLayoutV3PostprocessError.invalidRawCounts(
                scores: raw.scores.count,
                labels: raw.labels.count,
                boxes: raw.boxes.count
            )
        }

        var diagnostics: [String] = []
        var orderSeq: [Int]?
        if let seq = raw.orderSeq {
            if seq.count == count {
                orderSeq = seq
            } else {
                diagnostics.append("order_seq count mismatch; using fallback ordering")
            }
        }

        var polygons: [[OCRNormalizedPoint]]?
        if let polys = raw.polygons {
            if polys.count == count {
                polygons = polys
            } else {
                diagnostics.append("polygon count mismatch; falling back to bbox polygons")
            }
        }

        var detections: [Detection] = []
        detections.reserveCapacity(count)
        for i in 0 ..< count {
            detections.append(
                Detection(
                    classID: raw.labels[i],
                    score: raw.scores[i],
                    bbox: raw.boxes[i],
                    order: orderSeq?[i],
                    polygon: polygons?[i]
                )
            )
        }
        detections.removeAll { !isValidNormalizedBBox($0.bbox) }

        if options.applyNMS {
            detections = nms(detections, iouSameClass: options.iouSameClass, iouDifferentClass: options.iouDifferentClass)
        }

        let preserveClassIDs = preserveIndices(id2label: config.id2label)

        if let mergeModeByClassID = options.mergeModeByClassID {
            detections = applyContainmentMergeByClass(
                detections,
                preserveClassIDs: preserveClassIDs,
                mergeModeByClassID: mergeModeByClassID
            )
        } else if let mergeMode = options.mergeMode {
            detections = applyContainmentMergeGlobal(
                detections,
                preserveClassIDs: preserveClassIDs,
                mode: mergeMode
            )
        }

        if orderSeq != nil {
            detections.sort {
                let a = $0.order ?? 0
                let b = $1.order ?? 0
                if a != b { return a < b }
                return fallbackSortKey($0.bbox) < fallbackSortKey($1.bbox)
            }
        } else {
            diagnostics.append("order_seq missing; using (y1, x1) fallback ordering")
            detections.sort { fallbackSortKey($0.bbox) < fallbackSortKey($1.bbox) }
        }

        let unclipApplied: Set<Int> = {
            var applied: Set<Int> = []
            for det in detections {
                if let ratio = ratio(for: det, options: options), !ratio.isIdentity {
                    applied.insert(det.classID)
                }
            }
            return applied
        }()

        if !unclipApplied.isEmpty {
            for idx in detections.indices {
                guard let ratio = ratio(for: detections[idx], options: options), !ratio.isIdentity else { continue }
                detections[idx].bbox = unclipBBox(detections[idx].bbox, ratio: ratio)
                detections[idx].polygon = nil
            }
        }

        var regions: [ProcessedRegion] = []
        regions.reserveCapacity(detections.count)

        for det in detections {
            let bbox = clampNormalizedBBox(det.bbox)
            guard isValidNormalizedBBox(bbox) else { continue }

            let label = config.id2label[det.classID] ?? "class_\(det.classID)"
            let taskType = PPDocLayoutV3Mappings.labelTaskMapping[label] ?? .abandon
            let orderValue: Int? = if let o = det.order, o > 0 { o } else { nil }

            let polygon: [OCRNormalizedPoint] = if let poly = det.polygon, poly.count >= 3 {
                poly.map { clampNormalizedPoint($0) }
            } else {
                bboxPolygon(bbox)
            }

            regions.append(
                ProcessedRegion(
                    index: regions.count,
                    classID: det.classID,
                    nativeLabel: label,
                    score: det.score,
                    order: orderValue,
                    taskType: taskType,
                    bbox: bbox,
                    polygon: polygon
                )
            )
        }

        return (regions, diagnostics)
    }
}

private struct Detection: Sendable, Equatable {
    var classID: Int
    var score: Float
    var bbox: OCRNormalizedBBox
    var order: Int?
    var polygon: [OCRNormalizedPoint]?
}

private func nms(_ detections: [Detection], iouSameClass: Float, iouDifferentClass: Float) -> [Detection] {
    let indices = detections.indices.sorted { detections[$0].score > detections[$1].score }
    var remaining = indices
    var selected: [Detection] = []
    selected.reserveCapacity(detections.count)

    while let currentIndex = remaining.first {
        let current = detections[currentIndex]
        selected.append(current)
        remaining.removeFirst()

        remaining.removeAll { idx in
            let other = detections[idx]
            let value = iou(current.bbox, other.bbox)
            let threshold = (current.classID == other.classID) ? iouSameClass : iouDifferentClass
            return value >= threshold
        }
    }

    return selected
}

private func iou(_ a: OCRNormalizedBBox, _ b: OCRNormalizedBBox) -> Float {
    let ax1 = Float(a.x1), ay1 = Float(a.y1), ax2 = Float(a.x2), ay2 = Float(a.y2)
    let bx1 = Float(b.x1), by1 = Float(b.y1), bx2 = Float(b.x2), by2 = Float(b.y2)

    let x1 = max(ax1, bx1)
    let y1 = max(ay1, by1)
    let x2 = min(ax2, bx2)
    let y2 = min(ay2, by2)

    let interW = max(0, x2 - x1 + 1)
    let interH = max(0, y2 - y1 + 1)
    let interArea = interW * interH

    let aArea = max(0, ax2 - ax1 + 1) * max(0, ay2 - ay1 + 1)
    let bArea = max(0, bx2 - bx1 + 1) * max(0, by2 - by1 + 1)
    let denom = aArea + bArea - interArea
    return denom > 0 ? interArea / denom : 0
}

private func preserveIndices(id2label: [Int: String]) -> Set<Int> {
    let preserveLabels: Set<String> = ["image", "seal", "chart"]
    return Set(id2label.compactMap { preserveLabels.contains($0.value) ? $0.key : nil })
}

private func applyContainmentMergeGlobal(_ detections: [Detection], preserveClassIDs: Set<Int>, mode: PPDocLayoutV3Postprocess.MergeMode) -> [Detection] {
    guard detections.count > 1 else { return detections }
    guard mode != .union else { return detections }

    let (containsOther, containedByOther) = checkContainment(detections, preserveClassIDs: preserveClassIDs)
    switch mode {
    case .union:
        return detections
    case .large:
        return zip(detections.indices, detections)
            .filter { !containedByOther[$0.0] }
            .map(\.1)
    case .small:
        return zip(detections.indices, detections)
            .filter { !containsOther[$0.0] || containedByOther[$0.0] }
            .map(\.1)
    }
}

private func applyContainmentMergeByClass(
    _ detections: [Detection],
    preserveClassIDs: Set<Int>,
    mergeModeByClassID: [Int: PPDocLayoutV3Postprocess.MergeMode]
) -> [Detection] {
    guard detections.count > 1 else { return detections }
    var keepMask = Array(repeating: true, count: detections.count)

    for (categoryID, mode) in mergeModeByClassID.sorted(by: { $0.key < $1.key }) {
        guard mode != .union else { continue }
        let (containsOther, containedByOther) = checkContainment(
            detections,
            preserveClassIDs: preserveClassIDs,
            categoryID: categoryID,
            mode: mode
        )
        for i in keepMask.indices {
            switch mode {
            case .union:
                continue
            case .large:
                keepMask[i] = keepMask[i] && !containedByOther[i]
            case .small:
                keepMask[i] = keepMask[i] && (!containsOther[i] || containedByOther[i])
            }
        }
    }

    return zip(keepMask, detections).compactMap { $0.0 ? $0.1 : nil }
}

private func checkContainment(
    _ detections: [Detection],
    preserveClassIDs: Set<Int>,
    categoryID: Int? = nil,
    mode: PPDocLayoutV3Postprocess.MergeMode? = nil
) -> (containsOther: [Bool], containedByOther: [Bool]) {
    let n = detections.count
    var containsOther = Array(repeating: false, count: n)
    var containedByOther = Array(repeating: false, count: n)

    for i in 0 ..< n {
        for j in 0 ..< n {
            if i == j { continue }
            if preserveClassIDs.contains(detections[i].classID) { continue }

            if let categoryID, let mode {
                if mode == .large, detections[j].classID == categoryID {
                    if isContained(detections[i].bbox, in: detections[j].bbox) {
                        containedByOther[i] = true
                        containsOther[j] = true
                    }
                } else if mode == .small, detections[i].classID == categoryID {
                    if isContained(detections[i].bbox, in: detections[j].bbox) {
                        containedByOther[i] = true
                        containsOther[j] = true
                    }
                }
            } else {
                if isContained(detections[i].bbox, in: detections[j].bbox) {
                    containedByOther[i] = true
                    containsOther[j] = true
                }
            }
        }
    }

    return (containsOther, containedByOther)
}

private func isContained(_ box: OCRNormalizedBBox, in container: OCRNormalizedBBox) -> Bool {
    let x1 = Float(box.x1), y1 = Float(box.y1), x2 = Float(box.x2), y2 = Float(box.y2)
    let X1 = Float(container.x1), Y1 = Float(container.y1), X2 = Float(container.x2), Y2 = Float(container.y2)

    let boxArea = max(0, x2 - x1) * max(0, y2 - y1)
    guard boxArea > 0 else { return false }

    let xi1 = max(x1, X1)
    let yi1 = max(y1, Y1)
    let xi2 = min(x2, X2)
    let yi2 = min(y2, Y2)

    let interW = max(0, xi2 - xi1)
    let interH = max(0, yi2 - yi1)
    let interArea = interW * interH
    let ratio = interArea / boxArea
    return ratio >= 0.8
}

// swiftlint:disable:next large_tuple
private func fallbackSortKey(_ bbox: OCRNormalizedBBox) -> (Int, Int, Int, Int) {
    (bbox.y1, bbox.x1, bbox.y2, bbox.x2)
}

private func ratio(for det: Detection, options: PPDocLayoutV3Postprocess.Options) -> PPDocLayoutV3Postprocess.UnclipRatio? {
    if let ratios = options.unclipRatioByClassID, let ratio = ratios[det.classID] { return ratio }
    return options.unclipRatio
}

private func unclipBBox(_ bbox: OCRNormalizedBBox, ratio: PPDocLayoutV3Postprocess.UnclipRatio) -> OCRNormalizedBBox {
    let x1 = Float(bbox.x1), y1 = Float(bbox.y1), x2 = Float(bbox.x2), y2 = Float(bbox.y2)
    let width = x2 - x1
    let height = y2 - y1
    guard width > 0, height > 0 else { return bbox }

    let newW = width * ratio.widthRatio
    let newH = height * ratio.heightRatio
    let centerX = x1 + width / 2
    let centerY = y1 + height / 2

    let nx1 = centerX - newW / 2
    let ny1 = centerY - newH / 2
    let nx2 = centerX + newW / 2
    let ny2 = centerY + newH / 2

    return OCRNormalizedBBox(
        x1: Int(max(0, min(1000, nx1)).rounded(.down)),
        y1: Int(max(0, min(1000, ny1)).rounded(.down)),
        x2: Int(max(0, min(1000, nx2)).rounded(.down)),
        y2: Int(max(0, min(1000, ny2)).rounded(.down))
    )
}

private func isValidNormalizedBBox(_ bbox: OCRNormalizedBBox) -> Bool {
    let range = 0 ... 1000
    guard range.contains(bbox.x1), range.contains(bbox.y1), range.contains(bbox.x2), range.contains(bbox.y2) else {
        return false
    }
    guard bbox.x1 < bbox.x2, bbox.y1 < bbox.y2 else {
        return false
    }
    return true
}

private func clampNormalizedBBox(_ bbox: OCRNormalizedBBox) -> OCRNormalizedBBox {
    OCRNormalizedBBox(
        x1: max(0, min(1000, bbox.x1)),
        y1: max(0, min(1000, bbox.y1)),
        x2: max(0, min(1000, bbox.x2)),
        y2: max(0, min(1000, bbox.y2))
    )
}

private func clampNormalizedPoint(_ p: OCRNormalizedPoint) -> OCRNormalizedPoint {
    OCRNormalizedPoint(
        x: max(0, min(1000, p.x)),
        y: max(0, min(1000, p.y))
    )
}

private func bboxPolygon(_ bbox: OCRNormalizedBBox) -> [OCRNormalizedPoint] {
    [
        OCRNormalizedPoint(x: bbox.x1, y: bbox.y1),
        OCRNormalizedPoint(x: bbox.x2, y: bbox.y1),
        OCRNormalizedPoint(x: bbox.x2, y: bbox.y2),
        OCRNormalizedPoint(x: bbox.x1, y: bbox.y2),
    ]
}
