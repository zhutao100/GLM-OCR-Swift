import Foundation
import VLMRuntimeKit

/// Layout-mode result formatter.
///
/// Ports the observable formatting/merge behaviors of the official GLM-OCR `ResultFormatter`
/// (`glmocr/postprocess/result_formatter.py`) into deterministic Swift helpers.
public enum LayoutResultFormatter {
    public static func format(pages: [OCRPage]) -> (document: OCRDocument, markdown: String) {
        let sortedPages = pages.sorted { $0.index < $1.index }

        var formattedPages: [OCRPage] = []
        formattedPages.reserveCapacity(sortedPages.count)

        var markdownPages: [String] = []
        markdownPages.reserveCapacity(sortedPages.count)

        for page in sortedPages {
            let formattedRegions = formatRegions(page.regions)
            let formattedPage = OCRPage(index: page.index, regions: formattedRegions)
            formattedPages.append(formattedPage)
            markdownPages.append(renderMarkdown(for: formattedPage))
        }

        return (OCRDocument(pages: formattedPages), markdownPages.joined(separator: "\n\n"))
    }

    private static func formatRegions(_ regions: [OCRRegion]) -> [OCRRegion] {
        let sortedRegions = regions.enumerated().sorted {
            if $0.element.index != $1.element.index { return $0.element.index < $1.element.index }
            return $0.offset < $1.offset
        }.map(\.element)

        var formatted: [OCRRegion] = []
        formatted.reserveCapacity(sortedRegions.count)

        for region in sortedRegions {
            var region = region
            region.kind = PPDocLayoutV3Mappings.labelToVisualizationKind[region.nativeLabel] ?? .unknown
            region.content = formatContent(region.content, kind: region.kind, nativeLabel: region.nativeLabel)

            if let content = region.content, content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            region.index = formatted.count
            formatted.append(region)
        }

        formatted = mergeFormulaNumbers(formatted)
        formatted = mergeHyphenatedTextBlocks(formatted)
        formatted = formatBulletPoints(formatted)

        return formatted
    }

    private static func renderMarkdown(for page: OCRPage) -> String {
        var blocks: [String] = []
        blocks.reserveCapacity(page.regions.count)

        for region in page.regions {
            if region.kind == .image {
                blocks.append(imagePlaceholder(pageIndex: page.index, bbox: region.bbox))
            } else if let content = region.content, !content.isEmpty {
                blocks.append(content)
            }
        }

        return blocks.joined(separator: "\n\n")
    }

    private static func imagePlaceholder(pageIndex: Int, bbox: OCRNormalizedBBox) -> String {
        "![](page=\(pageIndex),bbox=[\(bbox.x1),\(bbox.y1),\(bbox.x2),\(bbox.y2)])"
    }

    // MARK: - Content formatting

    private static func formatContent(_ content: String?, kind: OCRRegionKind, nativeLabel: String) -> String? {
        guard let content else { return nil }
        var output = cleanContent(content)

        if nativeLabel == "doc_title" {
            output = "# " + strippingLeadingHashes(output)
        } else if nativeLabel == "paragraph_title" {
            if output.hasPrefix("- ") || output.hasPrefix("* ") {
                output = trimmingLeadingWhitespace(String(output.dropFirst(2)))
            }
            output = "## " + trimmingLeadingWhitespace(strippingLeadingHashes(output))
        }

        if kind == .formula {
            output = formatFormula(output)
        }

        if kind == .text {
            output = formatText(output)
        }

        return output
    }

