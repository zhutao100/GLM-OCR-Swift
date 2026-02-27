import Foundation

public enum PDFPagesSpec: Sendable, Equatable {
    case all
    /// 1-based ranges, normalized + merged.
    case explicit([ClosedRange<Int>])
}

public enum PDFPagesSpecError: Error, Sendable, Equatable {
    case emptyToken
    case couldNotParseToken(String)
    case invalidBrackets(String)
    case mixedAllWithExplicit
    case invalidPageCount(Int)
    case pageMustBeAtLeast1(Int)
    case rangeStartAfterEnd(start: Int, end: Int)
    case pageOutOfRange(page: Int, pageCount: Int)
}

extension PDFPagesSpecError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyToken:
            "empty token"
        case .couldNotParseToken(let token):
            "could not parse token '\(token)'"
        case .invalidBrackets(let token):
            "invalid brackets in token '\(token)'"
        case .mixedAllWithExplicit:
            "cannot mix 'all' with explicit page selections"
        case .invalidPageCount(let value):
            "invalid PDF page count \(value)"
        case .pageMustBeAtLeast1(let value):
            "page must be >= 1 (got \(value))"
        case .rangeStartAfterEnd(let start, let end):
            "range start must be <= end (got \(start)-\(end))"
        case .pageOutOfRange(let page, let pageCount):
            "page \(page) is out of range (pageCount=\(pageCount))"
        }
    }
}

extension PDFPagesSpec {
    /// Parse a fuzzy CLI/App pages spec.
    ///
    /// Examples:
    /// - nil / "" → `.all`
    /// - "all" → `.all`
    /// - "1" → `.explicit([1...1])`
    /// - "1-3" / "[1-3]" → `.explicit([1...3])`
    /// - "1, [3-5], 9" → `.explicit([1...1, 3...5, 9...9])` (normalized + merged)
    public static func parse(_ raw: String?) throws -> PDFPagesSpec {
        guard let raw else { return .all }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .all }

        if trimmed.compare("all", options: [.caseInsensitive]) == .orderedSame {
            return .all
        }

        let tokenSubs = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        var ranges: [ClosedRange<Int>] = []
        ranges.reserveCapacity(tokenSubs.count)

        var sawAll = false
        var sawExplicit = false

        for tokenSub in tokenSubs {
            let token = tokenSub.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw PDFPagesSpecError.emptyToken }

            if token.compare("all", options: [.caseInsensitive]) == .orderedSame {
                sawAll = true
                continue
            }

            sawExplicit = true

            let inner = try unwrappingBracketsIfPresent(token)
            let parsed = try parseRangeOrSingle(inner, originalToken: token)
            ranges.append(parsed)
        }

        if sawAll, sawExplicit {
            throw PDFPagesSpecError.mixedAllWithExplicit
        }
        if sawAll {
            return .all
        }

        return try .explicit(normalizeAndMerge(ranges))
    }

    /// Resolve to a deduped, ascending list of 1-based page indices.
    public func resolve(pageCount: Int) throws -> [Int] {
        guard pageCount >= 1 else { throw PDFPagesSpecError.invalidPageCount(pageCount) }

        switch self {
        case .all:
            return Array(1...pageCount)
        case .explicit(let ranges):
            var pages: [Int] = []
            pages.reserveCapacity(ranges.reduce(0) { $0 + ($1.count) })

            for range in ranges {
                guard range.lowerBound >= 1 else {
                    throw PDFPagesSpecError.pageMustBeAtLeast1(range.lowerBound)
                }
                guard range.upperBound <= pageCount else {
                    throw PDFPagesSpecError.pageOutOfRange(page: range.upperBound, pageCount: pageCount)
                }
                pages.append(contentsOf: range)
            }
            return pages
        }
    }
}

private func unwrappingBracketsIfPresent(_ token: String) throws -> String {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("[") || trimmed.hasSuffix("]") else { return trimmed }

    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 else {
        throw PDFPagesSpecError.invalidBrackets(token)
    }

    return trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
}

private func parseRangeOrSingle(_ raw: String, originalToken: String) throws -> ClosedRange<Int> {
    let cleaned = raw.filter { !$0.isWhitespace }
    let parts = cleaned.split(separator: "-", omittingEmptySubsequences: false)

    func parseInt(_ substring: Substring) throws -> Int {
        guard !substring.isEmpty, let value = Int(substring) else {
            throw PDFPagesSpecError.couldNotParseToken(originalToken)
        }
        return value
    }

    switch parts.count {
    case 1:
        let value = try parseInt(parts[0])
        guard value >= 1 else { throw PDFPagesSpecError.pageMustBeAtLeast1(value) }
        return value...value
    case 2:
        let start = try parseInt(parts[0])
        let end = try parseInt(parts[1])
        guard start >= 1 else { throw PDFPagesSpecError.pageMustBeAtLeast1(start) }
        guard end >= 1 else { throw PDFPagesSpecError.pageMustBeAtLeast1(end) }
        guard start <= end else { throw PDFPagesSpecError.rangeStartAfterEnd(start: start, end: end) }
        return start...end
    default:
        throw PDFPagesSpecError.couldNotParseToken(originalToken)
    }
}

private func normalizeAndMerge(_ ranges: [ClosedRange<Int>]) throws -> [ClosedRange<Int>] {
    guard !ranges.isEmpty else { throw PDFPagesSpecError.emptyToken }

    let sorted = ranges.sorted { lhs, rhs in
        if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound < rhs.lowerBound }
        return lhs.upperBound < rhs.upperBound
    }

    var merged: [ClosedRange<Int>] = []
    merged.reserveCapacity(sorted.count)

    for range in sorted {
        guard range.lowerBound >= 1 else { throw PDFPagesSpecError.pageMustBeAtLeast1(range.lowerBound) }
        guard range.upperBound >= 1 else { throw PDFPagesSpecError.pageMustBeAtLeast1(range.upperBound) }

        if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
            merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
        } else {
            merged.append(range)
        }
    }

    return merged
}
