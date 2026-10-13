import PopulousAssets

/// The animated demo the title screen falls into when left alone, ported from the
/// disk's `populous` program ($11186). A patch of land drops into place over the
/// demo picture, the name board falls in and flies off, and then sixteen scripted
/// figures act out a little game while the credits scroll past.
///
/// `step` advances one pass of the original's loop and returns the screen.
public struct TitleDemo: Sendable {
    /// Seconds between passes. (The original runs as fast as an Amiga draws it;
    /// two display frames a pass is an estimate.)
    public static let stepSeconds = 0.04

    enum Stage {
        case land, boardDown, boardUp, figuresDrop, scene
    }

    struct Figure {
        var sprite: Int
        var pc = 0
        var frame = 0
        var direction = 8
        var cell: Int
        var aux: Int
        var flag: Int
    }

    let assets: GameAssets
    var data: DemoData { assets.demoData }
    var stage = Stage.land
    var seed: UInt32
    /// Height above its resting place, and falling speed, of each dropping thing.
    var drop = [Int](repeating: 0, count: 100)
    var speed = [Int](repeating: 0, count: 100)
    /// The picture with the land on it, and the same plus what has been built.
    var backdrop: IndexedImage
    var built: IndexedImage
    var screen: IndexedImage
    var phase = 0
    var figures: [Figure] = []
    /// Things the figures have built, in cell order: (cell, tile).
    var buildings: [(cell: Int, tile: Int)] = []
    var rebuild = false
    /// How far each corner picture has faded in.
    var logoLevel = [0, 0]
    var counter = 0
    /// The two credit lines on screen: what each says and its row.
    var lines: [[UInt8]] = [[], []]
    var rows = [0x4B, 0x32]
    var nextCredit = 0

    public init(assets: GameAssets) {
        self.assets = assets
        seed = assets.demoData.randomSeed
        backdrop = assets.demo.image
        built = backdrop
        screen = backdrop
        scatter(100)
    }

    /// The C library's `rand` ($16538).
    mutating func random() -> Int {
        seed = seed &* 1_103_515_245 &+ 12345
        return Int(seed >> 16) & 0x7FFF
    }

    /// Lifts `count` things to a random height with a random speed ($110A2).
    mutating func scatter(_ count: Int) {
        for index in 0..<count {
            drop[index] = random() % 13 + 0xE8
            speed[index] = random() % 9
        }
    }

    /// Lets them fall and bounce ($1110A); false once all have come to rest.
    mutating func fall(_ count: Int) -> Bool {
        var moving = 0
        for index in 0..<count {
            var velocity = speed[index] + 1
            var height = drop[index] - velocity
            if height < 0 {
                velocity = -(velocity / 2)
                height = 0
            }
            if moving == 0 { moving = velocity }
            drop[index] = height
            speed[index] = velocity
        }
        return moving != 0
    }

    // MARK: Drawing

    /// The original's blits skip anything that starts above the screen.
    func draw(_ picture: IndexedImage, x: Int, y: Int, into target: inout IndexedImage) {
        if y >= 0 { target.draw(picture, x: x, y: y) }
    }

    func drawTile(_ tile: Int, x: Int, y: Int, into target: inout IndexedImage) {
        let tiles = assets.landSets[0].tiles
        if tiles.indices.contains(tile) { draw(tiles[tile], x: x, y: y, into: &target) }
    }

    /// The land, each tile lifted by its drop ($11C12).
    func drawLand(into target: inout IndexedImage) {
        for row in 0..<10 {
            for column in 0..<10 {
                let cell = row * 10 + column
                let x = (column - row) * 16 + 0x90
                let y = (column + row) * 8 - data.heights[cell] + 0x20 - drop[cell]
                drawTile(data.tiles[cell], x: x, y: y, into: &target)
                if data.objects[cell] != 0 { drawTile(data.objects[cell], x: x, y: y - 8, into: &target) }
            }
        }
    }

    /// The name board: its three kinds of plank, then the eight letters ($10E40).
    func drawBoard(y: (Int) -> Int, into target: inout IndexedImage) {
        let letters = data.letters
        draw(letters[5], x: 0x50, y: y(0), into: &target)
        for index in 1...8 { draw(letters[6], x: 0x50 + index * 16, y: y(index), into: &target) }
        draw(letters[7], x: 0xE0, y: y(9), into: &target)
        for index in 0..<8 where letters.indices.contains(data.letterOrder[index]) {
            draw(letters[data.letterOrder[index]], x: 0x60 + index * 16, y: y(index), into: &target)
        }
    }

    /// Step offsets and sprite offsets of the eight directions on the 10-wide grid.
    static let steps: [Int: (dx: Int, dy: Int, sprite: Int)] = [
        -11: (0, -2, 0), -10: (2, -1, 2), -9: (4, 0, 4), 1: (2, 1, 6),
        11: (0, 2, 8), 10: (-2, 1, 10), 9: (-4, 0, 12), -1: (-2, -1, 14),
    ]

