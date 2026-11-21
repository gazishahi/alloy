import AppKit
import Metal
import XCTest
@testable import AlloyTerminal

/// Draws grids offscreen and reads the pixels back.
final class TerminalRendererTests: XCTestCase {
    static let black = TerminalTheme(background: SIMD4(0, 0, 0, 1), cursor: 0xFFFFFF)
    let font = TerminalFont(name: "Menlo", size: 13)
    let scale: CGFloat = 2

    private func render(_ grid: TerminalGrid, renderer: TerminalRenderer) throws -> Pixels {
        let cell = font.cellSize
        let width = Int((CGFloat(grid.columns) * cell.width * scale).rounded(.up))
        let height = Int((CGFloat(grid.rows) * cell.height * scale).rounded(.up))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        let buffer = try XCTUnwrap(renderer.draw(grid, scale: scale, into: texture))
        buffer.waitUntilCompleted()
        return Pixels(texture)
    }

    /// The pixel rectangle of a cell, inset so neighbors don't bleed in.
    private func cellRect(column: Int, row: Int, span: Int = 1) -> (x: Range<Int>, y: Range<Int>) {
        let cell = font.cellSize
        let x0 = Int(CGFloat(column) * cell.width * scale) + 2, x1 = Int(CGFloat(column + span) * cell.width * scale) - 2
        let y0 = Int(CGFloat(row) * (cell.height * scale).rounded()) + 2, y1 = Int(CGFloat(row + 1) * (cell.height * scale).rounded()) - 2
        return (x0..<x1, y0..<y1)
    }

    private func makeRenderer() throws -> TerminalRenderer {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        return try TerminalRenderer(device: device, font: font, theme: Self.black)
    }

