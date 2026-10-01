import SwiftUI
import UIKit

/// Phone-specific layout switches. The iPad layout is the default and stays untouched.
enum Layout {
    static let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    /// Width of the Steps row labels (and the lock lane's label, which must line up with them).
    static var rowLabelWidth: CGFloat { isPhone ? 72 : 92 }
}

// Mirrors the JSON emitted by RemoteScript/Conductor/Conductor.py.

struct SongState: Decodable, Equatable {
    var tempo: Double = 120
    var isPlaying = false
    var metronome = false
    var sigNum = 4
    var sigDen = 4
    var sessionRecord = false
    var recordMode = false
    var canUndo = false
    var canRedo = false
    var rootNote = 0
    var scaleName = "Major"
    var scaleIntervals = [0, 2, 4, 5, 7, 9, 11]
}

enum SlotState: String, Decodable {
    case empty, stopped, playing, triggered, recording
}

struct SlotInfo: Decodable, Equatable {
    var hasClip: Bool
    var name: String
    var color: Int
    var state: SlotState
    var hasStop: Bool
    var isGroupSlot: Bool

    static let empty = SlotInfo(hasClip: false, name: "", color: 0, state: .empty, hasStop: true, isGroupSlot: false)
}

enum TrackKind: String, Decodable {
    case track, `return`, master
}

struct TrackInfo: Decodable, Identifiable, Equatable {
    var i: Int
    var kind: TrackKind
    var name: String
    var color: Int
    var volume: Double
    var volumeStr: String
    var pan: Double
    var panStr: String
    var sends: [Double]
    var mute: Bool
    var solo: Bool
    var arm: Bool
    var canArm: Bool
    var isGroup: Bool
    var isFolded: Bool
    var groupIndex: Int
    var playingSlot: Int
    var firedSlot: Int
    var midi: Bool
    var devices: [TrackDevice]
    var slots: [SlotInfo]?

    var id: Int { i }
}

/// Top-level device summary shown in the mixer's effects rack.
struct TrackDevice: Decodable, Equatable {
    var name: String
    var className: String
    var isActive: Bool
}

struct SceneInfo: Decodable, Equatable {
    var name: String
    var color: Int
    var triggered: Bool
}

struct DeviceInfo: Decodable, Identifiable, Equatable {
    var path: [Int]
    var name: String
    var className: String
    var depth: Int
    var isActive: Bool
    var isRack: Bool
    var chain: String

    var id: String { path.map(String.init).joined(separator: ".") }
    var isPlugin: Bool { className.contains("PluginDevice") }
}

struct ParamInfo: Decodable, Identifiable, Equatable {
    var i: Int
    var name: String
    var value: Double
    var min: Double
    var max: Double
    var quantized: Bool
    var items: [String]
    var display: String
    var enabled: Bool

    var id: Int { i }
    var normalized: Double {
        max > min ? (value - min) / (max - min) : 0
    }
    func value(fromNormalized n: Double) -> Double {
        min + Swift.max(0, Swift.min(1, n)) * (max - min)
    }
}

struct FocusedDevice: Equatable {
    var t: Int
    var path: [Int]
    var name: String
    var className: String
}

struct SlotKey: Hashable {
    var t: Int
    var s: Int
}

// MARK: - Wire messages

struct Envelope: Decodable { let type: String }
struct HelloMsg: Decodable { let version: Int; let host: String }
struct StateMsg: Decodable { let song: SongState; let tracks: [TrackInfo]; let scenes: [SceneInfo]; let returns: [String] }
struct SlotMsg: Decodable { let t: Int; let s: Int; let slot: SlotInfo }
struct TrackMsg: Decodable { let track: TrackInfo }
struct SceneMsg: Decodable { let s: Int; let scene: SceneInfo }
struct SongMsg: Decodable { let song: SongState }
struct ProgressMsg: Decodable { let beat: Double; let clips: [[Double]] }
struct DevicesMsg: Decodable { let t: Int; let devices: [DeviceInfo] }
struct DeviceMsg: Decodable { let t: Int; let path: [Int]; let name: String; let className: String; let params: [ParamInfo] }
struct ParamMsg: Decodable { let i: Int; let value: Double; let display: String }
struct AppointedMsg: Decodable { let t: Int; let path: [Int] }
struct ErrorMsg: Decodable { let message: String }
struct MetersMsg: Decodable { let levels: [[Double]] }
struct InstrumentMsg: Decodable { let t: Int; let isDrum: Bool; let pads: [String] }
struct SeqPosMsg: Decodable { let pos: Double }

/// One parameter's Elektron-style lock lane on the sequencer clip. nil = step not locked.
struct LockLane: Decodable, Equatable {
    var t: Int
    var s: Int
    var path: [Int]
    var i: Int
    var name: String
    var base: Double
    var baseDisplay: String
    var step: Double
    var values: [Double?]
    var displays: [String?]
}
struct LockStepMsg: Decodable { let k: Int; let locks: [String: Double] }

// MARK: - Browser

struct BrowserCategory: Decodable, Identifiable, Equatable {
    var key: String
    var name: String
    var id: String { key }
}

struct BrowserItem: Decodable, Equatable {
    var name: String
    var isFolder: Bool
    var isLoadable: Bool
    var isDevice: Bool
    /// Devices (e.g. Drift) open to their preset folders; plain presets/samples don't.
    var isOpenable: Bool { isFolder || isDevice || !isLoadable }
}

struct BrowseMsg: Decodable, Equatable {
    var cat: String?
    var path: [Int]
    var name: String
    var items: [BrowserItem]
    var truncated: Bool
    var canPreview: Bool
    var categories: [BrowserCategory]
}

struct LoadedMsg: Decodable { let name: String; let track: String; let t: Int; let newTrack: Bool }

/// The clip the step sequencer edits. notes: [pitch, start, duration, velocity, mute]
struct SeqClip: Decodable, Equatable {
    var t: Int
    var s: Int
    var hasClip: Bool
    var isAudio: Bool
    var name: String
    var loopStart: Double
    var loopEnd: Double
    var notes: [[Double]]

    var length: Double { loopEnd - loopStart }

    func hasNote(pitch: Int, from start: Double, span: Double) -> Bool {
        notes.contains { n in
            n.count >= 2 && Int(n[0]) == pitch && n[1] >= start - 0.001 && n[1] < start + span - 0.001
        }
    }
}

// MARK: - Colors

extension Color {
    init(live rgb: Int) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

enum Theme {
    static let background = Color(white: 0.09)
    static let panel = Color(white: 0.14)
    static let cell = Color(white: 0.19)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.1)
    static let play = Color(red: 0.35, green: 0.9, blue: 0.4)
    static let record = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let solo = Color(red: 0.35, green: 0.6, blue: 1.0)
    static let activator = Color(red: 1.0, green: 0.8, blue: 0.2)
}
