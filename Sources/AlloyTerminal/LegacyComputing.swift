/// Symbols for Legacy Computing (U+1FB00–U+1FB9B), drawn to the cell as Ghostty's sprite font
/// draws them: the sextants, the diagonal "smooth mosaic" wedges, the triangular blocks, the
/// eighth blocks and the half shades, the shapes teletext art and terminal image viewers (chafa)
/// build pictures from. Generated from the characters' Unicode names, which spell out each
/// shape: "LOWER LEFT BLOCK DIAGONAL UPPER MIDDLE LEFT TO LOWER CENTRE" is the cell on the
/// lower left of that line. Not drawn (left to the font): the checkerboards and fills
/// (U+1FB95–1FB99) and the shaded triangles (U+1FB9C–1FB9F).
enum LegacyComputing {
    /// In the cell's fractions, top-left (0, 0) to bottom-right (1, 1). A polygon is convex.
    enum Piece {
        case rect(Float, Float, Float, Float, Float)
        case poly([(Float, Float)])
    }

    static let shapes: [UInt32: [Piece]] = [
        0x1FB00: [.rect(0, 0, 0.5, 0.333333, 1)], // BLOCK SEXTANT-1
        0x1FB01: [.rect(0.5, 0, 1, 0.333333, 1)], // BLOCK SEXTANT-2
        0x1FB02: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1)], // BLOCK SEXTANT-12
        0x1FB03: [.rect(0, 0.333333, 0.5, 0.666667, 1)], // BLOCK SEXTANT-3
        0x1FB04: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1)], // BLOCK SEXTANT-13
        0x1FB05: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1)], // BLOCK SEXTANT-23
        0x1FB06: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1)], // BLOCK SEXTANT-123
        0x1FB07: [.rect(0.5, 0.333333, 1, 0.666667, 1)], // BLOCK SEXTANT-4
        0x1FB08: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1)], // BLOCK SEXTANT-14
        0x1FB09: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1)], // BLOCK SEXTANT-24
        0x1FB0A: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1)], // BLOCK SEXTANT-124
        0x1FB0B: [.rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1)], // BLOCK SEXTANT-34
        0x1FB0C: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1)], // BLOCK SEXTANT-134
        0x1FB0D: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1)], // BLOCK SEXTANT-234
        0x1FB0E: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1)], // BLOCK SEXTANT-1234
        0x1FB0F: [.rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-5
        0x1FB10: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-15
        0x1FB11: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-25
        0x1FB12: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-125
        0x1FB13: [.rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-35
        0x1FB14: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-235
        0x1FB15: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-1235
        0x1FB16: [.rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-45
        0x1FB17: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-145
        0x1FB18: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-245
        0x1FB19: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-1245
        0x1FB1A: [.rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-345
        0x1FB1B: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-1345
        0x1FB1C: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-2345
        0x1FB1D: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1)], // BLOCK SEXTANT-12345
        0x1FB1E: [.rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-6
        0x1FB1F: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-16
        0x1FB20: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-26
        0x1FB21: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-126
        0x1FB22: [.rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-36
        0x1FB23: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-136
        0x1FB24: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-236
        0x1FB25: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-1236
        0x1FB26: [.rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-46
        0x1FB27: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-146
        0x1FB28: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-1246
        0x1FB29: [.rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-346
        0x1FB2A: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-1346
        0x1FB2B: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-2346
        0x1FB2C: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-12346
        0x1FB2D: [.rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-56
        0x1FB2E: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-156
        0x1FB2F: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-256
        0x1FB30: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-1256
        0x1FB31: [.rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-356
        0x1FB32: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-1356
        0x1FB33: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-2356
        0x1FB34: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-12356
        0x1FB35: [.rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-456
        0x1FB36: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-1456
        0x1FB37: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-2456
        0x1FB38: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0.5, 0, 1, 0.333333, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-12456
        0x1FB39: [.rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-3456
        0x1FB3A: [.rect(0, 0, 0.5, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-13456
        0x1FB3B: [.rect(0.5, 0, 1, 0.333333, 1), .rect(0, 0.333333, 0.5, 0.666667, 1), .rect(0.5, 0.333333, 1, 0.666667, 1), .rect(0, 0.666667, 0.5, 1, 1), .rect(0.5, 0.666667, 1, 1, 1)], // BLOCK SEXTANT-23456
        0x1FB3C: [.poly([(0.5, 1), (0, 1), (0, 0.666667)])], // LOWER LEFT BLOCK DIAGONAL LOWER MIDDLE LEFT TO LOWER CENTRE
        0x1FB3D: [.poly([(1, 1), (0, 1), (0, 0.666667)])], // LOWER LEFT BLOCK DIAGONAL LOWER MIDDLE LEFT TO LOWER RIGHT
        0x1FB3E: [.poly([(0.5, 1), (0, 1), (0, 0.333333)])], // LOWER LEFT BLOCK DIAGONAL UPPER MIDDLE LEFT TO LOWER CENTRE
        0x1FB3F: [.poly([(1, 1), (0, 1), (0, 0.333333)])], // LOWER LEFT BLOCK DIAGONAL UPPER MIDDLE LEFT TO LOWER RIGHT
        0x1FB40: [.poly([(0, 0), (0.5, 1), (0, 1)])], // LOWER LEFT BLOCK DIAGONAL UPPER LEFT TO LOWER CENTRE
        0x1FB41: [.poly([(0.5, 0), (1, 0), (1, 1), (0, 1), (0, 0.333333)])], // LOWER RIGHT BLOCK DIAGONAL UPPER MIDDLE LEFT TO UPPER CENTRE
        0x1FB42: [.poly([(1, 0), (1, 1), (0, 1), (0, 0.333333)])], // LOWER RIGHT BLOCK DIAGONAL UPPER MIDDLE LEFT TO UPPER RIGHT
        0x1FB43: [.poly([(0.5, 0), (1, 0), (1, 1), (0, 1), (0, 0.666667)])], // LOWER RIGHT BLOCK DIAGONAL LOWER MIDDLE LEFT TO UPPER CENTRE
        0x1FB44: [.poly([(1, 0), (1, 1), (0, 1), (0, 0.666667)])], // LOWER RIGHT BLOCK DIAGONAL LOWER MIDDLE LEFT TO UPPER RIGHT
        0x1FB45: [.poly([(0.5, 0), (1, 0), (1, 1), (0, 1)])], // LOWER RIGHT BLOCK DIAGONAL LOWER LEFT TO UPPER CENTRE
        0x1FB46: [.poly([(1, 0.333333), (1, 1), (0, 1), (0, 0.666667)])], // LOWER RIGHT BLOCK DIAGONAL LOWER MIDDLE LEFT TO UPPER MIDDLE RIGHT
        0x1FB47: [.poly([(1, 0.666667), (1, 1), (0.5, 1)])], // LOWER RIGHT BLOCK DIAGONAL LOWER CENTRE TO LOWER MIDDLE RIGHT
        0x1FB48: [.poly([(1, 0.666667), (1, 1), (0, 1)])], // LOWER RIGHT BLOCK DIAGONAL LOWER LEFT TO LOWER MIDDLE RIGHT
        0x1FB49: [.poly([(1, 0.333333), (1, 1), (0.5, 1)])], // LOWER RIGHT BLOCK DIAGONAL LOWER CENTRE TO UPPER MIDDLE RIGHT
        0x1FB4A: [.poly([(1, 0.333333), (1, 1), (0, 1)])], // LOWER RIGHT BLOCK DIAGONAL LOWER LEFT TO UPPER MIDDLE RIGHT
        0x1FB4B: [.poly([(1, 0), (1, 1), (0.5, 1)])], // LOWER RIGHT BLOCK DIAGONAL LOWER CENTRE TO UPPER RIGHT
        0x1FB4C: [.poly([(0, 0), (0.5, 0), (1, 0.333333), (1, 1), (0, 1)])], // LOWER LEFT BLOCK DIAGONAL UPPER CENTRE TO UPPER MIDDLE RIGHT
        0x1FB4D: [.poly([(0, 0), (1, 0.333333), (1, 1), (0, 1)])], // LOWER LEFT BLOCK DIAGONAL UPPER LEFT TO UPPER MIDDLE RIGHT
        0x1FB4E: [.poly([(0, 0), (0.5, 0), (1, 0.666667), (1, 1), (0, 1)])], // LOWER LEFT BLOCK DIAGONAL UPPER CENTRE TO LOWER MIDDLE RIGHT
        0x1FB4F: [.poly([(0, 0), (1, 0.666667), (1, 1), (0, 1)])], // LOWER LEFT BLOCK DIAGONAL UPPER LEFT TO LOWER MIDDLE RIGHT
        0x1FB50: [.poly([(0, 0), (0.5, 0), (1, 1), (0, 1)])], // LOWER LEFT BLOCK DIAGONAL UPPER CENTRE TO LOWER RIGHT
        0x1FB51: [.poly([(1, 0.666667), (1, 1), (0, 1), (0, 0.333333)])], // LOWER LEFT BLOCK DIAGONAL UPPER MIDDLE LEFT TO LOWER MIDDLE RIGHT
        0x1FB52: [.poly([(0, 0), (1, 0), (1, 1), (0.5, 1), (0, 0.666667)])], // UPPER RIGHT BLOCK DIAGONAL LOWER MIDDLE LEFT TO LOWER CENTRE
        0x1FB53: [.poly([(0, 0), (1, 0), (1, 1), (0, 0.666667)])], // UPPER RIGHT BLOCK DIAGONAL LOWER MIDDLE LEFT TO LOWER RIGHT
        0x1FB54: [.poly([(0, 0), (1, 0), (1, 1), (0.5, 1), (0, 0.333333)])], // UPPER RIGHT BLOCK DIAGONAL UPPER MIDDLE LEFT TO LOWER CENTRE
        0x1FB55: [.poly([(0, 0), (1, 0), (1, 1), (0, 0.333333)])], // UPPER RIGHT BLOCK DIAGONAL UPPER MIDDLE LEFT TO LOWER RIGHT
        0x1FB56: [.poly([(0, 0), (1, 0), (1, 1), (0.5, 1)])], // UPPER RIGHT BLOCK DIAGONAL UPPER LEFT TO LOWER CENTRE
        0x1FB57: [.poly([(0, 0), (0.5, 0), (0, 0.333333)])], // UPPER LEFT BLOCK DIAGONAL UPPER MIDDLE LEFT TO UPPER CENTRE
        0x1FB58: [.poly([(0, 0), (1, 0), (0, 0.333333)])], // UPPER LEFT BLOCK DIAGONAL UPPER MIDDLE LEFT TO UPPER RIGHT
        0x1FB59: [.poly([(0, 0), (0.5, 0), (0, 0.666667)])], // UPPER LEFT BLOCK DIAGONAL LOWER MIDDLE LEFT TO UPPER CENTRE
        0x1FB5A: [.poly([(0, 0), (1, 0), (0, 0.666667)])], // UPPER LEFT BLOCK DIAGONAL LOWER MIDDLE LEFT TO UPPER RIGHT
        0x1FB5B: [.poly([(0, 0), (0.5, 0), (0, 1)])], // UPPER LEFT BLOCK DIAGONAL LOWER LEFT TO UPPER CENTRE
        0x1FB5C: [.poly([(0, 0), (1, 0), (1, 0.333333), (0, 0.666667)])], // UPPER LEFT BLOCK DIAGONAL LOWER MIDDLE LEFT TO UPPER MIDDLE RIGHT
        0x1FB5D: [.poly([(0, 0), (1, 0), (1, 0.666667), (0.5, 1), (0, 1)])], // UPPER LEFT BLOCK DIAGONAL LOWER CENTRE TO LOWER MIDDLE RIGHT
        0x1FB5E: [.poly([(0, 0), (1, 0), (1, 0.666667), (0, 1)])], // UPPER LEFT BLOCK DIAGONAL LOWER LEFT TO LOWER MIDDLE RIGHT
        0x1FB5F: [.poly([(0, 0), (1, 0), (1, 0.333333), (0.5, 1), (0, 1)])], // UPPER LEFT BLOCK DIAGONAL LOWER CENTRE TO UPPER MIDDLE RIGHT
        0x1FB60: [.poly([(0, 0), (1, 0), (1, 0.333333), (0, 1)])], // UPPER LEFT BLOCK DIAGONAL LOWER LEFT TO UPPER MIDDLE RIGHT
        0x1FB61: [.poly([(0, 0), (1, 0), (0.5, 1), (0, 1)])], // UPPER LEFT BLOCK DIAGONAL LOWER CENTRE TO UPPER RIGHT
        0x1FB62: [.poly([(0.5, 0), (1, 0), (1, 0.333333)])], // UPPER RIGHT BLOCK DIAGONAL UPPER CENTRE TO UPPER MIDDLE RIGHT
        0x1FB63: [.poly([(0, 0), (1, 0), (1, 0.333333)])], // UPPER RIGHT BLOCK DIAGONAL UPPER LEFT TO UPPER MIDDLE RIGHT
        0x1FB64: [.poly([(0.5, 0), (1, 0), (1, 0.666667)])], // UPPER RIGHT BLOCK DIAGONAL UPPER CENTRE TO LOWER MIDDLE RIGHT
        0x1FB65: [.poly([(0, 0), (1, 0), (1, 0.666667)])], // UPPER RIGHT BLOCK DIAGONAL UPPER LEFT TO LOWER MIDDLE RIGHT
        0x1FB66: [.poly([(0.5, 0), (1, 0), (1, 1)])], // UPPER RIGHT BLOCK DIAGONAL UPPER CENTRE TO LOWER RIGHT
        0x1FB67: [.poly([(0, 0), (1, 0), (1, 0.666667), (0, 0.333333)])], // UPPER RIGHT BLOCK DIAGONAL UPPER MIDDLE LEFT TO LOWER MIDDLE RIGHT
        0x1FB68: [.poly([(0, 0), (1, 0), (0.5, 0.5)]), .poly([(1, 0), (1, 1), (0.5, 0.5)]), .poly([(0, 1), (1, 1), (0.5, 0.5)])], // UPPER AND RIGHT AND LOWER TRIANGULAR THREE QUARTERS BLOCK
        0x1FB69: [.poly([(0, 0), (0.5, 0.5), (0, 1)]), .poly([(0, 1), (1, 1), (0.5, 0.5)]), .poly([(1, 0), (1, 1), (0.5, 0.5)])], // LEFT AND LOWER AND RIGHT TRIANGULAR THREE QUARTERS BLOCK
        0x1FB6A: [.poly([(0, 0), (1, 0), (0.5, 0.5)]), .poly([(0, 0), (0.5, 0.5), (0, 1)]), .poly([(0, 1), (1, 1), (0.5, 0.5)])], // UPPER AND LEFT AND LOWER TRIANGULAR THREE QUARTERS BLOCK
        0x1FB6B: [.poly([(0, 0), (0.5, 0.5), (0, 1)]), .poly([(0, 0), (1, 0), (0.5, 0.5)]), .poly([(1, 0), (1, 1), (0.5, 0.5)])], // LEFT AND UPPER AND RIGHT TRIANGULAR THREE QUARTERS BLOCK
        0x1FB6C: [.poly([(0, 0), (0.5, 0.5), (0, 1)])], // LEFT TRIANGULAR ONE QUARTER BLOCK
        0x1FB6D: [.poly([(0, 0), (1, 0), (0.5, 0.5)])], // UPPER TRIANGULAR ONE QUARTER BLOCK
        0x1FB6E: [.poly([(1, 0), (1, 1), (0.5, 0.5)])], // RIGHT TRIANGULAR ONE QUARTER BLOCK
        0x1FB6F: [.poly([(0, 1), (1, 1), (0.5, 0.5)])], // LOWER TRIANGULAR ONE QUARTER BLOCK
        0x1FB70: [.rect(0.125, 0, 0.25, 1, 1)], // VERTICAL ONE EIGHTH BLOCK-2
        0x1FB71: [.rect(0.25, 0, 0.375, 1, 1)], // VERTICAL ONE EIGHTH BLOCK-3
        0x1FB72: [.rect(0.375, 0, 0.5, 1, 1)], // VERTICAL ONE EIGHTH BLOCK-4
        0x1FB73: [.rect(0.5, 0, 0.625, 1, 1)], // VERTICAL ONE EIGHTH BLOCK-5
        0x1FB74: [.rect(0.625, 0, 0.75, 1, 1)], // VERTICAL ONE EIGHTH BLOCK-6
        0x1FB75: [.rect(0.75, 0, 0.875, 1, 1)], // VERTICAL ONE EIGHTH BLOCK-7
        0x1FB76: [.rect(0, 0.125, 1, 0.25, 1)], // HORIZONTAL ONE EIGHTH BLOCK-2
        0x1FB77: [.rect(0, 0.25, 1, 0.375, 1)], // HORIZONTAL ONE EIGHTH BLOCK-3
        0x1FB78: [.rect(0, 0.375, 1, 0.5, 1)], // HORIZONTAL ONE EIGHTH BLOCK-4
        0x1FB79: [.rect(0, 0.5, 1, 0.625, 1)], // HORIZONTAL ONE EIGHTH BLOCK-5
        0x1FB7A: [.rect(0, 0.625, 1, 0.75, 1)], // HORIZONTAL ONE EIGHTH BLOCK-6
        0x1FB7B: [.rect(0, 0.75, 1, 0.875, 1)], // HORIZONTAL ONE EIGHTH BLOCK-7
        0x1FB7C: [.rect(0, 0, 0.125, 1, 1), .rect(0, 0.875, 1, 1, 1)], // LEFT AND LOWER ONE EIGHTH BLOCK
        0x1FB7D: [.rect(0, 0, 0.125, 1, 1), .rect(0, 0, 1, 0.125, 1)], // LEFT AND UPPER ONE EIGHTH BLOCK
        0x1FB7E: [.rect(0.875, 0, 1, 1, 1), .rect(0, 0, 1, 0.125, 1)], // RIGHT AND UPPER ONE EIGHTH BLOCK
        0x1FB7F: [.rect(0.875, 0, 1, 1, 1), .rect(0, 0.875, 1, 1, 1)], // RIGHT AND LOWER ONE EIGHTH BLOCK
        0x1FB80: [.rect(0, 0, 1, 0.125, 1), .rect(0, 0.875, 1, 1, 1)], // UPPER AND LOWER ONE EIGHTH BLOCK
        0x1FB81: [.rect(0, 0, 1, 0.125, 1), .rect(0, 0.25, 1, 0.375, 1), .rect(0, 0.5, 1, 0.625, 1), .rect(0, 0.875, 1, 1, 1)], // HORIZONTAL ONE EIGHTH BLOCK-1358
        0x1FB82: [.rect(0, 0, 1, 0.25, 1)], // UPPER ONE QUARTER BLOCK
        0x1FB83: [.rect(0, 0, 1, 0.375, 1)], // UPPER THREE EIGHTHS BLOCK
        0x1FB84: [.rect(0, 0, 1, 0.625, 1)], // UPPER FIVE EIGHTHS BLOCK
        0x1FB85: [.rect(0, 0, 1, 0.75, 1)], // UPPER THREE QUARTERS BLOCK
        0x1FB86: [.rect(0, 0, 1, 0.875, 1)], // UPPER SEVEN EIGHTHS BLOCK
        0x1FB87: [.rect(0.75, 0, 1, 1, 1)], // RIGHT ONE QUARTER BLOCK
        0x1FB88: [.rect(0.625, 0, 1, 1, 1)], // RIGHT THREE EIGHTHS BLOCK
        0x1FB89: [.rect(0.375, 0, 1, 1, 1)], // RIGHT FIVE EIGHTHS BLOCK
        0x1FB8A: [.rect(0.25, 0, 1, 1, 1)], // RIGHT THREE QUARTERS BLOCK
        0x1FB8B: [.rect(0.125, 0, 1, 1, 1)], // RIGHT SEVEN EIGHTHS BLOCK
        0x1FB8C: [.rect(0, 0, 0.5, 1, 0.5)], // LEFT HALF MEDIUM SHADE
        0x1FB8D: [.rect(0.5, 0, 1, 1, 0.5)], // RIGHT HALF MEDIUM SHADE
        0x1FB8E: [.rect(0, 0, 1, 0.5, 0.5)], // UPPER HALF MEDIUM SHADE
        0x1FB8F: [.rect(0, 0.5, 1, 1, 0.5)], // LOWER HALF MEDIUM SHADE
        0x1FB90: [.rect(0, 0, 1, 1, 0.5)], // INVERSE MEDIUM SHADE
        0x1FB91: [.rect(0, 0, 1, 0.5, 1), .rect(0, 0.5, 1, 1, 0.5)], // UPPER HALF BLOCK AND LOWER HALF INVERSE MEDIUM SHADE
        0x1FB92: [.rect(0, 0, 1, 0.5, 0.5), .rect(0, 0.5, 1, 1, 1)], // UPPER HALF INVERSE MEDIUM SHADE AND LOWER HALF BLOCK
        0x1FB94: [.rect(0, 0, 0.5, 1, 0.5), .rect(0.5, 0, 1, 1, 1)], // LEFT HALF INVERSE MEDIUM SHADE AND RIGHT HALF BLOCK
        0x1FB9A: [.poly([(0, 0), (1, 0), (0.5, 0.5)]), .poly([(0, 1), (1, 1), (0.5, 0.5)])], // UPPER AND LOWER TRIANGULAR HALF BLOCK
        0x1FB9B: [.poly([(0, 0), (0.5, 0.5), (0, 1)]), .poly([(1, 0), (1, 1), (0.5, 0.5)])], // LEFT AND RIGHT TRIANGULAR HALF BLOCK
    ]
}

extension TerminalRenderer {
    /// A legacy computing symbol's pieces as quads: rectangles as they are, polygons a pixel row
    /// at a time (each row's span where its middle crosses the polygon), as powerline's
    /// triangles are drawn, so wedges meet their neighbors' edges on the same pixels.
    func legacy(_ pieces: [LegacyComputing.Piece], left: Float, top: Float, width: Float, height: Float,
                rect: (Float, Float, Float, Float, Float) -> Void) {
        for piece in pieces {
            switch piece {
            case .rect(let x0, let y0, let x1, let y1, let alpha):
                rect(left + x0 * width, top + y0 * height, left + x1 * width, top + y1 * height, alpha)
            case .poly(let points):
                let pts = points.map { (left + $0.0 * width, top + $0.1 * height) }
                guard let minY = pts.map(\.1).min(), let maxY = pts.map(\.1).max() else { continue }
                var y = minY.rounded()
                while y < maxY.rounded() {
                    let middle = y + 0.5
                    var low = Float.infinity, high = -Float.infinity
                    for i in pts.indices {
                        let a = pts[i], b = pts[(i + 1) % pts.count]
                        guard (a.1 <= middle && b.1 >= middle) || (b.1 <= middle && a.1 >= middle), a.1 != b.1 else { continue }
                        let x = a.0 + (middle - a.1) / (b.1 - a.1) * (b.0 - a.0)
                        low = min(low, x); high = max(high, x)
                    }
                    if low < high { rect(low, y, high, y + 1, 1) }
                    y += 1
                }
            }
        }
    }
}