    func testGlyphsBackgroundsAndTheDefaultBackground() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 8, rows: 2, foreground: 0xFFFFFF)
        grid[0, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFF0000)
        grid[2, 0] = TerminalCell(foreground: 0xFFFFFF, background: 0x00FF00)
        grid[3, 0] = TerminalCell(foreground: 0xFFFFFF, background: 0x00FF00)
        grid.cursor.visible = false
        let pixels = try render(grid, renderer: renderer)

        let glyph = cellRect(column: 0, row: 0)
        XCTAssertGreaterThan(pixels.count(in: glyph) { $0.r > 150 && $0.g < 80 && $0.b < 80 }, 20, "a red W")
        let filled = cellRect(column: 2, row: 0, span: 2)
        XCTAssertEqual(pixels.count(in: filled) { $0.g > 240 && $0.r < 20 }, filled.x.count * filled.y.count, "a green run across two cells")
        let empty = cellRect(column: 6, row: 1)
        XCTAssertEqual(pixels.count(in: empty) { $0.r < 5 && $0.g < 5 && $0.b < 5 }, empty.x.count * empty.y.count, "the theme's background")
        XCTAssertEqual(grid.dirty, [false, false], "drawn rows are clean")
    }

    /// A variable font at a weight of its own has no bold face by traits: its bold is 300
    /// heavier on its weight axis, its italics keep the weight.
    func testAVariableFontsBoldIsHeavierOnItsAxis() throws {
        let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
        let axis = try XCTUnwrap(TerminalFont.weightAxis(base), "SF Mono is variable")
        let font = TerminalFont(TerminalFont.font(base, weight: 450))
        XCTAssertEqual(TerminalFont.weight(font.regular), 450)
        // Heavier by a bold's step: 750 on the axis here; macOS 15's SF Mono finds a bold face of
        // its own instead (683), which is as good.
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(TerminalFont.weight(font.bold)), 650)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(TerminalFont.weight(font.boldItalic)), 650)
        XCTAssertTrue(CTFontGetSymbolicTraits(font.italic).contains(.traitItalic))
        XCTAssertEqual(TerminalFont.weight(TerminalFont(TerminalFont.font(base, weight: 800)).bold), axis.upperBound, "held to the axis")
        XCTAssertEqual(CTFontGetAdvancesForGlyphs(font.bold, .horizontal, [CTFontGetGlyphWithName(font.bold, "M" as CFString)], nil, 1),
                       CTFontGetAdvancesForGlyphs(font.regular, .horizontal, [CTFontGetGlyphWithName(font.regular, "M" as CFString)], nil, 1),
                       "the same cell width")
        // A static family keeps its own bold face.
        XCTAssertEqual(CTFontCopyPostScriptName(TerminalFont(name: "Menlo-Regular", size: 13).bold) as String, "Menlo-Bold")
    }

    /// A translucent theme (Side's translucent background) as Ghostty's background-opacity at its
    /// defaults: only the default background lets the window's glass through; a cell's own
    /// background, its text and an image stay opaque (background-opacity-cells = false).
    func testATranslucentBackgroundAppliesToTheDefaultBackgroundOnly() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try TerminalRenderer(device: device, font: font, theme: TerminalTheme(background: SIMD4(0.2, 0.2, 0.2, 0.5), cursor: 0xFFFFFF))
        let grid = TerminalGrid(columns: 6, rows: 1, foreground: 0xFFFFFF)
        grid.cursor.visible = false
        grid[1, 0] = TerminalCell(foreground: 0xFFFFFF, background: 0x005F87)
        grid[3, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "M")), foreground: 0xFFFFFF)
        let key = TerminalImage.Key(id: 1, generation: 1)
        grid.newImagePixels = [solid(key, [255, 0, 0, 255])]
        grid.images = [place(key, .belowText, x: 5, y: 0, width: 1, height: 1)]
        let pixels = try render(grid, renderer: renderer)

        func all(_ column: Int, _ test: (Pixels.RGBA) -> Bool) -> Bool {
            let r = cellRect(column: column, row: 0)
            return pixels.count(in: r, test) == r.x.count * r.y.count
        }
        XCTAssertTrue(all(0) { (126...129).contains($0.a) && (24...27).contains($0.r) }, "the default background: half alpha, premultiplied")
        XCTAssertTrue(all(1) { $0.a == 255 && $0.b == 0x87 }, "a cell's own background is opaque")
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 3, row: 0)) { $0.a == 255 && $0.r > 250 }, 10, "text is opaque")
        XCTAssertTrue(all(5) { $0.a == 255 && $0.r > 250 }, "so is an image")
    }

    // MARK: Images (kitty graphics)

    /// One color's pixels, width × height, RGBA.
    private func solid(_ key: TerminalImage.Key, _ rgba: [UInt8], width: Int = 2, height: Int = 2) -> TerminalImage.Pixels {
        TerminalImage.Pixels(key: key, width: width, height: height, rgba: Array([[UInt8]](repeating: rgba, count: width * height).joined()))
    }

    private func place(_ key: TerminalImage.Key, _ layer: TerminalImage.Layer, x: Double, y: Double, width: Double, height: Double, z: Int32 = 0,
                       source: (Double, Double, Double, Double) = (0, 0, 0, 0)) -> TerminalImage {
        TerminalImage(key: key, layer: layer, z: z, x: x, y: y, width: width, height: height,
                      sourceX: source.0, sourceY: source.1, sourceWidth: source.2, sourceHeight: source.3)
    }

    /// Ghostty's layers: under the cells' backgrounds, between backgrounds and text, over text.
    func testImagesAreDrawnInTheirLayers() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 8, rows: 3, foreground: 0xFFFFFF)
        grid.cursor.visible = false
        let red = TerminalImage.Key(id: 1, generation: 1), blue = TerminalImage.Key(id: 2, generation: 1), white = TerminalImage.Key(id: 3, generation: 1)
        grid.newImagePixels = [solid(red, [255, 0, 0, 255]), solid(blue, [0, 0, 255, 255]), solid(white, [255, 255, 255, 255])]
        // Row 0: red under text across cells 0–3; cell 1 has a green background, cell 2 a W.
        grid[1, 0] = TerminalCell(foreground: 0xFFFFFF, background: 0x00FF00)
        grid[2, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0x00FF00)
        // Row 1: blue under backgrounds across cells 0–3; cell 1 has a green background.
        grid[1, 1] = TerminalCell(foreground: 0xFFFFFF, background: 0x00FF00)
        // Row 2: white over text across cells 0–3; cell 1 has a red W.
        grid[1, 2] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFF0000)
        grid.images = [place(red, .belowText, x: 0, y: 0, width: 4, height: 1),
                       place(blue, .belowBackground, x: 0, y: 1, width: 4, height: 1),
                       place(white, .aboveText, x: 0, y: 2, width: 4, height: 1)]
        let pixels = try render(grid, renderer: renderer)

        func all(_ column: Int, _ row: Int, _ test: (Pixels.RGBA) -> Bool) -> Bool {
            let r = cellRect(column: column, row: row)
            return pixels.count(in: r, test) == r.x.count * r.y.count
        }
        XCTAssertTrue(all(0, 0) { $0.r > 250 && $0.g < 5 && $0.b < 5 }, "the image on the default background")
        XCTAssertTrue(all(1, 0) { $0.r > 250 && $0.g < 5 }, "an image under text covers a cell's background")
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 2, row: 0)) { $0.g > 150 && $0.r < 100 }, 20, "but not the text")
        XCTAssertTrue(all(0, 1) { $0.b > 250 && $0.r < 5 }, "an image under backgrounds shows on the default one")
        XCTAssertTrue(all(1, 1) { $0.g > 250 && $0.b < 5 }, "and under a cell's own")
        XCTAssertTrue(all(1, 2) { $0.r > 250 && $0.g > 250 && $0.b > 250 }, "an image over text hides it")
        XCTAssertTrue(all(5, 0) { $0.r < 5 && $0.g < 5 && $0.b < 5 }, "nothing past the image")
        XCTAssertEqual(renderer.imageTextureCount, 3)
        XCTAssertTrue(grid.newImagePixels.isEmpty, "the renderer took the pixels")
    }

    func testAnImageDrawsItsSourceRectangleBlendedAndClippedToTheGrid() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 2, foreground: 0xFFFFFF)
        grid.cursor.visible = false
        let halves = TerminalImage.Key(id: 1, generation: 1), faint = TerminalImage.Key(id: 2, generation: 1)
        // Left pixel red, right pixel blue; only the right one is drawn, across two cells.
        grid.newImagePixels = [TerminalImage.Pixels(key: halves, width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 0, 255, 255]),
                               solid(faint, [255, 255, 255, 128])]
        // The half-transparent one runs off the grid's right edge and over its top.
        grid.images = [place(halves, .belowText, x: 0, y: 0, width: 2, height: 1, source: (1, 0, 1, 1)),
                       place(faint, .belowText, x: 4, y: -0.5, width: 4, height: 1)]
        let cell = font.cellSize
        let gridWidth = Int((CGFloat(grid.columns) * cell.width * scale).rounded(.up))
        let rowHeight = Int((cell.height * scale).rounded())
        // A target two cells wider than the grid: the padding stays the theme's.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: gridWidth + Int(cell.width * scale * 2),
                                                                  height: rowHeight * 2, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        try XCTUnwrap(renderer.draw(grid, scale: scale, into: texture)).waitUntilCompleted()
        let pixels = Pixels(texture)

        // Sampled smoothly, as Ghostty does: the source's left edge blends with its neighbor, so
        // the second cell, past the texel's center, is the one that's pure.
        let source = cellRect(column: 1, row: 0)
        XCTAssertEqual(pixels.count(in: source) { $0.b > 250 && $0.r < 5 }, source.x.count * source.y.count, "the source's blue")
        XCTAssertEqual(pixels.count(in: cellRect(column: 0, row: 0)) { $0.r > 128 }, 0, "and not the red beside it")
        let half = (x: cellRect(column: 4, row: 0).x, y: 2..<(rowHeight / 2 - 2))
        XCTAssertEqual(pixels.count(in: half) { (120...136).contains(Int($0.r)) && $0.r == $0.g && $0.g == $0.b }, half.x.count * half.y.count,
                       "half-transparent white over black")
        let below = (x: half.x, y: (rowHeight / 2 + 2)..<(rowHeight - 2))
        XCTAssertEqual(pixels.count(in: below) { $0.r < 5 }, below.x.count * below.y.count, "the part above the grid isn't drawn lower down")
        let padding = (x: (gridWidth + 1)..<texture.width, y: 0..<rowHeight)
        XCTAssertEqual(pixels.count(in: padding) { $0.r < 5 && $0.g < 5 && $0.b < 5 }, padding.x.count * padding.y.count, "clipped at the grid's edge")
    }

    /// Textures last while their images are on screen; an image whose pixels never came isn't drawn.
    func testImageTexturesGoWhenTheirImagesDo() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
        grid.cursor.visible = false
        let one = TerminalImage.Key(id: 1, generation: 1), next = TerminalImage.Key(id: 1, generation: 2)
        grid.newImagePixels = [solid(one, [255, 0, 0, 255])]
        grid.images = [place(one, .belowText, x: 0, y: 0, width: 2, height: 1)]
        _ = try render(grid, renderer: renderer)
        XCTAssertEqual(renderer.imageTextureCount, 1)
        // A new generation (new pixels) whose pixels haven't come: nothing drawn, the old one let go.
        grid.images = [place(next, .belowText, x: 0, y: 0, width: 2, height: 1)]
        let pixels = try render(grid, renderer: renderer)
        XCTAssertEqual(renderer.imageTextureCount, 0)
        let r = cellRect(column: 0, row: 0)
        XCTAssertEqual(pixels.count(in: r) { $0.r < 5 }, r.x.count * r.y.count)
        grid.images = []
        _ = try render(grid, renderer: renderer)
        XCTAssertEqual(renderer.imageTextureCount, 0)
    }

    /// A grapheme of several scalars (a flag, a combining accent) is kept by the grid, not the
    /// cell, and drawn whole; the cell itself stays plain data.
    func testAClusterIsDrawnWhole() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 1, foreground: 0xFFFFFF)
        grid.setCluster("e\u{301}", column: 1, row: 0, foreground: 0xFFFFFF)
        grid[3, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "e")), foreground: 0xFFFFFF)
        grid.cursor.visible = false
        XCTAssertEqual(grid.text(column: 1, row: 0), "e\u{301}")
        XCTAssertTrue(grid[1, 0].style.contains(.cluster))
        let pixels = try render(grid, renderer: renderer)
        let lit: (Pixels.RGBA) -> Bool = { $0.r > 128 }
        let accented = cellRect(column: 1, row: 0), plain = cellRect(column: 3, row: 0)
        XCTAssertGreaterThan(pixels.count(in: accented, lit), pixels.count(in: plain, lit), "the e and its accent")
    }

    func testAWideCharacterSpansTwoCells() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 1, foreground: 0xFFFFFF)
        grid[1, 0] = TerminalCell(scalar: 0x6F22, foreground: 0xFFFFFF, style: .wide) // 漢
        grid[2, 0] = TerminalCell(foreground: 0xFFFFFF, style: .spacer)
        grid.cursor.visible = false
        let pixels = try render(grid, renderer: renderer)
        let lit: (Pixels.RGBA) -> Bool = { $0.r > 100 }
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 1, row: 0), lit), 10)
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 2, row: 0), lit), 10, "the glyph reaches into its spacer")
        XCTAssertEqual(pixels.count(in: cellRect(column: 4, row: 0), lit), 0)
    }

    func testCursorShapes() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
        let cell = cellRect(column: 1, row: 0)
        let total = cell.x.count * cell.y.count
        let lit: (Pixels.RGBA) -> Bool = { $0.r > 100 }

        grid.cursor = TerminalCursor(column: 1, row: 0, visible: true, shape: .block)
        XCTAssertEqual(try render(grid, renderer: renderer).count(in: cell, lit), total, "a block fills the cell")
        grid.cursor.shape = .bar
        let bar = try render(grid, renderer: renderer).count(in: cell, lit)
        XCTAssertGreaterThan(bar, 0)
        XCTAssertLessThan(bar, total / 3, "a bar is a sliver")
        grid.cursor.visible = false
        XCTAssertEqual(try render(grid, renderer: renderer).count(in: cell, lit), 0)
    }

    /// Search matches in the theme's search colors, the selected one in its own, the text over
    /// them in the search's text color; cleared, the row looks as before.
    func testSearchMatchesAreHighlighted() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 8, rows: 1, foreground: 0xFFFFFF)
        for x in 0..<8 { grid[x, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFFFFFF) }
        grid.cursor.visible = false
        let before = try render(grid, renderer: renderer)
        renderer.searchMatches = [TerminalSpan(row: 0, columns: 1...2), TerminalSpan(row: 0, columns: 5...6)]
        renderer.selectedMatch = [TerminalSpan(row: 0, columns: 5...6)]
        let after = try render(grid, renderer: renderer)
        let yellow: (Pixels.RGBA) -> Bool = { $0.r > 240 && $0.g > 210 && $0.g < 235 && $0.b > 110 && $0.b < 140 } // 0xFFE082
        let orange: (Pixels.RGBA) -> Bool = { $0.r > 230 && $0.g > 150 && $0.g < 180 && $0.b > 110 && $0.b < 140 } // 0xF2A57E
        let black: (Pixels.RGBA) -> Bool = { $0.r < 40 && $0.g < 40 && $0.b < 40 }
        let match = cellRect(column: 1, row: 0), selected = cellRect(column: 5, row: 0), plain = cellRect(column: 3, row: 0)
        XCTAssertGreaterThan(after.count(in: match, yellow), match.x.count * match.y.count / 3, "a match")
        XCTAssertGreaterThan(after.count(in: match, black), 20, "its W in the search's text color")
        XCTAssertGreaterThan(after.count(in: selected, orange), selected.x.count * selected.y.count / 3, "the selected match")
        XCTAssertEqual(after.count(in: plain, yellow) + after.count(in: plain, orange), 0, "not a match")
        renderer.searchMatches = []
        renderer.selectedMatch = []
        XCTAssertEqual(try render(grid, renderer: renderer), before, "cleared")
    }

    /// The hovered link is underlined, cell by cell in each cell's color, across the rows it covers.
    func testTheHoveredLinkIsUnderlined() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 2, foreground: 0xFFFFFF)
        for x in 0..<6 { grid[x, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "a")), foreground: 0x00FF00) }
        for x in 0..<6 { grid[x, 1] = TerminalCell(scalar: UInt32(UInt8(ascii: "a")), foreground: 0x00FF00) }
        grid.cursor.visible = false
        let cell = font.cellSize
        let baseline = (cell.height * scale).rounded()
        // Below the text's baseline, where the underline sits ("a" has no descender).
        let ascent = Int((CTFontGetAscent(font.regular) * scale).rounded())
        func bottom(_ column: Int, _ row: Int) -> (x: Range<Int>, y: Range<Int>) {
            let x0 = Int(CGFloat(column) * cell.width * scale) + 2, x1 = Int(CGFloat(column + 1) * cell.width * scale) - 2
            let rowTop = Int(CGFloat(row) * baseline)
            return (x0..<x1, (rowTop + ascent + 1)..<(rowTop + Int(baseline) - 1))
        }
        let green: (Pixels.RGBA) -> Bool = { $0.g > 150 && $0.r < 100 }
        let before = try render(grid, renderer: renderer)
        XCTAssertEqual(before.count(in: bottom(4, 0), green), 0, "no underline yet")

        renderer.highlightedLink = [TerminalSpan(row: 0, columns: 3...5), TerminalSpan(row: 1, columns: 0...1)]
        let after = try render(grid, renderer: renderer)
        for (column, row) in [(3, 0), (5, 0), (0, 1), (1, 1)] {
            XCTAssertGreaterThan(after.count(in: bottom(column, row), green), 5, "underlined: \(column), \(row)")
        }
        for (column, row) in [(2, 0), (2, 1)] {
            XCTAssertEqual(after.count(in: bottom(column, row), green), 0, "not part of it: \(column), \(row)")
        }
        renderer.highlightedLink = []
        XCTAssertEqual(try render(grid, renderer: renderer), before, "gone again")
    }

    /// The strip past the last whole cell: the theme's background by default; extended, the edge
    /// cells' own backgrounds carried to the edge, right and bottom.
    func testPaddingColor() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 2, foreground: 0xFFFFFF)
        for x in 0..<4 { grid[x, 1] = TerminalCell(foreground: 0xFFFFFF, background: 0x0000FF) } // a status bar
        grid[3, 0] = TerminalCell(foreground: 0xFFFFFF, background: 0x00FF00)
        grid.cursor.visible = false
        let cell = font.cellSize
        let gridWidth = Int((CGFloat(4) * cell.width * scale).rounded(.down)), gridHeight = Int(2 * (cell.height * scale).rounded())
        // 30 pixels more each way than the grid needs.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: gridWidth + 30, height: gridHeight + 30, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        func draw() throws -> Pixels {
            let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
            try XCTUnwrap(renderer.draw(grid, scale: scale, into: texture)).waitUntilCompleted()
            return Pixels(texture)
        }
        let rowHeight = Int((cell.height * scale).rounded())
        let rightOfRow0 = ((gridWidth + 5)..<(gridWidth + 25), 4..<(rowHeight - 4))
        let rightOfRow1 = ((gridWidth + 5)..<(gridWidth + 25), (rowHeight + 4)..<(gridHeight - 4))
        let below = (4..<(gridWidth - 4), (gridHeight + 5)..<(gridHeight + 25))
        let corner = ((gridWidth + 5)..<(gridWidth + 25), (gridHeight + 5)..<(gridHeight + 25))
        let green: (Pixels.RGBA) -> Bool = { $0.g > 240 && $0.r < 20 && $0.b < 20 }
        let blue: (Pixels.RGBA) -> Bool = { $0.b > 240 && $0.r < 20 && $0.g < 20 }
        let black: (Pixels.RGBA) -> Bool = { $0.r < 10 && $0.g < 10 && $0.b < 10 }
        func all(_ p: Pixels, _ r: (Range<Int>, Range<Int>), _ test: (Pixels.RGBA) -> Bool) -> Bool { p.count(in: (r.0, r.1), test) == r.0.count * r.1.count }

        var pixels = try draw()
        XCTAssertTrue(all(pixels, rightOfRow0, black) && all(pixels, below, black) && all(pixels, corner, black), "the theme's background")
        renderer.paddingColor = .extend
        pixels = try draw()
        XCTAssertTrue(all(pixels, rightOfRow0, green), "row 0's last cell, carried right")
        XCTAssertTrue(all(pixels, rightOfRow1, blue), "the status bar to the right edge")
        XCTAssertTrue(all(pixels, below, blue), "and to the bottom")
        XCTAssertTrue(all(pixels, corner, blue), "and into the corner")
    }

    /// A family with no bold or italic (Monaco) draws them synthetically: bold heavier, italic
    /// slanted, leaning right at the top. One that has them (Menlo) uses its own faces.
    func testSyntheticBoldAndItalic() throws {
        let monaco = TerminalFont(name: "Monaco", size: 13)
        try XCTSkipUnless((CTFontCopyPostScriptName(monaco.regular) as String) == "Monaco", "Monaco isn't installed")
        XCTAssertEqual(monaco.synthetic([.bold]), [.bold])
        XCTAssertEqual(monaco.synthetic([.italic]), [.italic])
        XCTAssertEqual(monaco.synthetic([.bold, .italic]), [.bold, .italic])
        XCTAssertEqual(font.synthetic([.bold, .italic]), [], "Menlo has its own")

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try TerminalRenderer(device: device, font: monaco, theme: Self.black)
        func draw(_ style: TerminalCell.Style) throws -> (lit: Int, lean: Double) {
            let grid = TerminalGrid(columns: 3, rows: 1, foreground: 0xFFFFFF)
            grid[1, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "|")), foreground: 0xFFFFFF, style: style)
            grid.cursor.visible = false
            let cell = monaco.cellSize
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int((3 * cell.width * scale).rounded(.up)),
                                                                      height: Int((cell.height * scale).rounded(.up)), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            try XCTUnwrap(renderer.draw(grid, scale: scale, into: texture)).waitUntilCompleted()
            let pixels = Pixels(texture)
            // The ink's middle, x, in the top and bottom thirds of the cell: how far it leans.
            func middle(_ rows: Range<Int>) -> Double {
                var sum = 0.0, count = 0.0
                for y in rows { for x in 0..<pixels.width where pixels.count(in: (x..<(x + 1), y..<(y + 1)), { $0.r > 128 }) == 1 { sum += Double(x); count += 1 } }
                return count > 0 ? sum / count : 0
            }
            let h = pixels.height
            return (pixels.count(in: (0..<pixels.width, 0..<h), { $0.r > 128 }), middle(0..<(h / 3)) - middle((2 * h / 3)..<h))
        }
        let regular = try draw([]), bold = try draw(.bold), italic = try draw(.italic)
        XCTAssertGreaterThan(Double(bold.lit), Double(regular.lit) * 1.15, "bold is heavier")
        XCTAssertLessThan(abs(regular.lean), 1.5, "an upright bar: \(regular.lean)")
        XCTAssertGreaterThan(italic.lean, 3, "italic leans right toward the top: \(italic.lean)")
    }

    /// Blinking text (SGR 5) shows in the blink's on phase, not in the off; unfocused, it stays.
    func testBlinkingText() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
        grid[0, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFFFFFF, style: .blink)
        grid[2, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFFFFFF)
        grid.cursor.visible = false
        let lit: (Pixels.RGBA) -> Bool = { $0.r > 128 }
        let blinking = cellRect(column: 0, row: 0), steady = cellRect(column: 2, row: 0)
        var pixels = try render(grid, renderer: renderer)
        XCTAssertTrue(renderer.hasBlinkingText)
        XCTAssertGreaterThan(pixels.count(in: blinking, lit), 20, "on")
        renderer.blinkOn = false
        pixels = try render(grid, renderer: renderer)
        XCTAssertEqual(pixels.count(in: blinking, lit), 0, "off")
        XCTAssertGreaterThan(pixels.count(in: steady, lit), 20, "steady text stays")
        renderer.focused = false
        XCTAssertGreaterThan(try render(grid, renderer: renderer).count(in: blinking, lit), 20, "unfocused, it doesn't blink")
    }

    /// Minimum contrast: off by default; on, text too close to its background becomes black or
    /// white, whichever stands out more, and text that already stands out is left alone.
    func testMinimumContrast() throws {
        XCTAssertEqual(TerminalRenderer.contrast(0xFFFFFF, 0x000000), 21, accuracy: 0.01)
        XCTAssertEqual(TerminalRenderer.contrast(0x777777, 0x777777), 1, accuracy: 0.01)
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 1, foreground: 0xFFFFFF)
        grid[0, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0x101010)                     // near-black on black
        grid[2, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xE0E0E0, background: 0xFFFFFF) // near-white on white
        grid[4, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFF0000)                     // red on black: fine
        grid.cursor.visible = false
        let white: (Pixels.RGBA) -> Bool = { $0.r > 200 && $0.g > 200 && $0.b > 200 }
        let black: (Pixels.RGBA) -> Bool = { $0.r < 30 && $0.g < 30 && $0.b < 30 }
        let red: (Pixels.RGBA) -> Bool = { $0.r > 200 && $0.g < 60 }
        var pixels = try render(grid, renderer: renderer)
        XCTAssertEqual(pixels.count(in: cellRect(column: 0, row: 0), white), 0, "off: as the program asked")
        renderer.minimumContrast = 3
        pixels = try render(grid, renderer: renderer)
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 0, row: 0), white), 20, "white on black")
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 2, row: 0), black), 20, "black on white")
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 4, row: 0), red), 20, "red stands out already")
    }

    /// A program's cursor color over the theme's.
    func testTheCursorInAProgramsColor() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
        grid.cursor = TerminalCursor(column: 1, row: 0, visible: true, shape: .block, color: 0xFF8000)
        let cell = cellRect(column: 1, row: 0)
        let orange: (Pixels.RGBA) -> Bool = { $0.r > 240 && $0.g > 110 && $0.g < 150 && $0.b < 20 }
        XCTAssertEqual(try render(grid, renderer: renderer).count(in: cell, orange), cell.x.count * cell.y.count)
        grid.cursor.color = nil
        XCTAssertEqual(try render(grid, renderer: renderer).count(in: cell, orange), 0, "the theme's white")
    }

    /// Unfocused, every shape is an outline of its cell; a blinking cursor blinked off isn't drawn,
    /// unless unfocused, where it doesn't blink.
    func testHollowWhenUnfocusedAndBlinkedOff() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
        grid[1, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0x00FF00)
        grid.cursor = TerminalCursor(column: 1, row: 0, visible: true, shape: .bar, blinking: true)
        let cellPixels = cellRect(column: 1, row: 0)
        let cursorLit: (Pixels.RGBA) -> Bool = { $0.r > 200 && $0.b > 200 }
        let edges: (Pixels) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) = { p in
            let cell = self.font.cellSize
            let x0 = Int(CGFloat(1) * cell.width * self.scale), x1 = Int(CGFloat(2) * cell.width * self.scale) - 1
            let y1 = Int((cell.height * self.scale).rounded()) - 1, mid = y1 / 2, midX = (x0 + x1) / 2
            return (p.count(in: (x0..<x0 + 1, mid..<mid + 1), cursorLit) == 1, p.count(in: (x1..<x1 + 1, mid..<mid + 1), cursorLit) == 1,
                    p.count(in: (midX..<midX + 1, 0..<1), cursorLit) == 1, p.count(in: (midX..<midX + 1, y1..<y1 + 1), cursorLit) == 1)
        }

        renderer.focused = false
        renderer.blinkOn = false
        var pixels = try render(grid, renderer: renderer)
        let e = edges(pixels)
        XCTAssertTrue(e.left && e.right && e.top && e.bottom, "an outline all round: \(e)")
        XCTAssertGreaterThan(pixels.count(in: cellPixels) { $0.g > 150 && $0.r < 100 }, 20, "the W shows through, its own color")
        XCTAssertLessThan(pixels.count(in: cellPixels, cursorLit), cellPixels.x.count * cellPixels.y.count / 3, "hollow")

        renderer.focused = true
        pixels = try render(grid, renderer: renderer)
        XCTAssertEqual(pixels.count(in: cellPixels, cursorLit) + pixels.count(in: (0..<pixels.width, 0..<pixels.height), cursorLit), 0, "blinked off")
        renderer.blinkOn = true
        XCTAssertGreaterThan(try render(grid, renderer: renderer).count(in: (0..<pixels.width, 0..<pixels.height), cursorLit), 0, "blinked on: the bar")
        grid.cursor.blinking = false
        renderer.blinkOn = false
        XCTAssertGreaterThan(try render(grid, renderer: renderer).count(in: (0..<pixels.width, 0..<pixels.height), cursorLit), 0, "a steady cursor ignores the phase")
    }

    func testSelectedCellsAreHighlighted() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 1, foreground: 0xFFFFFF)
        for x in 1...3 { grid[x, 0] = TerminalCell(foreground: 0xFFFFFF, style: .selected) }
        grid.cursor.visible = false
        let pixels = try render(grid, renderer: renderer)
        let blue: (Pixels.RGBA) -> Bool = { $0.b > 60 && $0.b > $0.r + 30 }
        let selected = cellRect(column: 1, row: 0, span: 3)
        XCTAssertEqual(pixels.count(in: selected, blue), selected.x.count * selected.y.count, "the selection color over the run")
        XCTAssertEqual(pixels.count(in: cellRect(column: 5, row: 0), blue), 0)
    }

    /// Box drawing, braille and powerline are drawn to the cell: lines reach the cell's edges
    /// (so rows and columns join), dots sit where braille puts them.
    /// Legacy computing symbols drawn to the cell: a sextant, a diagonal wedge, an eighth block
    /// and a half shade, each filling exactly its part of the cell.
    func testLegacyComputingSymbols() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 5, rows: 1, foreground: 0xFFFFFF)
        grid[0, 0] = TerminalCell(scalar: 0x1FB00, foreground: 0xFFFFFF) // 🬀 sextant 1: the top-left sixth
        grid[1, 0] = TerminalCell(scalar: 0x1FB3D, foreground: 0xFFFFFF) // 🬽 lower left, below lower-middle-left → lower-right
        grid[2, 0] = TerminalCell(scalar: 0x1FB70, foreground: 0xFFFFFF) // 🭰 vertical one eighth, column 2
        grid[3, 0] = TerminalCell(scalar: 0x1FB8C, foreground: 0xFFFFFF) // 🮌 left half medium shade
        grid.cursor.visible = false
        let pixels = try render(grid, renderer: renderer)
        let cell = font.cellSize, w = cell.width * scale, h = (cell.height * scale).rounded()
        // The pixel at a point of a cell, in the cell's fractions.
        func at(_ column: Int, _ fx: Double, _ fy: Double) -> (x: Range<Int>, y: Range<Int>) {
            let x = Int(Double(column) * w + fx * w), y = Int(fy * h)
            return (x..<(x + 1), y..<(y + 1))
        }
        func lit(_ r: (x: Range<Int>, y: Range<Int>)) -> Bool { pixels.count(in: r) { $0.r > 200 } == 1 }
        func dark(_ r: (x: Range<Int>, y: Range<Int>)) -> Bool { pixels.count(in: r) { $0.r < 30 } == 1 }
        XCTAssertTrue(lit(at(0, 0.25, 0.15)) && dark(at(0, 0.75, 0.15)) && dark(at(0, 0.25, 0.5)), "the top-left sixth only")
        // Its diagonal runs from (0, 2/3) to (1, 1): below it is filled.
        XCTAssertTrue(lit(at(1, 0.15, 0.92)) && lit(at(1, 0.6, 0.97)), "below the wedge's diagonal")
        XCTAssertTrue(dark(at(1, 0.85, 0.75)) && dark(at(1, 0.5, 0.3)), "nothing above its diagonal")
        XCTAssertTrue(lit(at(2, 0.1875, 0.5)) && dark(at(2, 0.05, 0.5)) && dark(at(2, 0.4, 0.5)), "the second eighth")
        let shade = pixels.count(in: at(3, 0.25, 0.5)) { $0.r > 100 && $0.r < 160 }
        XCTAssertEqual(shade, 1, "a medium shade on the left half")
        XCTAssertTrue(dark(at(3, 0.75, 0.5)), "nothing on the right")
    }

    func testDrawnCharacters() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 6, rows: 2, foreground: 0xFFFFFF)
        grid[0, 0] = TerminalCell(scalar: 0x2500, foreground: 0xFFFFFF) // ─
        grid[1, 0] = TerminalCell(scalar: 0x2502, foreground: 0xFFFFFF) // │
        grid[1, 1] = TerminalCell(scalar: 0x2502, foreground: 0xFFFFFF) // │ below it
        grid[2, 0] = TerminalCell(scalar: 0x2801, foreground: 0xFFFFFF) // ⠁ dot 1
        grid[3, 0] = TerminalCell(scalar: 0x28FF, foreground: 0xFFFFFF) // ⣿ all eight
        grid[4, 0] = TerminalCell(scalar: 0xE0B0, foreground: 0xFFFFFF) // powerline right triangle
        grid.cursor.visible = false
        let pixels = try render(grid, renderer: renderer)
        let lit: (Pixels.RGBA) -> Bool = { $0.r > 128 }
        let cell = font.cellSize, w = cell.width * scale, h = (cell.height * scale).rounded()
        func px(_ column: Double, _ row: Double, _ dx: Double, _ dy: Double) -> (x: Range<Int>, y: Range<Int>) {
            let x = Int(column * w + dx * w), y = Int(row * h + dy * h)
            return (x..<(x + 1), y..<(y + 1))
        }
        // ─ reaches both edges at mid height; │ both edges at mid width, and joins the one below.
        XCTAssertEqual(pixels.count(in: px(0, 0, 0.02, 0.5), lit), 1)
        XCTAssertEqual(pixels.count(in: px(0, 0, 0.97, 0.5), lit), 1)
        XCTAssertEqual(pixels.count(in: px(1, 0, 0.5, 0.01), lit), 1)
        XCTAssertEqual(pixels.count(in: px(1, 0, 0.5, 0.99), lit), 1)
        XCTAssertEqual(pixels.count(in: px(1, 1, 0.5, 0.01), lit), 1, "no gap between rows")
        // ⠁: only the top-left dot.
        XCTAssertEqual(pixels.count(in: px(2, 0, 0.25, 0.125), lit), 1)
        XCTAssertEqual(pixels.count(in: px(2, 0, 0.75, 0.125), lit), 0)
        XCTAssertEqual(pixels.count(in: px(2, 0, 0.25, 0.875), lit), 0)
        // ⣿: every dot.
        for (dx, dy) in [(0.25, 0.125), (0.75, 0.125), (0.25, 0.375), (0.75, 0.375), (0.25, 0.625), (0.75, 0.625), (0.25, 0.875), (0.75, 0.875)] {
            XCTAssertEqual(pixels.count(in: px(3, 0, dx, dy), lit), 1, "dot at \(dx), \(dy)")
        }
        // The triangle: full height at the left edge, a point at the right's middle.
        XCTAssertEqual(pixels.count(in: px(4, 0, 0.1, 0.3), lit), 1)
        XCTAssertEqual(pixels.count(in: px(4, 0, 0.9, 0.5), lit), 1)
        XCTAssertEqual(pixels.count(in: px(4, 0, 0.9, 0.1), lit), 0)
    }

    /// A block cursor covers its cell and shows the character under it in the background color.
    func testABlockCursorInvertsItsCharacter() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
        grid[1, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFFFFFF)
        grid.cursor = TerminalCursor(column: 1, row: 0, visible: true, shape: .block)
        let pixels = try render(grid, renderer: renderer)
        let cell = cellRect(column: 1, row: 0)
        XCTAssertGreaterThan(pixels.count(in: cell) { $0.r < 60 }, 20, "the W, dark on the block")
        XCTAssertGreaterThan(pixels.count(in: cell) { $0.r > 200 }, cell.x.count * cell.y.count / 2, "the block itself")
    }

    /// The emulator can be bigger than the grid for a frame (the view's placeholder grid before
    /// layout): a cursor past the grid's edge isn't drawn, and the frame doesn't trap.
    func testACursorOutsideTheGridIsSkipped() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 4, rows: 2, foreground: 0xFFFFFF)
        for (column, row) in [(150, 0), (1, 40), (-1, 0)] {
            for shape in [TerminalCursor.Shape.block, .bar, .underline, .hollowBlock] {
                grid.cursor = TerminalCursor(column: column, row: row, visible: true, shape: shape)
                let pixels = try render(grid, renderer: renderer)
                XCTAssertEqual(pixels.count(in: cellRect(column: 3, row: 1)) { $0.r > 200 }, 0)
            }
        }
    }

    // MARK: Ligatures

    private func draw(_ text: String, font: TerminalFont, prepare: (TerminalRenderer) -> Void = { _ in }) throws -> Pixels {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try TerminalRenderer(device: device, font: font, theme: Self.black)
        prepare(renderer)
        let grid = TerminalGrid(columns: text.unicodeScalars.count + 2, rows: 1, foreground: 0xFFFFFF)
        for (x, scalar) in text.unicodeScalars.enumerated() { grid[x + 1, 0] = TerminalCell(scalar: scalar.value, foreground: 0xFFFFFF) }
        grid.cursor.visible = false
        let cell = font.cellSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int((CGFloat(grid.columns) * cell.width * scale).rounded(.up)),
                                                                  height: Int((cell.height * scale).rounded(.up)), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        try XCTUnwrap(renderer.draw(grid, scale: scale, into: texture)).waitUntilCompleted()
        return Pixels(texture)
    }

    /// A font without ligatures (Side's default, Menlo here) looks exactly as it did a glyph a cell.
    func testShapingChangesNothingForAFontWithoutLigatures() throws {
        var unshaped = font
        unshaped.ligatures = false
        for text in ["fn main() -> i32 { a != b }", "*bold* and plain", "x => y  <= z"] {
            XCTAssertEqual(try draw(text, font: font), try draw(text, font: unshaped), text)
        }
    }

    /// Only faces with ligatures or contextual alternates have their runs shaped: Side's default
    /// (MesloLGS NF, with neither) draws a glyph a cell and skips CoreText's shaping.
    func testOnlyFontsThatSubstituteAreShaped() throws {
        XCTAssertTrue(TerminalFont(name: "Menlo", size: 13).shapesRuns([]), "Menlo's Apple ligatures")
        XCTAssertTrue(TerminalFont(name: "Helvetica", size: 13).shapesRuns([]), "fi")
        let andale = TerminalFont(name: "Andale Mono", size: 13)
        if (CTFontCopyPostScriptName(andale.regular) as String) == "AndaleMono" {
            XCTAssertFalse(andale.shapesRuns([]), "no substitutions at all")
            XCTAssertFalse(andale.shapesRuns([.bold, .italic]))
        }
        let meslo = TerminalFont(name: "MesloLGS-NF-Regular", size: 13)
        if (CTFontCopyPostScriptName(meslo.regular) as String) == "MesloLGS-NF-Regular" {
            XCTAssertFalse(meslo.shapesRuns([]), "only a right-to-left form, which plain text never takes")
        }
        let fira = TerminalFont(name: "FiraCodeNFM-Reg", size: 13)
        if (CTFontCopyPostScriptName(fira.regular) as String) == "FiraCodeNFM-Reg" {
            XCTAssertTrue(fira.shapesRuns([]), "calt")
        }
        var off = TerminalFont(name: "Menlo", size: 13)
        off.ligatures = false
        XCTAssertFalse(off.shapesRuns([]), "turned off")
    }

    /// "fi" in Helvetica is one glyph for two cells: the run was shaped, not drawn a cell at a time.
    func testARunIsShapedWithItsLigatures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try TerminalRenderer(device: device, font: TerminalFont(name: "Helvetica", size: 13), theme: Self.black)
        let run = try XCTUnwrap(renderer.shaped("fi", face: [], scale: scale))
        XCTAssertEqual(run.count, 1, "one ligature glyph")
        XCTAssertEqual(run.first?.cell, 0, "starting at the first cell")
    }

    /// A character the font doesn't have comes from a fallback font with its own advance; the run
    /// isn't shaped, so nothing after it drifts out of its cell.
    func testARunWithAFallbackCharacterIsDrawnACellAtATime() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = try TerminalRenderer(device: device, font: font, theme: Self.black)
        XCTAssertNil(renderer.shaped("a\u{16A0}b", face: [], scale: scale), "ᚠ isn't in Menlo")
        XCTAssertNotNil(renderer.shaped("ab", face: [], scale: scale))
    }

    /// With a ligature font (Fira Code, where it's installed), `!=` draws as its ligature.
    func testFiraCodesLigaturesAreDrawn() throws {
        let fira = CTFontCreateWithName("FiraCodeNFM-Reg" as CFString, 13, nil)
        try XCTSkipUnless((CTFontCopyPostScriptName(fira) as String).hasPrefix("FiraCodeNFM"), "Fira Code isn't installed")
        var plain = TerminalFont(fira)
        plain.ligatures = false
        XCTAssertNotEqual(try draw("a != b", font: TerminalFont(fira)), try draw("a != b", font: plain))
        XCTAssertEqual(try draw("a b c", font: TerminalFont(fira)), try draw("a b c", font: plain), "no ligature, no change")
        // Runs are shaped a word at a time: a word that falls back to another font doesn't cost
        // the rest of the row its ligatures.
        XCTAssertNotEqual(try draw("a != b \u{16A0}", font: TerminalFont(fira)), try draw("a != b \u{16A0}", font: plain))
        // A row of new words is shaped once and cut into words; the same as each word shaped alone.
        let row = "if x != y => z <= 0xFF ||| www -> fn"
        let byWord = try draw(row, font: TerminalFont(fira)) { renderer in
            for word in row.split(separator: " ") { _ = renderer.shaped(String(word), face: [], scale: self.scale) }
        }
        XCTAssertEqual(try draw(row, font: TerminalFont(fira)), byWord)
    }

    // MARK: Right-to-left text

    /// Hebrew reads right to left: the word's first letter is drawn rightmost.
    func testRightToLeftTextIsDrawnInReadingOrder() throws {
        let renderer = try makeRenderer()
        let glyphs = renderer.rightToLeftGlyphsForTesting("שלום")
        XCTAssertEqual(glyphs.count, 4)
        let byIndex = Dictionary(uniqueKeysWithValues: glyphs.map { ($0.index, $0.x) })
        XCTAssertGreaterThan(byIndex[0]!, byIndex[1]!, "ש right of ל")
        XCTAssertGreaterThan(byIndex[1]!, byIndex[3]!, "and the last letter leftmost")
    }

    /// Arabic letters take their joined forms in a word, not the isolated ones a glyph a cell
    /// would draw (the regression of docs/SIDE_RFC_TERMINAL_ENGINE.md).
    func testArabicLettersJoin() throws {
        let renderer = try makeRenderer()
        let word = "سلام"
        let glyphs = renderer.rightToLeftGlyphsForTesting(word)
        XCTAssertFalse(glyphs.isEmpty)
        // The isolated form of each letter, in the font the run was drawn with.
        let font = try XCTUnwrap(glyphs.first?.font)
        var differing = 0
        for g in glyphs {
            let units = Array(word.utf16)
            guard units.indices.contains(g.index) else { continue }
            var unit = units[g.index], isolated: CGGlyph = 0
            CTFontGetGlyphsForCharacters(font, &unit, &isolated, 1)
            if isolated != g.glyph { differing += 1 }
        }
        XCTAssertGreaterThan(differing, 0, "some letters in a joined form")
        // Drawn, it differs from a glyph a cell.
        let grid = TerminalGrid(columns: 6, rows: 1, foreground: 0xFFFFFF)
        for (x, scalar) in word.unicodeScalars.enumerated() { grid[x + 1, 0] = TerminalCell(scalar: scalar.value, foreground: 0xFFFFFF) }
        grid.cursor.visible = false
        let joined = try render(grid, renderer: renderer)
        let cellByCell = try makeRenderer()
        cellByCell.drawsRightToLeftRuns = false
        let apart = try render(grid, renderer: cellByCell)
        XCTAssertNotEqual(joined, apart)
    }

    /// Composing text is drawn at the cursor, over what's there, underlined.
    func testComposingTextAtTheCursor() throws {
        let renderer = try makeRenderer()
        let grid = TerminalGrid(columns: 8, rows: 1, foreground: 0xFFFFFF)
        for x in 0..<8 { grid[x, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "x")), foreground: 0xFF0000) }
        grid.cursor = TerminalCursor(column: 2, row: 0)
        renderer.preedit = "日本"
        let pixels = try render(grid, renderer: renderer)
        let red: (Pixels.RGBA) -> Bool = { $0.r > 150 && $0.g < 80 }
        let white: (Pixels.RGBA) -> Bool = { $0.r > 150 && $0.g > 150 }
        XCTAssertEqual(pixels.count(in: cellRect(column: 2, row: 0, span: 4), red), 0, "the cells under it are covered")
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 2, row: 0, span: 4), white), 40, "two wide characters across four cells")
        XCTAssertGreaterThan(pixels.count(in: cellRect(column: 0, row: 0), red), 5, "the rest of the row as it was")
    }

    /// The renderer lives on the render thread: made and used there, away from the main actor.
    func testItDrawsOnAThreadOfItsOwn() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let font = self.font
        let done = expectation(description: "drawn off the main thread")
        nonisolated(unsafe) var lit = 0
        let thread = Thread {
            XCTAssertFalse(Thread.isMainThread)
            guard let renderer = try? TerminalRenderer(device: device, font: font, theme: Self.black) else { return }
            let grid = TerminalGrid(columns: 4, rows: 1, foreground: 0xFFFFFF)
            grid[0, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "#")), foreground: 0xFFFFFF)
            grid.cursor.visible = false
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 40, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return }
            renderer.draw(grid, scale: 2, into: texture)?.waitUntilCompleted()
            lit = Pixels(texture).count(in: (0..<16, 0..<40)) { $0.r > 100 }
            done.fulfill()
        }
        thread.start()
        wait(for: [done], timeout: 10)
        XCTAssertGreaterThan(lit, 10)
    }
}

