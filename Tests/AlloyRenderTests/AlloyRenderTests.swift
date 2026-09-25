import AlloyCore
import CoreText
import Metal
import XCTest
@testable import AlloyRender

final class RowIndexTests: XCTestCase {
    func testPrefixesAndLookups() {
        var index = RowIndex(rows: [1, 3, 1, 2])
        XCTAssertEqual(index.totalRows, 7)
        XCTAssertEqual((0...4).map { index.prefix($0) }, [0, 1, 4, 5, 7])
        XCTAssertTrue(index.line(atRow: 0) == (0, 0))
        XCTAssertTrue(index.line(atRow: 2) == (1, 1))
        XCTAssertTrue(index.line(atRow: 4) == (2, 0))
        XCTAssertTrue(index.line(atRow: 6) == (3, 1))
        XCTAssertTrue(index.line(atRow: 99) == (3, 1), "past the end: the last row")
        index.set(line: 1, rows: 1)
        XCTAssertEqual(index.totalRows, 5)
        index.replaceLines(start: 1, oldCount: 2, newCount: 4)
        XCTAssertEqual(index.rows, [1, 1, 1, 1, 1, 2])
    }

    func testManyLines() {
        var index = RowIndex(lineCount: 100_000)
        index.set(line: 50_000, rows: 5)
        XCTAssertEqual(index.totalRows, 100_004)
        XCTAssertTrue(index.line(atRow: 50_003) == (50_000, 3))
        XCTAssertTrue(index.line(atRow: 50_005) == (50_001, 0))
    }
}

@MainActor
final class DocumentLayoutTests: XCTestCase {
    let font = CTFontCreateUIFontForLanguage(.userFixedPitch, 13, nil)!

    func testCaretsAndHitTestsRoundTrip() {
        let text = Rope("let a = 1\n\tlet b = \"😀\"\n\nlast")
        let layout = DocumentLayout(text: text, font: font)
        for offset in [0, 3, 9, 10, 11, 20, 22, 24, 25, text.utf16Count] {
            let caret = layout.caretRect(at: offset)
            XCTAssertEqual(layout.offset(at: CGPoint(x: caret.minX + 0.1, y: caret.midY)), offset, "offset \(offset)")
        }
        XCTAssertEqual(layout.caretRect(at: 10).minY, layout.y(ofLine: 1))
        XCTAssertGreaterThan(layout.caretRect(at: 11).minX - layout.caretRect(at: 10).minX, layout.tabWidth * 0.9, "a tab is four spaces wide")
    }

    func testWrappingMakesRowsAndMovesLinesDown() {
        let long = String(repeating: "word ", count: 60)
        let layout = DocumentLayout(text: Rope("short\n" + long + "\nafter"), font: font)
        let unwrappedAfter = layout.y(ofLine: 2)
        layout.setWrapWidth(200)
        let rows = layout.layout(line: 1).rows
        XCTAssertGreaterThan(rows.count, 3)
        XCTAssertEqual(layout.y(ofLine: 2), unwrappedAfter + CGFloat(rows.count - 1) * layout.lineHeight)
        for row in rows { XCTAssertLessThanOrEqual(row.width, 200 + 1) }
        // A caret at the start of the second row sits on that row, at the left edge.
        let secondRow = rows[1].range.lowerBound + 6
        let caret = layout.caretRect(at: secondRow)
        XCTAssertEqual(caret.minY, layout.y(ofLine: 1) + layout.lineHeight)
        XCTAssertEqual(caret.minX, layout.insets.width, accuracy: 0.5)
        XCTAssertEqual(layout.offset(at: CGPoint(x: caret.minX + 0.1, y: caret.midY)), secondRow)
    }

    func testEditsKeepRowsInStep() {
        let buffer = TextBuffer("a\nb\nc\n")
        let layout = DocumentLayout(text: buffer.text, font: font)
        buffer.onChange = { layout.update(buffer.text, edits: $0.edits) }
        buffer.setSelections([Selection(caret: 2)])
        buffer.insert("x\ny\n")
        XCTAssertEqual(layout.lineCount, 6)
        XCTAssertEqual(layout.y(ofLine: 5), layout.insets.height + 5 * layout.lineHeight)
        buffer.undo()
        XCTAssertEqual(layout.lineCount, 4)
        XCTAssertEqual(layout.contentHeight, 4 * layout.lineHeight + layout.insets.height * 2)
    }
}

/// Renders off screen and reads the pixels back: text lands where the layout says, and the
/// selection and caret are drawn in their colors.
@MainActor
final class TextRendererTests: XCTestCase {
    func testPixelsLandWhereTheLayoutSays() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device (a CI runner without a GPU)")
        let renderer = try TextRenderer()
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, 14, nil)!
        let text = Rope("MMMM selected\nsecond line 😀\n")
        let layout = DocumentLayout(text: text, font: font)
        let scale: CGFloat = 2
        let size = CGSize(width: 400, height: 120)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width * scale), height: Int(size.height * scale), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        let target = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        var theme = RenderTheme.light
        theme.selection = [1, 0, 0, 1]
        theme.caret = [0, 0, 1, 1]
        theme.currentLine = [0, 0, 0, 0]
        let frame = RenderFrame(scrollY: 0, size: size, scale: scale,
                                selections: [Selection(anchor: 5, head: 13), Selection(caret: 21)], theme: theme)
        let buffer = try XCTUnwrap(renderer.draw(frame, layout: layout, into: target))
        let blit = try XCTUnwrap(renderer.device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(blit.makeBlitCommandEncoder())
        encoder.synchronize(resource: target)
        encoder.endEncoding()
        buffer.waitUntilCompleted()
        blit.commit()
        blit.waitUntilCompleted()

        func pixel(_ point: CGPoint) -> SIMD4<UInt8> {
            var bytes = [UInt8](repeating: 0, count: 4)
            target.getBytes(&bytes, bytesPerRow: target.width * 4, from: MTLRegionMake2D(Int(point.x * scale), Int(point.y * scale), 1, 1), mipmapLevel: 0)
            return [bytes[2], bytes[1], bytes[0], bytes[3]]  // BGRA to RGBA
        }

        // The selection band covers "selected": red where there's no glyph ink.
        let selection = layout.caretRect(at: 5)
        let selectionEnd = layout.caretRect(at: 13)
        let inSelection = pixel(CGPoint(x: (selection.minX + selectionEnd.minX) / 2, y: selection.minY + 1))
        XCTAssertGreaterThan(inSelection.x, 200)
        XCTAssertLessThan(inSelection.z, 80)
        // The caret on line 2 is blue.
        let caret = layout.caretRect(at: 21)
        let onCaret = pixel(CGPoint(x: caret.minX, y: caret.midY))
        XCTAssertGreaterThan(onCaret.z, 150)
        XCTAssertLessThan(onCaret.x, 100)
        // Text is drawn: the "MMMM" run holds dark ink; the empty background doesn't.
        var inked = 0
        let first = layout.caretRect(at: 0)
        let fourth = layout.caretRect(at: 4)
        for x in stride(from: first.minX, to: fourth.minX, by: 0.5) {
            for y in stride(from: first.minY, to: first.maxY, by: 0.5) where pixel(CGPoint(x: x, y: y)).x < 100 { inked += 1 }
        }
        XCTAssertGreaterThan(inked, 40, "the glyphs left ink")
        let empty = pixel(CGPoint(x: 380, y: 110))
        XCTAssertGreaterThan(empty.x, 230, "the background is the theme's")
        XCTAssertGreaterThan(renderer.lastStats.quads, 20)
        XCTAssertEqual(renderer.lastStats.visibleLines, 3)
    }
}
