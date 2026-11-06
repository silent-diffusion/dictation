import CoreGraphics

/// How the overlay pill's row shares its width (OverlayViews.swift's PillGrid). Each column has its own width; the star
/// column (the meter, subtitle or dots) takes what is left. Windows lays the row out at a fixed width and clips what
/// doesn't fit; the Mac asks for the room the columns need, so a profile or model name of any normal length shows whole.
/// Only when even that room is short (an iPhone, a huge name) columns give way: first the words that can drop out
/// (the decor word, CANCEL), whole; then the widest of the title and chip, which end in "…", down to 40.
public enum PillRowFit {
    /// The longest the title and the chip get before they end in "…": far more than any normal profile or model name.
    /// The chip (11 pt Cascadia Mono, 6.6 pt a character) holds about 48 characters; the title (13 pt) "PROFILE   " or
    /// "TIDYING // " and a name of about 45.
    public static let titleCap: CGFloat = 440, chipCap: CGFloat = 320
    public struct Column: Equatable {
        /// The column's own width.
        public var width: CGFloat
        /// 0: keeps its width. 1: drops to `least` (a word that goes whole). 2: shrinks towards `least`, text ending in "…".
        public var shrink: Int
        /// The narrowest it gets.
        public var least: CGFloat

        public init(width: CGFloat, shrink: Int = 0, least: CGFloat = 0) {
            self.width = width
            self.shrink = shrink
            self.least = shrink == 2 ? max(least, min(40, width)) : least
        }
    }

    /// The width the row asks for: every column at its own width, and the star column's `star` (its content, or a share
    /// of it for the meter), at most `limit`; at least `proposed`.
    public static func width(_ columns: [Column], star: CGFloat, proposed: CGFloat, limit: CGFloat) -> CGFloat {
        let need = (columns.reduce(0) { $0 + $1.width } + star).rounded(.up)
        return min(max(proposed, need), limit)
    }

    /// Each column's width in a row `width` wide, and what is left for the star column.
    public static func widths(_ columns: [Column], in width: CGFloat) -> (columns: [CGFloat], star: CGFloat) {
        var sizes = columns.map(\.width)
        var short = sizes.reduce(0, +) - width
        for level in [1, 2] where short > 0.5 {
            while short > 0.5 {
                guard let i = sizes.indices.filter({ columns[$0].shrink == level && sizes[$0] > columns[$0].least + 0.5 })
                    .max(by: { sizes[$0] < sizes[$1] }) else { break }
                // A word that drops out goes whole; a name gives up only what is missing.
                let give = level == 1 ? sizes[i] - columns[i].least : min(short, sizes[i] - columns[i].least)
                sizes[i] -= give
                short -= give
            }
        }
        return (sizes, max(0, width - sizes.reduce(0, +)))
    }
}
