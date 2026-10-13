import PopulousAssets
import PopulousCore

/// A button on the bottom edge of a dialog box. Drawing the box fills in where it
/// ended up, for hit-testing ($675D0).
public struct DialogButton: Sendable {
    public var text: String
    public var x = 0
    public var y = 0
    public var right = 0

    public init(_ text: String) { self.text = text }

    public func contains(x px: Int, y py: Int) -> Bool {
        px >= x && px <= right && py >= y && py <= y + 16
    }
}

/// What the "world to conquer" box says about a world ($676AC).
public struct WorldBrief: Sendable {
    public var name: String
    /// Typed so far, when the name is being entered; the box then shows only this.
    public var entry: (text: String, cursorOn: Bool, message: String)?
    public var worldNumber: Int
    public var level: LevelRecord

    public init(name: String, worldNumber: Int, level: LevelRecord) {
        self.name = name
        self.worldNumber = worldNumber
        self.level = level
    }
}

extension Renderer {
    /// Characters of the name field: an empty cell and the cursor.
    static let fieldCell: UInt8 = 0x82
    static let fieldCursor: UInt8 = 0x83
    /// Longest world name that can be typed, one less than the field.
    public static let nameLimit = 15

    /// Text in the game's 8x8 font ($6CD32). `x` is rounded down to a whole byte
    /// column; a newline moves down eight rows.
    func drawText(_ bytes: [UInt8], x: Int, y: Int, into screen: inout IndexedImage) {
        var column = x >> 3, row = y
        for byte in bytes {
            if byte == 0x0A {
                row += 8
                column = x >> 3
                continue
            }
            let glyph = Int(byte) - 0x20
            if assets.font.indices.contains(glyph) { screen.draw(assets.font[glyph], x: column * 8, y: row) }
            column += 1
        }
    }

    func drawText(_ text: String, x: Int, y: Int, into screen: inout IndexedImage) {
        drawText(Array(text.utf8), x: x, y: y, into: &screen)
    }

    /// A dialog box built from 16x16 pieces, with one or two buttons along its
    /// bottom edge ($65B04). Returns the buttons with their positions filled in.
    func drawBox(
        x: Int, y: Int, width: Int, height: Int, buttons: [DialogButton], into screen: inout IndexedImage
    ) -> [DialogButton] {
        var buttons = buttons
        let column = x >> 4, columns = width >> 4
        func piece(_ offset: Int, _ row: Int, _ block: Int) {
            screen.draw(assets.shieldBlocks[block], x: (column + offset) * 16, y: row)
        }
        func half(_ button: DialogButton) -> Int { button.text.utf8.count >> 1 }

        piece(0, y, 0xC)
        var d6 = 1
        while d6 < columns - 1 {
            piece(d6, y, 0xD)
            d6 += 1
        }
        piece(d6, y, 0xE)
        var row = y + 16
        while row < y + height - 16 {
            piece(0, row, 0x12)
            var d7 = 1
            while d7 < columns - 1 {
                piece(d7, row, 0x14)
                d7 += 1
            }
            piece(d7, row, 0x13)
            row += 16
        }
        piece(0, row, 0xF)

        var d7 = 1
        // A button: left end, a piece for every two letters, right end.
        func button(_ index: Int) {
            buttons[index].x = (column + d7) << 4
            buttons[index].y = row
            piece(d7, row, 0x15)
            d7 += 1
            for _ in 0..<half(buttons[index]) {
                piece(d7, row, 0x16)
                d7 += 1
            }
            piece(d7, row, 0x17)
            d7 += 1
            buttons[index].right = (buttons[index].text.utf8.count + 4) * 8 + buttons[index].x
        }
        func plain(until limit: Int) {
            while d7 < limit {
                piece(d7, row, 0x10)
                d7 += 1
            }
        }
        if buttons.count > 1 {
            button(0)
            plain(until: columns - half(buttons[1]) - 3)
            button(1)
        } else {
            plain(until: columns >> 1 - half(buttons[0]) >> 1 - 1)
            button(0)
            plain(until: columns - 1)
        }
        piece(d7, row, 0x11)
        for button in buttons {
            drawText(button.text, x: button.x + 0x10, y: row + 3, into: &screen)
        }
        return buttons
    }