    private static func cleanContent(_ content: String) -> String {
        var output = content

        while output.hasPrefix("\\t") {
            output = String(output.dropFirst(2))
        }
        output = trimmingLeadingWhitespace(output)

        while output.hasSuffix("\\t") {
            output = String(output.dropLast(2))
        }
        output = trimmingTrailingWhitespace(output)

        output = limitRepeats(in: output, character: ".", maxRepeats: 3)
        output = limitRepeats(in: output, character: "·", maxRepeats: 3)
        output = limitRepeats(in: output, character: "_", maxRepeats: 3)
        output = limitRepeatsOfEscapedUnderscore(output, maxRepeats: 3)

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingLeadingHashes(_ content: String) -> String {
        var idx = content.startIndex
        while idx < content.endIndex, content[idx] == "#" {
            idx = content.index(after: idx)
        }
        while idx < content.endIndex, content[idx].isWhitespace {
            idx = content.index(after: idx)
        }
        return String(content[idx...])
    }

    private static func formatFormula(_ content: String) -> String {
        let stripped = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if stripped.hasPrefix("$$"), stripped.hasSuffix("$$"), stripped.count >= 4 {
            let inner = stripped.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
            return "$$\n" + inner + "\n$$"
        }

        if stripped.hasPrefix("\\["), stripped.hasSuffix("\\]"), stripped.count >= 4 {
            let inner = stripped.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
            return "$$\n" + inner + "\n$$"
        }

        if stripped.hasPrefix("\\("), stripped.hasSuffix("\\)"), stripped.count >= 4 {
            let inner = stripped.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
            return "$$\n" + inner + "\n$$"
        }

        return "$$\n" + stripped + "\n$$"
    }

    private static func formatText(_ content: String) -> String {
        var output = content

        if output.hasPrefix("·") || output.hasPrefix("•") || output.hasPrefix("* ") {
            let rest = trimmingLeadingWhitespace(String(output.dropFirst(1)))
            output = "- " + rest
        }

        if let (symbol, rest) = parseParenListPrefix(output) {
            output = "(\(symbol)) " + trimmingLeadingWhitespace(rest)
        } else if let (symbol, sep, rest) = parseNumberedListPrefix(output) {
            output = symbol + sep + " " + trimmingLeadingWhitespace(rest)
        }

        output = replacingSingleNewlinesWithDoubleNewlines(output)

        return output
    }

    private static func parseParenListPrefix(_ content: String) -> (symbol: String, rest: String)? {
        guard let first = content.first, first == "(" || first == "（" else { return nil }
        let afterOpen = content.index(after: content.startIndex)
        guard afterOpen < content.endIndex else { return nil }

        let symbolAndEnd = parseSymbol(content, from: afterOpen)
        guard let symbolAndEnd else { return nil }

        let (symbol, symbolEnd) = symbolAndEnd
        guard symbolEnd < content.endIndex else { return nil }
        let close = content[symbolEnd]
        guard close == ")" || close == "）" else { return nil }

        let restStart = content.index(after: symbolEnd)
        return (symbol, String(content[restStart...]))
    }

    private static func parseNumberedListPrefix(_ content: String) -> (symbol: String, sep: String, rest: String)? {
        guard let first = content.first else { return nil }
        let symbolAndEnd: (String, String.Index)?

        let afterFirst = content.index(after: content.startIndex)
        if first.isASCIIAlpha {
            symbolAndEnd = (String(first), afterFirst)
        } else if first.isDigit {
            symbolAndEnd = parseDigits(content, from: content.startIndex)
        } else {
            symbolAndEnd = nil
        }

        guard let (symbol, symbolEnd) = symbolAndEnd, symbolEnd < content.endIndex else { return nil }
        let sepChar = content[symbolEnd]
        guard sepChar == "." || sepChar == ")" || sepChar == "）" else { return nil }
        let normalizedSep = sepChar == "）" ? ")" : String(sepChar)

        let restStart = content.index(after: symbolEnd)
        return (symbol, normalizedSep, String(content[restStart...]))
    }

    private static func parseSymbol(_ content: String, from index: String.Index) -> (String, String.Index)? {
        guard index < content.endIndex else { return nil }
        let ch = content[index]

        if ch.isDigit {
            return parseDigits(content, from: index)
        }
        if ch.isASCIIAlpha {
            return (String(ch), content.index(after: index))
        }

        return nil
    }

    private static func parseDigits(_ content: String, from index: String.Index) -> (String, String.Index)? {
        var idx = index
        var digits = ""
        while idx < content.endIndex, content[idx].isDigit {
            digits.append(content[idx])
            idx = content.index(after: idx)
        }
        guard !digits.isEmpty else { return nil }
        return (digits, idx)
    }

    private static func replacingSingleNewlinesWithDoubleNewlines(_ content: String) -> String {
        let chars = Array(content)
        guard chars.contains("\n") else { return content }

        var output = ""
        output.reserveCapacity(chars.count + 8)

        for i in chars.indices {
            let ch = chars[i]
            if ch != "\n" {
                output.append(ch)
                continue
            }

            let prevIsNewline = i > 0 && chars[i - 1] == "\n"
            let nextIsNewline = (i + 1) < chars.count && chars[i + 1] == "\n"
            if !prevIsNewline, !nextIsNewline {
                output.append(contentsOf: "\n\n")
            } else {
                output.append("\n")
            }
        }

        return output
    }

    // MARK: - Post-pass merges

    private static func mergeFormulaNumbers(_ regions: [OCRRegion]) -> [OCRRegion] {
        guard !regions.isEmpty else { return regions }

        var merged: [OCRRegion] = []
        merged.reserveCapacity(regions.count)

        var skipIndices: Set<Int> = []

        for i in regions.indices {
            if skipIndices.contains(i) { continue }
            let block = regions[i]

            if block.nativeLabel == "formula_number" {
                if i + 1 < regions.count, regions[i + 1].kind == .formula {
                    let next = regions[i + 1]
                    let numberClean = cleanFormulaNumber(block.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")

                    var mergedBlock = next
                    if let formula = next.content, formula.hasSuffix("\n$$") {
                        mergedBlock.content = String(formula.dropLast(3)) + " \\tag{\(numberClean)}\n$$"
                    }

                    merged.append(mergedBlock)
                    skipIndices.insert(i + 1)
                    continue
                }
                continue
            }

            if block.kind == .formula {
                if i + 1 < regions.count, regions[i + 1].nativeLabel == "formula_number" {
                    let numberClean = cleanFormulaNumber(regions[i + 1].content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")

                    var mergedBlock = block
                    if let formula = block.content, formula.hasSuffix("\n$$") {
                        mergedBlock.content = String(formula.dropLast(3)) + " \\tag{\(numberClean)}\n$$"
                    }

                    merged.append(mergedBlock)
                    skipIndices.insert(i + 1)
                    continue
                }

                merged.append(block)
                continue
            }

            merged.append(block)
        }

        return renumberRegions(merged)
    }

    private static func mergeHyphenatedTextBlocks(_ regions: [OCRRegion]) -> [OCRRegion] {
        guard !regions.isEmpty else { return regions }

        var merged: [OCRRegion] = []
        merged.reserveCapacity(regions.count)

        var skipIndices: Set<Int> = []

        for i in regions.indices {
            if skipIndices.contains(i) { continue }

            let block = regions[i]
            guard block.kind == .text else {
                merged.append(block)
                continue
            }

            guard let content = block.content else {
                merged.append(block)
                continue
            }

            let contentStripped = trimmingTrailingWhitespace(content)
            guard !contentStripped.isEmpty else {
                merged.append(block)
                continue
            }

            guard contentStripped.hasSuffix("-") else {
                merged.append(block)
                continue
            }

            var didMerge = false
            for j in (i + 1) ..< regions.count {
                guard regions[j].kind == .text, let nextContent = regions[j].content else { continue }

                let nextStripped = trimmingLeadingWhitespace(nextContent)
                guard let firstScalar = nextStripped.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(firstScalar) else {
                    continue
                }

                let beforeTokens = contentStripped.dropLast().split(whereSeparator: { $0.isWhitespace })
                let afterTokens = nextStripped.split(whereSeparator: { $0.isWhitespace })
                if let beforeLast = beforeTokens.last, let afterFirst = afterTokens.first {
                    let beforeFragment = String(beforeLast)
                    let afterFragment = String(afterFirst)
                    if shouldMergeHyphenatedWord(before: beforeFragment, after: afterFragment) {
                        let mergedContent = String(contentStripped.dropLast()) + trimmingLeadingWhitespace(nextContent)
                        var mergedBlock = block
                        mergedBlock.content = mergedContent
                        merged.append(mergedBlock)
                        skipIndices.insert(j)
                        didMerge = true
                    }
                }

                break
            }

            if !didMerge {
                merged.append(block)
            }
        }

        return renumberRegions(merged)
    }

    private static func formatBulletPoints(_ regions: [OCRRegion], leftAlignThreshold: Int = 10) -> [OCRRegion] {
        guard regions.count >= 3 else { return regions }

        var regions = regions

        for i in 1 ..< (regions.count - 1) {
            let current = regions[i]
            let prev = regions[i - 1]
            let next = regions[i + 1]

            guard current.nativeLabel == "text", prev.nativeLabel == "text", next.nativeLabel == "text" else { continue }
            guard let currentContent = current.content, let prevContent = prev.content, let nextContent = next.content else { continue }
            guard !currentContent.hasPrefix("- ") else { continue }
            guard prevContent.hasPrefix("- "), nextContent.hasPrefix("- ") else { continue }

            let currentLeft = current.bbox.x1
            let prevLeft = prev.bbox.x1
            let nextLeft = next.bbox.x1

            if abs(currentLeft - prevLeft) <= leftAlignThreshold, abs(currentLeft - nextLeft) <= leftAlignThreshold {
                regions[i].content = "- " + currentContent
            }
        }

        return regions
    }

    private static func renumberRegions(_ regions: [OCRRegion]) -> [OCRRegion] {
        regions.enumerated().map { idx, region in
            var region = region
            region.index = idx
            return region
        }
    }

    private static func cleanFormulaNumber(_ content: String) -> String {
        var output = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.hasPrefix("("), output.hasSuffix(")"), output.count >= 2 {
            output = String(output.dropFirst().dropLast())
        } else if output.hasPrefix("（"), output.hasSuffix("）"), output.count >= 2 {
            output = String(output.dropFirst().dropLast())
        }
        return output
    }

    private static func shouldMergeHyphenatedWord(before: String, after: String) -> Bool {
        guard !before.isEmpty, !after.isEmpty else { return false }

        let merged = before + after
        guard merged.count <= 64 else { return false }
        guard merged.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { return false }

        return true
    }

    // MARK: - Small string helpers

    private static func trimmingLeadingWhitespace(_ content: String) -> String {
        String(content.drop(while: { $0.isWhitespace }))
    }

    private static func trimmingTrailingWhitespace(_ content: String) -> String {
        var end = content.endIndex
        while end > content.startIndex {
            let before = content.index(before: end)
            if content[before].isWhitespace {
                end = before
            } else {
                break
            }
        }
        return String(content[..<end])
    }

    private static func limitRepeats(in content: String, character: Character, maxRepeats: Int) -> String {
        guard maxRepeats >= 1 else { return "" }

        var output = ""
        output.reserveCapacity(content.count)

        var runCount = 0
        for ch in content {
            if ch == character {
                runCount += 1
                if runCount <= maxRepeats {
                    output.append(ch)
                }
            } else {
                runCount = 0
                output.append(ch)
            }
        }

        return output
    }

    private static func limitRepeatsOfEscapedUnderscore(_ content: String, maxRepeats: Int) -> String {
        guard maxRepeats >= 1 else { return "" }

        var output = ""
        output.reserveCapacity(content.count)

        var idx = content.startIndex
        while idx < content.endIndex {
            let ch = content[idx]
            if ch == "\\" {
                let next = content.index(after: idx)
                if next < content.endIndex, content[next] == "_" {
                    var runCount = 0
                    var j = idx
                    while j < content.endIndex {
                        let afterBackslash = content.index(after: j)
                        guard afterBackslash < content.endIndex, content[j] == "\\", content[afterBackslash] == "_" else { break }
                        runCount += 1
                        j = content.index(after: afterBackslash)
                    }

                    let kept = min(runCount, maxRepeats)
                    if kept > 0 {
                        for _ in 0 ..< kept {
                            output.append(contentsOf: "\\_")
                        }
                    }
                    idx = j
                    continue
                }
            }

            output.append(ch)
            idx = content.index(after: idx)
        }

        return output
    }
}

private extension Character {
    var isASCIIAlpha: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    var isDigit: Bool {
        unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }
}
