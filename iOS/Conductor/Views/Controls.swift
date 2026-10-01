import SwiftUI

/// Rotary knob. Drag vertically (relative, never jumps). Double-tap resets.
struct Knob: View {
    var value: Double                      // normalized 0...1
    var color: Color = Theme.accent
    var bipolar = false
    var steps: Int? = nil                  // for quantized params
    var size: CGFloat = 52
    var defaultValue: Double? = nil
    var onBegin: () -> Void = {}
    var onChange: (Double) -> Void
    var onEnd: () -> Void = {}

    @State private var startValue: Double?

    private let sweep = 270.0

    var body: some View {
        ZStack {
            Circle().fill(Theme.cell)
            arc(from: 0, to: 1).stroke(Color.white.opacity(0.12), style: .init(lineWidth: 4, lineCap: .round))
            filledArc.stroke(color, style: .init(lineWidth: 4, lineCap: .round))
            Capsule()
                .fill(Color.white)
                .frame(width: 3, height: size * 0.28)
                .offset(y: -size * 0.2)
                .rotationEffect(.degrees(-sweep / 2 + sweep * value))
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if startValue == nil { startValue = value; onBegin() }
                    let range: CGFloat = steps.map { CGFloat(min(max(1, $0), 12)) * 18 } ?? 220
                    let delta = Double((-g.translation.height + g.translation.width * 0.3) / range)
                    onChange(min(1, max(0, (startValue ?? value) + delta)))
                }
                .onEnded { _ in startValue = nil; onEnd() }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if let d = defaultValue { onBegin(); onChange(d); onEnd() }
        })
    }

    private var filledArc: Path {
        if bipolar {
            return value >= 0.5 ? arc(from: 0.5, to: value) : arc(from: value, to: 0.5)
        }
        return arc(from: 0, to: value)
    }

    private func arc(from a: Double, to b: Double) -> Path {
        let r = size / 2 - 5
        let c = CGPoint(x: size / 2, y: size / 2)
        let start = Angle.degrees(90 + (360 - sweep) / 2 + sweep * a)
        let end = Angle.degrees(90 + (360 - sweep) / 2 + sweep * b)
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
        return p
    }
}

/// Vertical fader with relative drag. Double-tap resets.
struct VerticalFader: View {
    var value: Double                      // normalized 0...1
    var color: Color = Theme.accent
    var defaultValue: Double? = 0.85       // 0 dB on Live's volume param
    var onBegin: () -> Void = {}
    var onChange: (Double) -> Void
    var onEnd: () -> Void = {}

    @State private var startValue: Double?

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let thumbH: CGFloat = 26
            let travel = max(1, h - thumbH)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.5))
                    .frame(width: 8)
                RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.8))
                    .frame(width: 8, height: thumbH / 2 + travel * value)
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(white: 0.85))
                    .overlay(Rectangle().fill(Color.black.opacity(0.6)).frame(height: 2))
                    .frame(width: min(geo.size.width, 44), height: thumbH)
                    .offset(y: -travel * value)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if startValue == nil { startValue = value; onBegin() }
                        let delta = Double(-g.translation.height / travel)
                        onChange(min(1, max(0, (startValue ?? value) + delta)))
                    }
                    .onEnded { _ in startValue = nil; onEnd() }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if let d = defaultValue { onBegin(); onChange(d); onEnd() }
            })
        }
    }
}

/// Two-parameter XY pad. Absolute positioning (touch = value), like touchAble's XY.
struct XYPad: View {
    var x: Double
    var y: Double
    var color: Color = Theme.accent
    var onBegin: () -> Void = {}
    var onChange: (Double, Double) -> Void
    var onEnd: () -> Void = {}

    @State private var active = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.cell)
                Path { p in
                    for f in stride(from: 0.25, to: 1.0, by: 0.25) {
                        p.move(to: CGPoint(x: w * f, y: 0)); p.addLine(to: CGPoint(x: w * f, y: h))
                        p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f))
                    }
                }
                .stroke(Color.white.opacity(0.06))
                Path { p in
                    p.move(to: CGPoint(x: w * x, y: 0)); p.addLine(to: CGPoint(x: w * x, y: h))
                    p.move(to: CGPoint(x: 0, y: h * (1 - y))); p.addLine(to: CGPoint(x: w, y: h * (1 - y)))
                }
                .stroke(color.opacity(0.35))
                Circle()
                    .fill(color)
                    .frame(width: active ? 44 : 30, height: active ? 44 : 30)
                    .shadow(color: color.opacity(0.8), radius: active ? 16 : 6)
                    .position(x: w * x, y: h * (1 - y))
                    .animation(.easeOut(duration: 0.12), value: active)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !active { active = true; onBegin() }
                        let nx = min(1, max(0, g.location.x / w))
                        let ny = min(1, max(0, 1 - g.location.y / h))
                        onChange(nx, ny)
                    }
                    .onEnded { _ in active = false; onEnd() }
            )
        }
    }
}

/// Small latching button used for mute/solo/arm/metronome etc.
struct ToggleChip: View {
    var label: String
    var systemImage: String? = nil
    var isOn: Bool
    var onColor: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(label)
                }
            }
            .font(.system(size: 13, weight: .bold))
            .frame(maxWidth: .infinity, minHeight: 30)
            .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.7))
            .background(RoundedRectangle(cornerRadius: 5).fill(isOn ? onColor : Theme.cell))
        }
        .buttonStyle(.plain)
    }
}
