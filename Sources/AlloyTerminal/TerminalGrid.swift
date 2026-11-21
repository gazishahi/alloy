/// One cell of a terminal's screen, as an emulator resolved it: text, colors already turned into
/// RGB (palette, inverse and dim applied by the emulator), and the style the renderer draws.
public struct TerminalCell: Equatable, Sendable {
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        /// A line over the cell (SGR 53).
        public static let overline = Style(rawValue: 1 << 2)
        public static let strikethrough = Style(rawValue: 1 << 3)
        /// The left half of a wide character (CJK, most emoji): its glyph spans two cells.
        public static let wide = Style(rawValue: 1 << 4)
        /// The right half of a wide character, or a placeholder: nothing drawn of its own.
        public static let spacer = Style(rawValue: 1 << 5)
        /// Inside the selection: drawn with the theme's selection color over its background.
        public static let selected = Style(rawValue: 1 << 6)
        /// SGR 5: the text blinks, with the cursor's phase, while the terminal is focused.
        public static let blink = Style(rawValue: 1 << 7)
        /// More than one scalar: the whole grapheme is the grid's (`TerminalGrid.cluster`).
        public static let cluster = Style(rawValue: 1 << 8)
    }

    /// The cell's text when it's a single scalar (a cluster's first); 0 for an empty cell. A
    /// grapheme of more than one scalar (ZWJ emoji, flags, combining marks) is flagged
    /// `.cluster` and kept by the grid, so a cell is plain data: a screen of them is copied
    /// every frame, and a string in each made that twice as slow.
    public var scalar: UInt32
    /// 0xRRGGBB.
    public var foreground: UInt32
    /// 0xRRGGBB, or nil for the terminal's default background (not drawn, so the view's own
    /// background, translucent or not, shows through).
    public var background: UInt32?
    public var style: Style

    /// SGR 4's kinds: what diagnostics and spell checkers draw with (curly, in their own color).
    public enum Underline: Sendable, Equatable { case none, single, double, curly, dotted, dashed }
    public var underline: Underline
    /// 0xRRGGBB (SGR 58), or nil for the text's color.
    public var underlineColor: UInt32?

    public init(scalar: UInt32 = 0, foreground: UInt32, background: UInt32? = nil, style: Style = [],
                underline: Underline = .none, underlineColor: UInt32? = nil) {
        self.scalar = scalar
        self.foreground = foreground
        self.background = background
        self.style = style
        self.underline = underline
        self.underlineColor = underlineColor
    }
}

public struct TerminalCursor: Equatable, Sendable {
    /// `hollowBlock`: an outline of the cell, what every shape becomes while the terminal isn't
    /// focused (and what a program can ask for).
    public enum Shape: Sendable { case block, bar, underline, hollowBlock }
    public var column: Int
    public var row: Int
    public var visible: Bool
    public var shape: Shape
    /// The program wants it blinking (DECSCUSR's odd styles, DEC mode 12).
    public var blinking: Bool
    /// 0xRRGGBB, a color a program set (OSC 12); nil for the theme's.
    public var color: UInt32?

    public init(column: Int = 0, row: Int = 0, visible: Bool = true, shape: Shape = .block, blinking: Bool = false, color: UInt32? = nil) {
        self.column = column
        self.row = row
        self.visible = visible
        self.shape = shape
        self.blinking = blinking
        self.color = color
    }
}

/// Cells on one row of the grid, `columns` inclusive: a link to underline, say.
public struct TerminalSpan: Equatable, Sendable {
    public var row: Int
    public var columns: ClosedRange<Int>
    public init(row: Int, columns: ClosedRange<Int>) { self.row = row; self.columns = columns }
}

/// The screen an emulator hands the renderer: cells row by row, which rows changed since the
/// renderer last drew them, and the cursor. Touched only on the render thread: the emulator's
/// `TerminalGridSource` copies into it there, the renderer reads it and clears `dirty`.
public final class TerminalGrid {
    public private(set) var columns: Int
    public private(set) var rows: Int
    /// Row-major, `columns × rows`.
    public var cells: [TerminalCell]
    public var dirty: [Bool]
    /// Each row's clusters, by column: the graphemes of cells flagged `.cluster`. Empty for
    /// most rows; set with the row's cells.
    public var rowClusters: [[Int: String]]
    public var cursor = TerminalCursor()
    /// The images on screen (kitty graphics), in no particular order.
    public var images: [TerminalImage] = []
    /// Pixels for images the renderer hasn't had yet: it takes them at its next frame. An image
    /// whose pixels never came isn't drawn.
    public var newImagePixels: [TerminalImage.Pixels] = []
    let blank: TerminalCell

