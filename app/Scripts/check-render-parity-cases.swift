// Fixed inputs for check-render-parity.sh. Every payload starts by hiding the cursor and
// homing, so a case is a pure function of its bytes (see check-render-parity-capture.swift on
// why the cursor must be hidden). Rows are joined with CR LF, never a trailing one, so the
// screen never scrolls and row N of the payload is row N of the grid.
let ESC = "\u{1b}"
let header = "\(ESC)[?25l\(ESC)[2J\(ESC)[H"
func screen(_ rows: [String]) -> String { header + rows.joined(separator: "\r\n") }

/// The audit's C1 and its one-character twin C1x: `>` at column 38 of row 0 becomes `!`.
let asciiRows = ["The quick brown fox 0123456789 {}[]()<>",
                 "ab                       cd",
                 "~!@#$%^&*_+-=;:'\",./?\\` jumps over the lazy dog",
                 "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz"]
let ascii = screen(asciiRows)
let asciiOneCharChanged = screen(["The quick brown fox 0123456789 {}[]()<!"] + asciiRows.dropFirst())
let changedCell = (col: 38, row: 0)

func boxFrame() -> [String] {
    let w = gridCols, l = w / 2 - 1, r = w - w / 2 - 2
    func rule(_ a: String, _ m: String, _ b: String, _ f: String) -> String {
        a + String(repeating: f, count: l) + m + String(repeating: f, count: r) + b
    }
    func full(_ a: String, _ f: String, _ b: String) -> String { a + String(repeating: f, count: w - 2) + b }
    return [rule("┌", "┬", "┐", "─"), rule("│", "│", "│", " "), rule("├", "┼", "┤", "─"),
            rule("└", "┴", "┘", "─"), full("╔", "═", "╗"), full("║", " ", "║"), full("╚", "═", "╝"),
            full("┏", "━", "┓"), full("┃", " ", "┃"), full("┗", "━", "┛"), full("╭", "─", "╮"),
            full("╰", "─", "╯")]
}
let box = screen(boxFrame())

let blocks = screen(["█▀▄▌▐░▒▓", "▁▂▃▄▅▆▇█", "████████", "▀▀▀▀▄▄▄▄", "▏▎▍▌▋▊▉█"])

let cjk = screen(["日本語テキスト 한국어 中文 ASCII after", "AB日CD", "「引用」、句読点。全角ＡＢＣ"])

/// Every SGR attribute the audit's C7 exercised, one per row.
let sgrParts: [(String, String)] = [("1", "bold"), ("3", "italic"), ("1;3", "bolditalic"), ("2", "dim"),
    ("7", "inverse"), ("4", "underline"), ("4:2", "double"), ("4:3", "curly"), ("4:4", "dotted"),
    ("4:5", "dashed"), ("4;58;2;255;0;0", "redunderline"), ("9", "strike"), ("31;42", "red-on-green")]
let sgr = screen(sgrParts.map { "\(ESC)[\($0.0)m\($0.1) text\(ESC)[0m" })

/// N4's subject. Row 0 puts four colour emoji at columns 0, 4, 8 and 12 (two cells each,
/// two blank cells between) so each 2-cell slot can be measured on its own.
let emoji = screen(["😀  👍  ✅  🎉  ", "😀x😀y", "AB😀CD"])
let emojiSlots = [0, 4, 8, 12]

/// Determinism input: a little of every class at once.
let mixed = screen(["The quick brown fox {}[]()<>", "┌──┬──┐ █▀▄ 日本語", "\(ESC)[1;4mbold\(ESC)[0m 😀 ✅"])

/// F10 (fixed by patch 0013, #151): a combining mark after a WIDE char. Buffer is right
/// (`[0:w2 65E5+0301] [1:w0]`). With 0013 both renderers draw the mark over the CJK glyph.
let f10 = screen(["日\u{0301}x", "中\u{0308}\u{0301}y"])

/// N5: Metal's `|` paints one pixel line into the next row. Row 1 is left EMPTY on purpose.
let n5 = screen(["|||| a|b", ""])
