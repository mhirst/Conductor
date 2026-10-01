import SwiftUI
import UIKit

/// Transparent multi-touch layer over a rows×cols grid. Each finger is tracked independently and
/// can slide between cells (like Push's pads). Reports cell indices with row 0 at the bottom.
struct MultiTouchGrid: UIViewRepresentable {
    let rows: Int
    let cols: Int
    var spacing: CGFloat = 0
    /// (cell, velocity 0...1 derived from where in the cell the finger lands: higher = harder)
    var onDown: (Int, Double) -> Void
    var onUp: (Int) -> Void

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.isMultipleTouchEnabled = true
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: TouchView, context: Context) {
        v.rows = rows
        v.cols = cols
        v.spacing = spacing
        v.onDown = onDown
        v.onUp = onUp
    }

    final class TouchView: UIView {
        var rows = 1, cols = 1
        var spacing: CGFloat = 0
        var onDown: (Int, Double) -> Void = { _, _ in }
        var onUp: (Int) -> Void = { _ in }
        private var active: [ObjectIdentifier: Int] = [:]

        private func hit(_ p: CGPoint) -> (Int, Double)? {
            guard bounds.width > 0, bounds.height > 0, bounds.contains(p) else { return nil }
            let cw = bounds.width / CGFloat(cols), ch = bounds.height / CGFloat(rows)
            let c = min(cols - 1, max(0, Int(p.x / cw)))
            let rFromTop = min(rows - 1, max(0, Int(p.y / ch)))
            let yInCell = (p.y - CGFloat(rFromTop) * ch) / ch
            return ((rows - 1 - rFromTop) * cols + c, Double(1 - yInCell))
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches {
                guard let (cell, vel) = hit(t.location(in: self)) else { continue }
                active[ObjectIdentifier(t)] = cell
                onDown(cell, vel)
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches {
                let id = ObjectIdentifier(t)
                let now = hit(t.location(in: self))
                if now?.0 == active[id] { continue }
                if let old = active[id] { onUp(old) }
                if let (cell, vel) = now {
                    active[id] = cell
                    onDown(cell, vel)
                } else {
                    active[id] = nil
                }
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

        private func finish(_ touches: Set<UITouch>) {
            for t in touches {
                if let cell = active.removeValue(forKey: ObjectIdentifier(t)) { onUp(cell) }
            }
        }
    }
}

/// Push-style touch strip: pitch bend (springs back to centre) or mod wheel (holds).
struct TouchStrip: View {
    enum Mode { case pitchBend, modulation }
    let mode: Mode
    let color: Color
    var onChange: (Double) -> Void

    @State private var value: Double = 0   // pitch: -1...1, mod: 0...1

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let norm = mode == .pitchBend ? (value + 1) / 2 : value
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.cell)
                if mode == .pitchBend {
                    Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1).offset(y: -h / 2)
                }
                Capsule()
                    .fill(color)
                    .frame(height: 10)
                    .padding(.horizontal, 5)
                    .offset(y: -max(0, min(h - 10, h * norm - 5)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let n = min(1, max(0, 1 - g.location.y / h))
                        set(mode == .pitchBend ? n * 2 - 1 : n)
                    }
                    .onEnded { _ in
                        if mode == .pitchBend {
                            withAnimation(.easeOut(duration: 0.12)) { set(0) }
                        }
                    }
            )
        }
        .frame(width: 44)
        .overlay(alignment: .top) {
            Text(mode == .pitchBend ? "PB" : "MOD")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).padding(.top, 6)
        }
    }

    private func set(_ v: Double) {
        value = v
        onChange(v)
    }
}