    public init(columns: Int, rows: Int, foreground: UInt32) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        blank = TerminalCell(foreground: foreground)
        cells = Array(repeating: blank, count: self.columns * self.rows)
        dirty = Array(repeating: true, count: self.rows)
        rowClusters = Array(repeating: [:], count: self.rows)
    }

    /// A cell's whole grapheme: its cluster if it has one, else its scalar.
    public func text(column: Int, row: Int) -> String? {
        let cell = self[column, row]
        if cell.style.contains(.cluster) { return rowClusters[row][column] }
        return cell.scalar > 0 ? UnicodeScalar(cell.scalar).map { String(Character($0)) } : nil
    }

    /// A cell whose text is a cluster: flagged, and its grapheme kept with the row's.
    public func setCluster(_ grapheme: String, column: Int, row: Int, foreground: UInt32, style: TerminalCell.Style = []) {
        self[column, row] = TerminalCell(scalar: grapheme.unicodeScalars.first?.value ?? 0, foreground: foreground, style: style.union(.cluster))
        rowClusters[row][column] = grapheme
    }

    public subscript(column: Int, row: Int) -> TerminalCell {
        get { cells[row * columns + column] }
        set { cells[row * columns + column] = newValue }
    }

    /// A new size: blank cells, every row dirty. The emulator refills it on its next snapshot.
    public func resize(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        cells = Array(repeating: blank, count: self.columns * self.rows)
        dirty = Array(repeating: true, count: self.rows)
        rowClusters = Array(repeating: [:], count: self.rows)
        cursor = TerminalCursor()
    }
}

/// One image placement: an image's part, drawn at a place measured in cells.
public struct TerminalImage: Equatable, Sendable {
    public enum Layer: Int, Sendable, Comparable {
        /// Under cell backgrounds (but over the window's), under text, or over text.
        case belowBackground, belowText, aboveText
        public static func < (a: Layer, b: Layer) -> Bool { a.rawValue < b.rawValue }
    }
    /// An image's pixels as one version of them: a new generation is new pixels.
    public struct Key: Hashable, Sendable {
        public let id: UInt32
        public let generation: UInt64
        public init(id: UInt32, generation: UInt64) { self.id = id; self.generation = generation }
    }
    /// 8-bit RGBA, rows top first, no padding, alpha not premultiplied.
    public struct Pixels: Sendable {
        public let key: Key
        public let width: Int
        public let height: Int
        public let rgba: [UInt8]
        public init(key: Key, width: Int, height: Int, rgba: [UInt8]) {
            self.key = key; self.width = width; self.height = height; self.rgba = rgba
        }
    }
    public var key: Key
    public var layer: Layer
    /// The order within the layer, lowest first.
    public var z: Int32
    /// The top-left corner and size, in cells from the grid's top-left (fractional; negative
    /// above or left of the grid).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// The part of the image drawn, in image pixels.
    public var sourceX: Double
    public var sourceY: Double
    public var sourceWidth: Double
    public var sourceHeight: Double

    public init(key: Key, layer: Layer, z: Int32, x: Double, y: Double, width: Double, height: Double,
                sourceX: Double, sourceY: Double, sourceWidth: Double, sourceHeight: Double) {
        self.key = key; self.layer = layer; self.z = z
        self.x = x; self.y = y; self.width = width; self.height = height
        self.sourceX = sourceX; self.sourceY = sourceY; self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
    }
}

/// An emulator behind the renderer. On the render thread, at each frame: copy what changed into
/// `grid` (setting its rows' `dirty`) and say whether anything did. It must be safe to call there
/// while the emulator parses on its own thread, which is why it's Sendable: libghostty-vt's
/// render state is updated under the terminal's lock and read without it.
public protocol TerminalGridSource: AnyObject, Sendable {
    func snapshot(into grid: TerminalGrid) -> Bool
}