    /// A figure on its cell, part-way through a step ($150B2).
    func drawFigure(
        cell: Int, direction: Int, sprite: Int, frame: Int, lift: Int, flag: Int, into target: inout IndexedImage
    ) {
        guard data.heights.indices.contains(cell) else { return }
        let column = cell % 10, row = cell / 10
        var x = (column - row) * 16 + 0x98
        var y = (column + row) * 8 + 0x1C - lift - data.heights[cell]
        let ahead = cell + direction
        if data.heights.indices.contains(ahead) {
            y += ((data.heights[cell] - data.heights[ahead]) * frame) >> 3
        }
        let step = Self.steps[direction] ?? (0, 0, 8)
        x += step.dx * frame
        y += step.dy * frame
        var picture = sprite
        if flag != 0 {
            picture += phase
        } else if sprite < 0x40 {
            picture += step.sprite + phase
        }
        if assets.sprites.indices.contains(picture) { draw(assets.sprites[picture], x: x, y: y, into: &target) }
    }

    /// Whether a fade pattern lets the pixel at `x` of the `word`th 16-pixel group
    /// through at a level ($15026, $13F92).
    func shows(level: Int, word: Int, x: Int) -> Bool {
        let at = level * 2 + [2, 4, 0][word % 3]
        guard at >= 0 else { return false }
        guard at + 1 < data.dither.count else { return true }
        let bits = UInt16(data.dither[at]) << 8 | UInt16(data.dither[at + 1])
        return (bits >> UInt16(15 - x & 15)) & 1 == 0
    }

    /// A corner picture, faded in as far as `level` ($13F92).
    func drawLogo(_ index: Int, level: Int, into target: inout IndexedImage) {
        let logo = data.logos[index]
        let left = index == 0 ? 0 : 256
        for y in 0..<64 {
            for x in 0..<64 where shows(level: level, word: y * 4 + x >> 4, x: x) {
                target[left + x, y] = logo[x, y]
            }
        }
    }

    /// A line of credits, centred, faded by its row ($11D1A, $15026).
    func drawCredit(_ text: [UInt8], row: Int, into target: inout IndexedImage) {
        var level = row > 0x19 ? 0x32 - row : row
        if level < 0 { level = 0 }
        let start = (40 - text.count) / 2
        for (index, byte) in text.enumerated() {
            let glyph = Int(byte) - 0x20
            guard assets.font.indices.contains(glyph) else { continue }
            let picture = assets.font[glyph]
            for y in 0..<8 where (0..<target.height).contains(row + y) {
                for x in 0..<8 {
                    let px = (start + index) * 8 + x
                    guard (0..<target.width).contains(px), picture[x, y] != IndexedImage.transparent,
                        shows(level: level, word: y * 20 + px >> 4, x: px)
                    else { continue }
                    target[px, row + y] = picture[x, y]
                }
            }
        }
    }

    // MARK: Stepping

    /// One pass of the demo; returns the screen to show.
    public mutating func step() -> IndexedImage {
        switch stage {
        case .land:
            if fall(100) {
                screen = backdrop
                drawLand(into: &screen)
            } else {
                // What is on screen becomes the backdrop for everything after.
                backdrop = screen
                built = screen
                scatter(18)
                stage = .boardDown
            }
        case .boardDown:
            if fall(18) {
                screen = built
                let heights = drop
                drawBoard(y: { 0xA8 - heights[$0] }, into: &screen)
            } else {
                for index in 0..<18 {
                    drop[index] = 0xA0
                    speed[index] = random() & 7
                }
                stage = .boardUp
            }
        case .boardUp:
            if fall(18) {
                screen = built
                let heights = drop
                drawBoard(y: { heights[$0] + 8 }, into: &screen)
            } else {
                beginScene()
            }
        case .figuresDrop:
            phase ^= 1
            let moving = fall(16)
            screen = built
            for index in [0, 1, 7, 8] {
                let figure = figures[index]
                drawFigure(
                    cell: figure.cell, direction: figure.direction, sprite: figure.sprite, frame: figure.frame,
                    lift: drop[index], flag: 0, into: &screen)
            }
            if !moving { stage = .scene }
        case .scene:
            scenePass()
        }
        return screen
    }

    /// Sets the figures on their starting cells and drops the first four in
    /// ($10536).
    mutating func beginScene() {
        rows = [0x4B, 0x32]
        counter = 0
        buildings = []
        figures = data.actors.map { Figure(sprite: $0.sprite, cell: $0.cell, aux: $0.aux, flag: $0.flag) }
        built = backdrop
        scatter(16)
        stage = .figuresDrop
    }

