import Foundation

enum Music {
    static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    /// Live's naming: MIDI 60 = C3.
    static func name(_ note: Int) -> String {
        "\(noteNames[((note % 12) + 12) % 12])\(note / 12 - 2)"
    }

    /// Names match Live 12's scale names so they can be set on the song.
    static let scales: [(name: String, intervals: [Int])] = [
        ("Major", [0, 2, 4, 5, 7, 9, 11]),
        ("Minor", [0, 2, 3, 5, 7, 8, 10]),
        ("Dorian", [0, 2, 3, 5, 7, 9, 10]),
        ("Mixolydian", [0, 2, 4, 5, 7, 9, 10]),
        ("Lydian", [0, 2, 4, 6, 7, 9, 11]),
        ("Phrygian", [0, 1, 3, 5, 7, 8, 10]),
        ("Locrian", [0, 1, 3, 5, 6, 8, 10]),
        ("Harmonic Minor", [0, 2, 3, 5, 7, 8, 11]),
        ("Melodic Minor", [0, 2, 3, 5, 7, 9, 11]),
        ("Major Pentatonic", [0, 2, 4, 7, 9]),
        ("Minor Pentatonic", [0, 3, 5, 7, 10]),
        ("Minor Blues", [0, 3, 5, 6, 7, 10]),
        ("Whole Tone", [0, 2, 4, 6, 8, 10]),
    ]
}

/// Push-style isomorphic keyboard mapping.
struct KeyLayout {
    enum Kind: String, CaseIterable { case fourths = "4ths", sequential = "Sequential" }

    var root: Int            // 0...11
    var intervals: [Int]
    var inKey: Bool
    var kind: Kind
    var octave: Int          // base octave (Live naming), 0...7
    var columns: Int

    private var base: Int { (octave + 2) * 12 + root }

    /// row 0 = bottom.
    func note(row: Int, col: Int) -> Int {
        if inKey {
            let n = max(1, intervals.count)
            let shift = kind == .sequential ? columns : (n >= 7 ? 3 : 2)
            let degree = row * shift + col
            return base + (degree / n) * 12 + intervals[degree % n]
        } else {
            let shift = kind == .sequential ? columns : 5
            return base + row * shift + col
        }
    }

    func isRoot(_ note: Int) -> Bool { ((note - root) % 12 + 12) % 12 == 0 }
    func inScale(_ note: Int) -> Bool { intervals.contains(((note - root) % 12 + 12) % 12) }

    /// Scale notes ascending from the base, for the melodic sequencer.
    func scaleNotes(count: Int, from startOctave: Int) -> [Int] {
        var out: [Int] = []
        var o = startOctave
        while out.count < count {
            for i in intervals where out.count < count { out.append((o + 2) * 12 + root + i) }
            o += 1
        }
        return out.filter { (0...127).contains($0) }
    }
}
