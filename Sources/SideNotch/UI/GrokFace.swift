import AppKit
import SwiftUI

/// Grok Bot's mark — a pale ball with two slanted eyes — drawn live so it can
/// look at the pointer the way the character does in its own app: the eyes sit
/// on the surface of the ball, so turning toward the pointer carries them out
/// toward the rim and foreshortens them, with a spring behind the turn and the
/// odd blink.
///
/// The pointer is polled rather than tracked: the rail is click-through, so it
/// never sees mouse-moved events for most of the screen. Frames only run while
/// something is moving — a still face with a still pointer costs a cheap check
/// ten times a second instead of a redraw at the display's refresh rate.
struct GrokFace: View {
    var color: Color
    var eyeColor: Color = .black
    /// Draw the face at rest — eyes forward, no tracking, no blinking, no timers.
    var still = false

    @StateObject private var locator = ScreenLocator()
    @State private var rig = FaceRig()
    @State private var animating = true
    @State private var lastMouse = NSEvent.mouseLocation

    private let wake = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    /// Eye centres on the front of a unit ball, x right and y down.
    private static let eyes: [(x: Double, y: Double)] = [(-0.30, 0.06), (0.26, -0.16)]

    var body: some View {
        if still {
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                let pose = FaceRig.Pose(yaw: 0, pitch: 0, open: 1)
                ZStack {
                    Circle().fill(color)
                    ForEach(0..<Self.eyes.count, id: \.self) { i in
                        eye(d, Self.eyes[i], pose)
                    }
                }
                .frame(width: d, height: d)
                .clipShape(Circle())
            }
        } else {
            live
        }
    }

    private var live: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !animating)) { context in
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                let pose = rig.step(at: context.date, toward: target())
                ZStack {
                    Circle().fill(color)
                    ForEach(0..<Self.eyes.count, id: \.self) { i in
                        eye(d, Self.eyes[i], pose)
                    }
                }
                .frame(width: d, height: d)
                .clipShape(Circle())
            }
        }
        .background(ScreenFrameReader(locator: locator))
        .onReceive(wake) { now in
            let mouse = NSEvent.mouseLocation
            let moved = mouse != lastMouse
            lastMouse = mouse
            let busy = moved || !rig.isResting(at: now)
            if busy != animating { animating = busy }
        }
    }

    private func eye(_ d: CGFloat, _ at: (x: Double, y: Double), _ pose: FaceRig.Pose) -> some View {
        // Put the eye on the ball, turn the ball, look at it head-on.
        let z = (1 - at.x * at.x - at.y * at.y).squareRoot()
        let x1 = at.x * cos(pose.yaw) + z * sin(pose.yaw)
        let z1 = -at.x * sin(pose.yaw) + z * cos(pose.yaw)
        let y2 = at.y * cos(pose.pitch) - z1 * sin(pose.pitch)
        let r = Double(d) / 2
        return Capsule()
            .fill(eyeColor)
            .frame(width: d * 0.15, height: d * 0.34)
            .rotationEffect(.degrees(-28))
            // Near the rim the surface faces away, so the eye narrows the way
            // it would on a real ball.
            .scaleEffect(x: max(0.35, (1 - x1 * x1).squareRoot()),
                         y: max(0.35, (1 - y2 * y2).squareRoot()) * pose.open)
            .offset(x: x1 * r, y: y2 * r)
    }

    /// Where the head wants to point, in radians: fully turned once the pointer
    /// is a short way off, easing in as it nears the face.
    private func target() -> (yaw: Double, pitch: Double) {
        guard let frame = locator.frame else { return (0, 0) }
        let mouse = NSEvent.mouseLocation
        let dx = Double(mouse.x - frame.midX)
        let dy = Double(mouse.y - frame.midY)      // screen space: y points up
        return (0.62 * tanh(dx / 160), 0.52 * tanh(dy / 160))
    }
}

/// The head's motion state. A class held in `@State` so each frame can advance
/// it without that itself counting as a view change.
final class FaceRig {
    struct Pose {
        var yaw: Double
        var pitch: Double
        /// 1 open, 0 shut.
        var open: Double
    }

    private var yaw = 0.0, pitch = 0.0, yawV = 0.0, pitchV = 0.0
    private var last: Date?
    private var nextBlink = Date().addingTimeInterval(2)
    private var blinkStart: Date?
    private var blinksLeft = 0

    func step(at now: Date, toward target: (yaw: Double, pitch: Double)) -> Pose {
        let dt = min(1 / 20, max(0, now.timeIntervalSince(last ?? now)))
        last = now

        // Slightly underdamped: it overshoots a touch and settles, rather than
        // gliding in on rails.
        let stiffness = 170.0, damping = 17.0
        yawV += ((target.yaw - yaw) * stiffness - yawV * damping) * dt
        pitchV += ((target.pitch - pitch) * stiffness - pitchV * damping) * dt
        yaw += yawV * dt
        pitch += pitchV * dt

        return Pose(yaw: yaw, pitch: pitch, open: openness(now))
    }

    /// Settled on its target, eyes open, and no blink due before the next
    /// check — nothing a frame would change.
    func isResting(at now: Date) -> Bool {
        blinkStart == nil
            && nextBlink.timeIntervalSince(now) > 0.15
            && abs(yawV) + abs(pitchV) < 0.005
    }

    /// A quick shut-and-open every few seconds, now and then twice in a row.
    private func openness(_ now: Date) -> Double {
        if blinkStart == nil, now >= nextBlink {
            blinkStart = now
            if blinksLeft == 0 { blinksLeft = Double.random(in: 0...1) < 0.2 ? 2 : 1 }
        }
        guard let began = blinkStart else { return 1 }
        let t = now.timeIntervalSince(began) / 0.15
        if t >= 1 {
            blinkStart = nil
            blinksLeft -= 1
            nextBlink = now.addingTimeInterval(blinksLeft > 0 ? 0.12 : .random(in: 2.5...6))
            return 1
        }
        return max(0.08, abs(1 - 2 * t))
    }
}

/// Where the face sits on screen, in AppKit's bottom-left coordinates. Read
/// fresh each tick, since the window moves when the rail is dragged or re-docked.
final class ScreenLocator: ObservableObject {
    weak var view: NSView?

    var frame: CGRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct ScreenFrameReader: NSViewRepresentable {
    let locator: ScreenLocator

    func makeNSView(context: Context) -> NSView {
        let probe = Probe()
        locator.view = probe
        return probe
    }
    func updateNSView(_ nsView: NSView, context: Context) { locator.view = nsView }

    private final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