    /// The score box drawn over the game when a world is decided ($68CA2).
    public func drawScore(
        _ summary: ScoreSummary, won: Bool, newGame: Bool, into screen: inout IndexedImage
    ) -> [DialogButton] {
        let text = assets.dialogs
        // Won worlds lead on to the next one; a lost conquest world is played
        // again. A custom game always offers a new one.
        let buttons = drawBox(
            x: 0x10, y: 0x10, width: 0x120, height: 0xA6, buttons: [DialogButton(newGame ? text.newGame : text.tryAgain)],
            into: &screen)
        func label(_ line: Int, _ length: Int) -> String {
            let head = String(text.score[line].text.prefix(length))
            return head + String(repeating: " ", count: length - head.count)
        }
        // Two numbers: the first padded to five characters, the second straight after.
        func pair(_ values: (Int, Int)) -> String {
            let first = String(values.0)
            return first + String(repeating: " ", count: max(5 - first.count, 0)) + String(values.1)
        }
        var lines = text.score.map(\.text)
        lines[0] = label(0, 5) + (won ? text.won : text.lost)
        lines[2] = label(2, 0x13) + pair(summary.battles)
        lines[3] = label(3, 0x13) + pair(summary.knights)
        lines[4] = label(4, 0x13) + pair(summary.towns)
        lines[5] = label(5, 0x13) + pair(summary.castles)
        lines[6] = label(6, 0x13) + String(summary.score)
        for (line, string) in zip(text.score, lines) {
            drawText(string, x: line.x + 0x10, y: line.y + 0x10, into: &screen)
        }
        return buttons
    }

    /// The "world to conquer" box ($676AC): the world's name and what to expect
    /// there, or just the name field while a name is being typed.
    public func drawWorldBox(_ brief: WorldBrief, into screen: inout IndexedImage) -> [DialogButton] {
        let text = assets.dialogs
        let buttons = drawBox(
            x: 0x10, y: 0x18, width: 0x120, height: 0xA0,
            buttons: [DialogButton(text.startGame), DialogButton(text.newGame)], into: &screen)
        func draw(_ string: String, line: Int, offset: Int = 0x10) {
            drawText(string, x: text.world[line].x + offset, y: text.world[line].y + 0x18, into: &screen)
        }
        draw(text.world[0].text, line: 0)
        drawText([UInt8](repeating: Self.fieldCell, count: 19), x: 0x20, y: 0x2C, into: &screen)

        if let entry = brief.entry {
            var field = Array(entry.text.utf8.prefix(Self.nameLimit))
            field.append(entry.cursorOn ? Self.fieldCursor : Self.fieldCell)
            field += [UInt8](repeating: Self.fieldCell, count: Self.nameLimit + 1 - field.count)
            drawText(field, x: 0x20, y: 0x2C, into: &screen)
            if !entry.message.isEmpty { draw(entry.message, line: 1) }
            return buttons
        }
        drawText(brief.name, x: 0x20, y: 0x2C, into: &screen)

        let level = brief.level
        let flags = level.ruleFlags
        let facts: [Int: String] = [
            1: String(brief.worldNumber / 5),
            2: text.words[level.terrain & 3],
            3: text.words[min(max((10 - level.period) >> 1, 0), 4) + 4],
            4: text.words[min(max((10 - level.skill) >> 1, 0), 4) + 9],
            5: text.words[flags & 4 != 0 ? 14 : flags & 0x10 != 0 ? 15 : flags & 8 != 0 ? 16 : 17],
            6: text.words[flags & 2 != 0 ? 19 : 18],
            7: text.words[flags & 1 != 0 ? 21 : 20],
        ]
        for line in 1..<15 {
            let record = text.world[line]
            switch line {
            case 1...7:
                // The fact goes straight after the label's own characters.
                let head = String(record.text.prefix(record.column))
                draw(head + String(repeating: " ", count: record.column - head.count) + (facts[line] ?? ""), line: line)
                continue
            case 9:
                draw(String(level.startingPeople.top), line: line, offset: record.column + 0x10)
                draw(String(level.startingPeople.bottom), line: line, offset: record.column + 0x48)
            case 10...14:
                let bit = 1 << (line - 10)
                draw(text.words[level.playerPowers & bit != 0 ? 22 : 23], line: line, offset: record.column + 0x10)
                draw(text.words[level.computerPowers & bit != 0 ? 22 : 23], line: line, offset: record.column + 0x48)
            default: break
            }
            draw(record.text, line: line)
        }
        return buttons
    }

    /// The two lines the lord says after a conquest ($691F8). `next` is nil when
    /// the last world has just fallen.
    public func lordLines(conquered: Int, next: Int?, names: Conquest.Names) -> [String] {
        let words = assets.dialogs.words
        guard let next else {
            // (The original names the world a seed of 0 gives here, not Genesis.)
            return [words[37], words[38] + names.generatedName(seed: 0)]
        }
        return [
            words[34] + words[24 + min(next / 250, 9)] + words[35],
            names.name(ofWorld: conquered) + words[36] + names.name(ofWorld: next),
        ]
    }

    /// The lord's screen: his picture (in its own palette), what he says along the
    /// bottom, his mouth, and after the final victory his winking eyes.
    public func lordScreen(lines: [String], mouth: Int, eyes: Bool) -> IndexedImage {
        var screen = assets.lord.image
        for (index, line) in lines.prefix(2).enumerated() {
            drawText(line, x: 8, y: 0xB2 + index * 8, into: &screen)
        }
        if eyes, assets.mouths.count > 5 { screen.draw(assets.mouths[5], x: 0x10 * 8, y: 0x4B) }
        if assets.mouths.indices.contains(mouth) { screen.draw(assets.mouths[mouth], x: 0x12 * 8, y: 0x87) }
        return screen
    }