@MainActor
final class AlloyTerminalViewTests: XCTestCase {
    final class Screen: TerminalGridSource, @unchecked Sendable {
        var text = ""
        var cursor = TerminalCursor(visible: false)
        func snapshot(into grid: TerminalGrid) -> Bool {
            for (i, scalar) in text.unicodeScalars.enumerated() where i < grid.columns {
                grid[i, 0] = TerminalCell(scalar: scalar.value, foreground: 0xFFFFFF)
            }
            grid.dirty[0] = true
            grid.cursor = cursor
            return true
        }
    }

    /// A focused, blinking cursor blinks on a timer; typing shows it again; unfocused or steady,
    /// no timer runs.
    func testTheCursorBlinksWhileFocused() throws {
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), font: TerminalFont(name: "Menlo", size: 13),
                                         theme: TerminalRendererTests.black)
        let screen = Screen()
        screen.cursor = TerminalCursor(column: 0, row: 0, visible: true, shape: .block, blinking: true)
        view.source = screen
        _ = view.renderOffscreen()
        XCTAssertFalse(view.isBlinking, "not focused")

        view.setFocused(true)
        view.setNeedsFrame()
        let off = Date().addingTimeInterval(2)
        while view.blinkOn, Date() < off { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(view.isBlinking)
        XCTAssertFalse(view.blinkOn, "blinked off within the interval")

        view.resetBlink()
        XCTAssertTrue(view.blinkOn, "typing shows it")

        view.setFocused(false)
        XCTAssertFalse(view.isBlinking)
        XCTAssertTrue(view.blinkOn)

        screen.cursor.blinking = false
        view.setFocused(true)
        view.setNeedsFrame()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(view.isBlinking, "a steady cursor")
    }

    /// Colors are sRGB, matched to the display by the window server.
    func testTheLayerIsTaggedSRGB() throws {
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), font: TerminalFont(name: "Menlo", size: 13),
                                         theme: TerminalRendererTests.black)
        let layer = try XCTUnwrap(view.layer as? CAMetalLayer)
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm, "blending in encoded values, as AppKit's")
    }

    /// Blinking text keeps the blink timer going though the cursor doesn't blink.
    func testBlinkingTextRunsTheTimer() throws {
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), font: TerminalFont(name: "Menlo", size: 13),
                                         theme: TerminalRendererTests.black)
        final class Blinking: TerminalGridSource, @unchecked Sendable {
            var blink = true
            func snapshot(into grid: TerminalGrid) -> Bool {
                grid[0, 0] = TerminalCell(scalar: UInt32(UInt8(ascii: "W")), foreground: 0xFFFFFF, style: blink ? .blink : [])
                grid.dirty[0] = true
                grid.cursor = TerminalCursor(visible: true, blinking: false)
                return true
            }
        }
        let source = Blinking()
        view.source = source
        view.setFocused(true)
        view.setNeedsFrame()
        let off = Date().addingTimeInterval(2)
        while view.blinkOn, Date() < off { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(view.isBlinking)
        XCTAssertFalse(view.blinkOn, "the text's phase turned")
        source.blink = false
        view.setNeedsFrame()
        let stop = Date().addingTimeInterval(1)
        while view.isBlinking, Date() < stop { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(view.isBlinking, "nothing blinks: no timer")
    }

    func testTheGridFollowsTheViewsSize() throws {
        let font = TerminalFont(name: "Menlo", size: 13)
        let cell = font.cellSize
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: cell.width * 80, height: cell.height * 24), font: font,
                                         theme: TerminalRendererTests.black)
        XCTAssertEqual(view.columns, 80)
        XCTAssertEqual(view.rows, 24)
        var reported: (Int, Int)?
        view.onGridResize = { reported = ($0, $1) }
        view.setFrameSize(NSSize(width: cell.width * 100 + 3, height: cell.height * 30 + 3))
        XCTAssertEqual(reported?.0, 100)
        XCTAssertEqual(reported?.1, 30)
    }

    func testItDrawsWhatTheSourceHolds() throws {
        let font = TerminalFont(name: "Menlo", size: 13)
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), font: font, theme: TerminalRendererTests.black)
        let screen = Screen()
        screen.text = "####"
        view.source = screen
        let texture = try XCTUnwrap(view.renderOffscreen())
        let lit = Pixels(texture).count(in: (0..<Int(font.cellSize.width * 2 * 4), 0..<Int(font.cellSize.height * 2))) { $0.r > 100 }
        XCTAssertGreaterThan(lit, 40)
    }

    func testMarkedTextUntilItsCommitted() throws {
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), font: TerminalFont(name: "Menlo", size: 13),
                                         theme: TerminalRendererTests.black)
        var typed: [String] = []
        view.onText = { typed.append($0) }
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))
        XCTAssertEqual(typed, [], "nothing reaches the program while composing")
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(typed, ["日本"])
        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText(), "cancelled")
    }

    func testTypedTextComesBackThroughOnText() throws {
        let view = try AlloyTerminalView(frame: NSRect(x: 0, y: 0, width: 200, height: 60), font: TerminalFont(name: "Menlo", size: 13),
                                         theme: TerminalRendererTests.black)
        var typed: [String] = []
        view.onText = { typed.append($0) }
        view.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(typed, ["é"])
    }
}