    /// One pass of the scripted scene ($10714).
    mutating func scenePass() {
        phase ^= 1
        screen = built
        for line in 0..<2 {
            if rows[line] == 0x32 {
                lines[line] = data.credits.isEmpty ? [] : data.credits[nextCredit]
                nextCredit = (nextCredit + 1) % max(data.credits.count, 1)
            }
            drawCredit(lines[line], row: rows[line], into: &screen)
            rows[line] -= 1
            if rows[line] < 0 { rows[line] = 0x32 }
        }
        if rebuild {
            built = backdrop
            if logoLevel[0] >= 0x14 { drawLogo(0, level: logoLevel[0], into: &built) }
            for building in buildings { placeBuilding(building, into: &built) }
            rebuild = false
        }
        for index in figures.indices { act(index) }
    }

    func placeBuilding(_ building: (cell: Int, tile: Int), into target: inout IndexedImage) {
        guard data.heights.indices.contains(building.cell) else { return }
        let column = building.cell % 10, row = building.cell / 10
        drawTile(
            building.tile, x: (column - row) * 16 + 0x90, y: (column + row) * 8 - data.heights[building.cell] + 0x18,
            into: &target)
    }

    /// Carries out the command a figure's script is at.
    mutating func act(_ index: Int) {
        var figure = figures[index]
        defer { figures[index] = figure }
        let script = data.actors[index].script
        func command(_ pc: Int) -> Int { script.indices.contains(pc) ? Int(script[pc]) : 0xFF }
        func show(_ sprite: Int, flag: Int) {
            drawFigure(
                cell: figure.cell, direction: figure.direction, sprite: sprite, frame: figure.frame, lift: drop[index],
                flag: flag, into: &screen)
        }
        var op = command(figure.pc)
        switch op {
        case 0..<100:
            // Walk towards a cell, one step of eight passes at a time.
            if figure.cell == op {
                figure.pc += 1
                op = command(figure.pc)
            }
            let across = (op % 10 - figure.cell % 10).signum()
            let down = (op / 10 - figure.cell / 10).signum()
            figure.direction = down * 10 + across
            show(figure.sprite, flag: figure.flag)
            figure.frame = (figure.frame + 1) & 7
            if figure.frame == 0 { figure.cell += figure.direction }
        case 100..<0x82:
            // Build something on the cell stood on.
            let tile = data.buildTiles.indices.contains(op - 100) ? data.buildTiles[op - 100] : 0
            if let existing = buildings.firstIndex(where: { $0.cell >= figure.cell }) {
                if buildings[existing].cell == figure.cell {
                    buildings[existing].tile = tile
                } else {
                    buildings.insert((figure.cell, tile), at: existing)
                }
            } else {
                buildings.append((figure.cell, tile))
            }
            show(figure.sprite, flag: 0)
            figure.pc += 1
            rebuild = true
        case 0x82...0xDC:
            // Strike a pose for one pass.
            let pose = data.poseSprites.indices.contains(op - 0x82) ? data.poseSprites[op - 0x82] : 0
            show(pose, flag: figure.flag)
            figure.pc += 1
        case 0xFD, 0xFE:
            // Fade in a corner picture; once it is whole it stays on the backdrop.
            let logo = op == 0xFD ? 1 : 0
            if logoLevel[logo] >= 0x13 {
                drawLogo(logo, level: logoLevel[logo], into: &built)
                figure.pc += 1
            }
            drawLogo(logo, level: logoLevel[logo], into: &screen)
            logoLevel[logo] += 1
        case 0xFC:
            // Wait for the right-hand picture.
            if logoLevel[1] >= 0x14 { figure.pc += 1 }
        case 0xFB:
            // Stand about, now and then doing something else.
            var pose = phase + 0x1B + (index >= 7 ? 2 : 0)
            if random() > 0x7530 { pose = (index >= 7 ? 4 : 0) + 0xE }
            show(data.poseSprites.indices.contains(pose) ? data.poseSprites[pose] : 0, flag: 0)
        case 0xFA:
            if figure.aux == -1 {
                show(figure.sprite, flag: figure.flag)
            } else {
                figure.aux = (figure.aux + 1) % 4
                show(figure.sprite + figure.aux, flag: 0)
            }
        case 0xF9:
            guard figure.sprite == 0x20 else { break }
            counter += 1
            if counter == 0xF0 {
                for other in figures.indices where other != index { figures[other].pc += 1 }
                figure.pc += 1
            }
            figure.frame += figure.aux
            if figure.frame == -1 || figure.frame == 8 {
                figure.aux = -figure.aux
                figure.frame += figure.aux
            }
            show(counter & 3 + 0x8A, flag: figure.flag)
        case 0xF7:
            // Everybody moves on to the next thing in their script.
            for other in figures.indices where other != index {
                let theirs = data.actors[other].script
                if theirs.indices.contains(figures[other].pc), theirs[figures[other].pc] != 0xFF { figures[other].pc += 1 }
            }
            if command(figure.pc) != 0xFF { figure.pc += 1 }
        case 0xF6:
            counter += 1
            show(counter & 3 + 0x79, flag: 0)
        default:
            break
        }
    }
}