    /// The three buttons painted on the title picture.
    public enum TitleChoice: Sendable {
        case tutorial, conquest, custom
    }

    /// The button under a screen point on the title picture, as the disk's intro
    /// program (`populous`, its routine at $10456) tests the mouse.
    public static func titleChoice(atX x: Int, y: Int) -> TitleChoice? {
        if (0x9C...0xA9).contains(y), x >= 0xE7 { return .tutorial }
        if (0xAA...0xB7).contains(y), x >= 0xE7 { return .conquest }
        if y > 0xB7, x > 0xF0 { return .custom }
        return nil
    }

    /// Which of the game's option dialogs, with what it shows.
    public enum OptionsBox: Sendable {
        /// "Options for good/evil" ($68792): one side's abilities, aggression, rate.
        case side(Int, World.Options)
        /// "Set game options" ($684D6): the five rules of the land.
        case rules(Int)
        /// "Game setup" ($67DA2); `conquest` ticks Conquest rather than Custom game.
        case setup(conquest: Bool)
    }

    private func layout(_ box: OptionsBox) -> (items: [DialogText.Item], x: Int, y: Int) {
        let text = assets.dialogs
        switch box {
        case .side: return (text.sideOptions, 0x10, 0x10)
        case .rules: return (text.gameOptions, 0x20, 0x18)
        case .setup: return (text.setup, 0x10, 0x10)
        }
    }

    /// The rows of the rules dialog on show: of each pair, the one in force.
    private func ruleRows(_ flags: Int) -> [Int] {
        (0..<5).map { 1 + $0 * 2 + (flags & (1 << $0) != 0 ? 1 : 0) }
    }

    /// Draws an options dialog with its OK and CANCEL buttons.
    public func drawOptions(_ box: OptionsBox, into screen: inout IndexedImage) -> [DialogButton] {
        let text = assets.dialogs
        let (items, left, top) = layout(box)
        let buttons = [DialogButton(text.ok), DialogButton(text.cancel)]
        func draw(_ bytes: [UInt8], item: Int, shift: Int = 0) {
            drawText(bytes, x: items[item].x + left + shift, y: items[item].y + top, into: &screen)
        }
        switch box {
        case .side(let side, let options):
            let placed = drawBox(x: 0x10, y: 0x10, width: 0x120, height: 0xA6, buttons: buttons, into: &screen)
            draw(Array(items[0].text.prefix(12)) + Array((side == 0 ? text.good : text.evil).utf8), item: 0)
            for item in 1..<14 {
                var bytes = items[item].text
                if item < 10 { bytes[0] = options.abilities[side] & (1 << (item - 1)) != 0 ? 0x81 : 0x80 }
                draw(bytes, item: item)
            }
            // The sliders show ten minus what is stored.
            draw([0x87], item: 11, shift: (10 - options.skill[side]) * 8 + 0x18)
            draw([0x87], item: 13, shift: (10 - options.period[side]) * 8 + 0x20)
            return placed
        case .rules(let flags):
            let placed = drawBox(x: 0x20, y: 0x18, width: 0x100, height: 0x70, buttons: buttons, into: &screen)
            draw(items[0].text, item: 0)
            for row in ruleRows(flags) { draw(items[row].text, item: row) }
            return placed
        case .setup(let conquest):
            let placed = drawBox(x: 0x10, y: 0x10, width: 0x120, height: 0xB0, buttons: buttons, into: &screen)
            // One player, playing (not painting), as good, human against the computer.
            let ticked: Set<Int> = [1, 3, 5, 7, conquest ? 9 : 10]
            for item in 0..<17 {
                var bytes = items[item].text
                if item > 0 { bytes[0] = ticked.contains(item) ? 0x81 : 0x80 }
                draw(bytes, item: item)
            }
            return placed
        }
    }

    /// The line of an options dialog under a screen point, and for a slider the
    /// position clicked (0...9), as the original tests the mouse ($68792).
    public func optionsItem(_ box: OptionsBox, atX px: Int, y py: Int) -> (item: Int, value: Int)? {
        let (items, left, top) = layout(box)
        var rows = Array(1..<items.count)
        if case .rules(let flags) = box { rows = ruleRows(flags) }
        for row in rows {
            let item = items[row]
            guard px >= item.x + left, px <= item.x + item.width + left, py >= item.y + top, py <= item.y + top + 8
            else { continue }
            if case .side = box, row == 11 || row == 13 {
                let value = (px - (item.x + (row == 11 ? 0x28 : 0x30))) / 8
                return (0...9).contains(value) ? (row, value) : nil
            }
            return (row, 0)
        }
        return nil
    }
}