/// ALLOY_TERMINAL_SNAPSHOT=/path.png: a sample screen, written for the eye (skipped otherwise).
final class TerminalSnapshotTests: XCTestCase {
    func testSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["ALLOY_TERMINAL_SNAPSHOT"] else { throw XCTSkip("set ALLOY_TERMINAL_SNAPSHOT") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // ALLOY_TERMINAL_SNAPSHOT_FONT: another font, a ligature font's for instance.
        let font = TerminalFont(name: ProcessInfo.processInfo.environment["ALLOY_TERMINAL_SNAPSHOT_FONT"] ?? "Menlo", size: 13)
        let renderer = try TerminalRenderer(device: device, font: font, theme: TerminalTheme(background: SIMD4(0.12, 0.12, 0.13, 1), cursor: 0xD0D0D0))
        let lines: [(String, UInt32, UInt32?, TerminalCell.Style)] = [
            ("$ git status", 0xD0D0D0, nil, []),
            ("a != b => c <= d -> e === f ... www", 0xC678DD, nil, []),
            ("On branch main — bold", 0xE5C07B, nil, [.bold]),
            ("italic, underline, strike", 0x61AFEF, nil, [.italic]),
            ("underlined text here", 0x98C379, nil, []),
            ("struck through text", 0xE06C75, nil, [.strikethrough]),
            (" selection-ish background ", 0x101010, 0x61AFEF, []),
            ("emoji 🙂 flag 🇯🇵 e\u{301}", 0xD0D0D0, nil, []),
            ("╭──┬──╮ ┏━━┓ ┌┄┄┐ ▁▂▃▄▅▆▇█ ░▒▓", 0x98C379, nil, []),
            ("│  ┼  │ ┃  ┃ ╎  ╎ ▖▗▘▙▚▛▜▝▞▟ ▌▐", 0x98C379, nil, []),
            ("╰──┴──╯ ┗━━┛ └┈┈┘ ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏", 0x98C379, nil, []),
            ("\u{E0B6} repo \u{E0B4}\u{E0B0} main \u{E0B2} \u{E0B1} \u{E0B3}", 0x3B55C9, nil, []),
            ("\u{1FB00}\u{1FB01}\u{1FB02}\u{1FB0B}\u{1FB1E} \u{1FB3C}\u{1FB3D}\u{1FB47}\u{1FB48} \u{1FB68}\u{1FB69}\u{1FB6C}\u{1FB9A} \u{1FB70}\u{1FB73}\u{1FB76}\u{1FB82}\u{1FB87} \u{1FB8C}\u{1FB91}", 0xC678DD, nil, []),
        ]
        let grid = TerminalGrid(columns: 60, rows: lines.count + 2, foreground: 0xD0D0D0)
        for (y, line) in lines.enumerated() {
            var x = 0
            for character in line.0 where x < grid.columns {
                let scalars = character.unicodeScalars
                let wide = character.unicodeScalars.first.map { $0.properties.isEmojiPresentation || (0x1100...0x9FFF).contains($0.value) } ?? false
                var style = line.3
                if wide { style.insert(.wide) }
                if scalars.count > 1 { style.insert(.cluster); grid.rowClusters[y][x] = String(character) }
                grid[x, y] = TerminalCell(scalar: scalars.first?.value ?? 0,
                                          foreground: line.1, background: line.2, style: style,
                                          underline: y == 3 ? [.single, .double, .curly, .dotted][min(3, x / 5)] : .none,
                                          underlineColor: y == 3 && x >= 10 ? 0xE06C75 : nil)
                if wide, x + 1 < grid.columns { grid[x + 1, y] = TerminalCell(foreground: line.1, background: line.2, style: .spacer); x += 1 }
                x += 1
            }
        }
        // The powerline row: text on the segment's color between its caps.
        for x in 1...6 { grid[x, 10].background = 0x3B55C9; grid[x, 10].foreground = 0xFFFFFF }
        grid[0, lines.count] = TerminalCell(scalar: UInt32(UInt8(ascii: "$")), foreground: 0xD0D0D0)
        grid.cursor = TerminalCursor(column: 2, row: lines.count, visible: true, shape: .block)
        let cell = font.cellSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(CGFloat(grid.columns) * cell.width * 2),
                                                                  height: Int(CGFloat(grid.rows) * (cell.height * 2).rounded()), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        renderer.draw(grid, scale: 2, into: texture)?.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: texture.width, height: texture.height, bitsPerComponent: 8, bytesPerRow: texture.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let png = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:])
        try XCTUnwrap(png).write(to: URL(fileURLWithPath: path))
    }
}

/// A texture's pixels, read back as BGRA.
struct Pixels: Equatable {
    struct RGBA { let r: UInt8, g: UInt8, b: UInt8, a: UInt8 }
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ texture: MTLTexture) {
        width = texture.width
        height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        self.bytes = bytes
    }

    func count(in rect: (x: Range<Int>, y: Range<Int>), _ test: (RGBA) -> Bool) -> Int {
        var n = 0
        for y in rect.y where y >= 0 && y < height {
            for x in rect.x where x >= 0 && x < width {
                let i = (y * width + x) * 4
                if test(RGBA(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i], a: bytes[i + 3])) { n += 1 }
            }
        }
        return n
    }
}
