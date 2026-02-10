import DocLayoutAdapter
import VLMRuntimeKit
import XCTest

final class PPDocLayoutPostprocessTests: XCTestCase {
    func testNMS_sameClassSuppressesOverlaps() throws {
        let config = makeConfig()
        let raw = PPDocLayoutV3Postprocess.RawDetections(
            scores: [0.9, 0.8],
            labels: [22, 22], // text
            boxes: [
                OCRNormalizedBBox(x1: 0, y1: 0, x2: 500, y2: 500),
                OCRNormalizedBBox(x1: 50, y1: 50, x2: 550, y2: 550),
            ],
            orderSeq: [1, 2]
        )

        let (regions, _) = try PPDocLayoutV3Postprocess.apply(
            raw,
            config: config,
            options: .init(applyNMS: true, mergeMode: nil, mergeModeByClassID: nil)
        )

        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].classID, 22)
        XCTAssertEqual(regions[0].bbox, OCRNormalizedBBox(x1: 0, y1: 0, x2: 500, y2: 500))
        XCTAssertEqual(regions[0].index, 0)
    }

    func testNMS_differentClassesKeepsOverlapsBelowDiffThreshold() throws {
        let config = makeConfig()
        let raw = PPDocLayoutV3Postprocess.RawDetections(
            scores: [0.9, 0.8],
            labels: [22, 21], // text vs table
            boxes: [
                OCRNormalizedBBox(x1: 0, y1: 0, x2: 500, y2: 500),
                OCRNormalizedBBox(x1: 50, y1: 50, x2: 550, y2: 550),
            ],
            orderSeq: [1, 2]
        )

        let (regions, _) = try PPDocLayoutV3Postprocess.apply(
            raw,
            config: config,
            options: .init(applyNMS: true, mergeMode: nil, mergeModeByClassID: nil)
        )

        XCTAssertEqual(regions.count, 2)
    }

    func testContainmentMerge_globalLargeKeepsContainerDropsContained() throws {
        let config = makeConfig()
        let raw = PPDocLayoutV3Postprocess.RawDetections(
            scores: [0.5, 0.6],
            labels: [22, 21],
            boxes: [
                OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 1000), // container
                OCRNormalizedBBox(x1: 100, y1: 100, x2: 200, y2: 200), // contained
            ],
            orderSeq: [1, 2]
        )

        let (regions, _) = try PPDocLayoutV3Postprocess.apply(
            raw,
            config: config,
            options: .init(applyNMS: false, mergeMode: .large, mergeModeByClassID: nil)
        )

        XCTAssertEqual(regions.map(\.bbox), [OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 1000)])
    }

    func testContainmentMerge_globalSmallKeepsContainedDropsContainer() throws {
        let config = makeConfig()
        let raw = PPDocLayoutV3Postprocess.RawDetections(
            scores: [0.5, 0.6],
            labels: [22, 21],
            boxes: [
                OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 1000), // container
                OCRNormalizedBBox(x1: 100, y1: 100, x2: 200, y2: 200), // contained
            ],
            orderSeq: [1, 2]
        )

        let (regions, _) = try PPDocLayoutV3Postprocess.apply(
            raw,
            config: config,
            options: .init(applyNMS: false, mergeMode: .small, mergeModeByClassID: nil)
        )

        XCTAssertEqual(regions.map(\.bbox), [OCRNormalizedBBox(x1: 100, y1: 100, x2: 200, y2: 200)])
    }

    func testContainmentMerge_perClassLargeRemovesBoxesContainedByThatClass() throws {
        let config = makeConfig()
        let raw = PPDocLayoutV3Postprocess.RawDetections(
            scores: [0.5, 0.6],
            labels: [22, 21],
            boxes: [
                OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 1000), // container (class 22)
                OCRNormalizedBBox(x1: 100, y1: 100, x2: 200, y2: 200), // contained
            ]
        )

        let (regions, _) = try PPDocLayoutV3Postprocess.apply(
            raw,
            config: config,
            options: .init(
                applyNMS: false,
                mergeMode: nil,
                mergeModeByClassID: [22: .large]
            )
        )

        XCTAssertEqual(regions.map(\.classID), [22])
    }

    func testContainmentMerge_perClassSmallDropsBoxesThatContainThatClass() throws {
        let config = makeConfig()
        let raw = PPDocLayoutV3Postprocess.RawDetections(
            scores: [0.5, 0.6],
            labels: [22, 21],
            boxes: [
                OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 1000), // container
                OCRNormalizedBBox(x1: 100, y1: 100, x2: 200, y2: 200), // contained (class 21)
            ]
        )

        let (regions, _) = try PPDocLayoutV3Postprocess.apply(
            raw,
            config: config,
            options: .init(
                applyNMS: false,
                mergeMode: nil,
                mergeModeByClassID: [21: .small]
            )
        )

        XCTAssertEqual(regions.map(\.classID), [21])
    }

    func testContainmentMerge_preserveLabelsAreNotRemovedWhenContained() throws {
        let config = makeConfig()
        let raw = PPDocLayoutV3Postprocess.RawDetections(
            scores: [0.9, 0.8],
            labels: [22, 14], // text container, image contained
            boxes: [
                OCRNormalizedBBox(x1: 0, y1: 0, x2: 1000, y2: 1000),
                OCRNormalizedBBox(x1: 100, y1: 100, x2: 200, y2: 200),
            ],
            orderSeq: [1, 2]
        )

        let (regions, _) = try PPDocLayoutV3Postprocess.apply(
            raw,
            config: config,
            options: .init(applyNMS: false, mergeMode: .large, mergeModeByClassID: nil)
        )

        XCTAssertEqual(Set(regions.map(\.classID)), Set([22, 14]))
    }

    func testOrdering_prefersOrderSeqWhenPresent() throws {
        let config = makeConfig()
        let raw = PPDocLayoutV3Postprocess.RawDetections(
            scores: [0.1, 0.1, 0.1],
            labels: [22, 21, 14],
            boxes: [
                OCRNormalizedBBox(x1: 0, y1: 0, x2: 10, y2: 10),
                OCRNormalizedBBox(x1: 0, y1: 0, x2: 10, y2: 10),
                OCRNormalizedBBox(x1: 0, y1: 0, x2: 10, y2: 10),
            ],
            orderSeq: [10, 1, 5]
        )

        let (regions, _) = try PPDocLayoutV3Postprocess.apply(
            raw,
            config: config,
            options: .init(applyNMS: false, mergeMode: nil, mergeModeByClassID: nil)
        )

        XCTAssertEqual(regions.map(\.classID), [21, 14, 22])
    }

    func testOrdering_fallsBackToReadingOrderWhenOrderSeqMissing() throws {
        let config = makeConfig()
        let raw = PPDocLayoutV3Postprocess.RawDetections(
            scores: [0.1, 0.1, 0.1],
            labels: [22, 21, 14],
            boxes: [
                OCRNormalizedBBox(x1: 50, y1: 100, x2: 60, y2: 110), // y=100
                OCRNormalizedBBox(x1: 100, y1: 50, x2: 110, y2: 60), // y=50, x=100
                OCRNormalizedBBox(x1: 10, y1: 50, x2: 20, y2: 60), // y=50, x=10
            ],
            orderSeq: nil
        )

        let (regions, diagnostics) = try PPDocLayoutV3Postprocess.apply(
            raw,
            config: config,
            options: .init(applyNMS: false, mergeMode: nil, mergeModeByClassID: nil)
        )

        XCTAssertEqual(regions.map(\.classID), [14, 21, 22])
        XCTAssertTrue(diagnostics.contains(where: { $0.contains("order_seq missing") }))
    }

    private func makeConfig() -> PPDocLayoutV3Config {
        PPDocLayoutV3Config(
            modelType: "ppdoclayoutv3",
            numLabels: 25,
            id2label: [
                3: "chart",
                14: "image",
                20: "seal",
                21: "table",
                22: "text",
            ],
            label2id: [
                "chart": 3,
                "image": 14,
                "seal": 20,
                "table": 21,
                "text": 22,
            ]
        )
    }
}
