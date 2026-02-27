import VLMRuntimeKit
import XCTest

final class PDFPagesSpecTests: XCTestCase {
    func testParse_nil_meansAll() throws {
        XCTAssertEqual(try PDFPagesSpec.parse(nil), .all)
    }

    func testParse_empty_meansAll() throws {
        XCTAssertEqual(try PDFPagesSpec.parse(""), .all)
        XCTAssertEqual(try PDFPagesSpec.parse("   "), .all)
    }

    func testParse_all_caseInsensitive() throws {
        XCTAssertEqual(try PDFPagesSpec.parse("all"), .all)
        XCTAssertEqual(try PDFPagesSpec.parse("ALL"), .all)
        XCTAssertEqual(try PDFPagesSpec.parse(" All "), .all)
    }

    func testParse_singlePage() throws {
        XCTAssertEqual(try PDFPagesSpec.parse("1"), .explicit([1...1]))
    }

    func testParse_range() throws {
        XCTAssertEqual(try PDFPagesSpec.parse("1-3"), .explicit([1...3]))
        XCTAssertEqual(try PDFPagesSpec.parse("[1-3]"), .explicit([1...3]))
        XCTAssertEqual(try PDFPagesSpec.parse(" [ 1 - 3 ] "), .explicit([1...3]))
    }

    func testParse_list_normalizesAndMerges() throws {
        XCTAssertEqual(try PDFPagesSpec.parse("1,2,4"), .explicit([1...2, 4...4]))
        XCTAssertEqual(try PDFPagesSpec.parse("3,1,2"), .explicit([1...3]))
        XCTAssertEqual(try PDFPagesSpec.parse("1, [3-5], 9"), .explicit([1...1, 3...5, 9...9]))
        XCTAssertEqual(try PDFPagesSpec.parse("1, [3 - 5], 9"), .explicit([1...1, 3...5, 9...9]))
        XCTAssertEqual(try PDFPagesSpec.parse("1,1,2"), .explicit([1...2]))
    }

    func testParse_mixingAllWithExplicit_throws() throws {
        XCTAssertThrowsError(try PDFPagesSpec.parse("all,1")) { error in
            XCTAssertEqual(error as? PDFPagesSpecError, .mixedAllWithExplicit)
        }
        XCTAssertThrowsError(try PDFPagesSpec.parse("1,all")) { error in
            XCTAssertEqual(error as? PDFPagesSpecError, .mixedAllWithExplicit)
        }
    }

    func testParse_invalidTokens_throw() throws {
        XCTAssertThrowsError(try PDFPagesSpec.parse("abc")) { error in
            XCTAssertEqual(error as? PDFPagesSpecError, .couldNotParseToken("abc"))
        }

        XCTAssertThrowsError(try PDFPagesSpec.parse("3-1")) { error in
            XCTAssertEqual(error as? PDFPagesSpecError, .rangeStartAfterEnd(start: 3, end: 1))
        }

        XCTAssertThrowsError(try PDFPagesSpec.parse("0")) { error in
            XCTAssertEqual(error as? PDFPagesSpecError, .pageMustBeAtLeast1(0))
        }
    }

    func testResolve_all() throws {
        XCTAssertEqual(try PDFPagesSpec.all.resolve(pageCount: 3), [1, 2, 3])
    }

    func testResolve_explicit() throws {
        let spec = try PDFPagesSpec.parse("2-3")
        XCTAssertEqual(try spec.resolve(pageCount: 3), [2, 3])
    }

    func testResolve_outOfRange_throws() throws {
        let spec = try PDFPagesSpec.parse("3")
        XCTAssertThrowsError(try spec.resolve(pageCount: 2)) { error in
            XCTAssertEqual(error as? PDFPagesSpecError, .pageOutOfRange(page: 3, pageCount: 2))
        }
    }
}
