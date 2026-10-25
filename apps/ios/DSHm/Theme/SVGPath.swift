import SwiftUI

/// Minimal SVG path-data parser (M/L/H/V/A/Z, absolute + relative) covering the
/// vector assets this app embeds. Arcs are converted to cubic beziers with the
/// standard W3C endpoint-to-center parameterization (spec F.6.5), split into
/// <=90 degree segments, so a Path renders identically to the SVG source with
/// no third-party dependency (design 3.2: the pin icon embeds pin-d.svg path
/// data directly).
enum SVGPath {
    static func path(from d: String) -> Path {
        var parser = Parser(d: d)
        return parser.parse()
    }

    private struct Parser {
        let d: String
        var index = 0
        var current: CGPoint = .zero
        var subpathStart: CGPoint = .zero
        var path = Path()

        init(d: String) { self.d = d }

 // MARK: tokenizer

        mutating func nextCommand() -> Character? {
            skipWhitespace()
            guard index < d.count else { return nil }
            let ch = d[d.index(d.startIndex, offsetBy: index)]
            index += 1
            return ch
        }

        mutating func peekNumber() -> Bool {
            skipWhitespace()
            guard index < d.count else { return false }
            let ch = d[d.index(d.startIndex, offsetBy: index)]
            return ch.isNumber || ch == "-" || ch == "+"
        }

        mutating func nextNumber() -> CGFloat {
            skipWhitespace()
            var text = ""
            while index < d.count {
                let ch = d[d.index(d.startIndex, offsetBy: index)]
                if ch == "-" || ch == "+" {
 // SVG packs a sign into the previous token's tail ("0-4"
 // means 0 then -4): a sign with digits already read starts
 // the NEXT number, unless it directly follows an exponent.
                    let previous = text.last
                    if !text.isEmpty, previous != "e", previous != "E" { break }
                    text.append(ch)
                    index += 1
                } else if ch.isNumber || ch == "." || ch == "e" || ch == "E" {
                    text.append(ch)
                    index += 1
                } else if ch == " " || ch == "," || ch == "\n" || ch == "\t" {
                    if text.isEmpty { index += 1; continue }
                    break
                } else {
                    break
                }
            }
            return CGFloat(Double(text) ?? 0)
        }

        mutating func skipWhitespace() {
            while index < d.count {
                let ch = d[d.index(d.startIndex, offsetBy: index)]
                if ch == " " || ch == "," || ch == "\n" || ch == "\r" || ch == "\t" { index += 1 } else { break }
            }
        }

 // MARK: commands

        mutating func parse() -> Path {
            while let command = nextCommand() {
                switch command {
                case "M", "m":
                    let x = nextNumber(); let y = nextNumber()
                    current = command == "M" ? CGPoint(x: x, y: y) : CGPoint(x: current.x + x, y: current.y + y)
                    subpathStart = current
                    path.move(to: current)
 // Implicit lineto after M.
                    while peekNumber() {
                        let lx = nextNumber(); let ly = nextNumber()
                        current = command == "M" ? CGPoint(x: lx, y: ly) : CGPoint(x: current.x + lx, y: current.y + ly)
                        path.addLine(to: current)
                    }
                case "L", "l":
                    while peekNumber() {
                        let x = nextNumber(); let y = nextNumber()
                        current = command == "L" ? CGPoint(x: x, y: y) : CGPoint(x: current.x + x, y: current.y + y)
                        path.addLine(to: current)
                    }
                case "H", "h":
                    while peekNumber() {
                        let x = nextNumber()
                        current = CGPoint(x: command == "H" ? x : current.x + x, y: current.y)
                        path.addLine(to: current)
                    }
                case "V", "v":
                    while peekNumber() {
                        let y = nextNumber()
                        current = CGPoint(x: current.x, y: command == "V" ? y : current.y + y)
                        path.addLine(to: current)
                    }
                case "A", "a":
                    while peekNumber() {
                        let rx = nextNumber(); let ry = nextNumber()
                        _ = nextNumber() // x-axis-rotation: only 0 makes sense in the embedded assets.
                        let largeArc = nextNumber() != 0
                        let sweep = nextNumber() != 0
                        let x = nextNumber(); let y = nextNumber()
                        let end = command == "A" ? CGPoint(x: x, y: y) : CGPoint(x: current.x + x, y: current.y + y)
                        appendArc(from: current, to: end, radius: CGSize(width: rx, height: ry), largeArc: largeArc, sweep: sweep)
                        current = end
                    }
                case "Z", "z":
                    path.addLine(to: subpathStart)
                    current = subpathStart
                default:
                    break
                }
            }
            return path
        }

 // MARK: arc -> cubic bezier (W3C F.6.5)

        mutating func appendArc(from start: CGPoint, to end: CGPoint, radius: CGSize, largeArc: Bool, sweep: Bool) {
            if radius.width == 0 || radius.height == 0 || start == end {
                path.addLine(to: end)
                return
            }
            var rx = abs(radius.width), ry = abs(radius.height)
 // F.6.5.1: out-of-range radii scale up.
            let dx2 = (start.x - end.x) / 2
            let dy2 = (start.y - end.y) / 2
            let lambda = (dx2 * dx2) / (rx * rx) + (dy2 * dy2) / (ry * ry)
            if lambda > 1 {
                let scale = lambda.squareRoot()
                rx *= scale; ry *= scale
            }
 // F.6.5.2: center parameters.
            let rx2 = rx * rx, ry2 = ry * ry
            let sign: CGFloat = largeArc != sweep ? 1 : -1
            let numerator = rx2 * ry2 - rx2 * dy2 * dy2 - ry2 * dx2 * dx2
            let denominator = rx2 * dy2 * dy2 + ry2 * dx2 * dx2
            let coefficient = denominator == 0 ? 0 : sign * (max(0, numerator) / denominator).squareRoot()
            let cx1 = coefficient * rx * dy2 / ry
            let cy1 = coefficient * -ry * dx2 / rx
            let cx = cx1 + (start.x + end.x) / 2
            let cy = cy1 + (start.y + end.y) / 2

            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                let dot = ux * vx + uy * vy
                let len = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).squareRoot()
                var value = dot / (len == 0 ? 1 : len)
                value = min(1, max(-1, value))
                var angle = acos(value)
                if ux * vy - uy * vx < 0 { angle = -angle }
                return angle
            }

            let theta1 = angle(1, 0, (start.x - cx) / rx, (start.y - cy) / ry)
 // F.6.5.4: delta = theta2 - theta1 with theta2 measured from the
 // same +x axis to the END point on the unit circle.
            let theta2 = angle(1, 0, (end.x - cx) / rx, (end.y - cy) / ry)
            var delta = theta2 - theta1
            let twoPi = CGFloat.pi * 2
            if !sweep && delta > 0 { delta -= twoPi }
            if sweep && delta < 0 { delta += twoPi }

 // Split into <=90 degree segments; each becomes one cubic.
            let segments = max(1, Int((abs(delta) / (CGFloat.pi / 2)).rounded(.up)))
            let increment = delta / CGFloat(segments)
 // The tangent handle length for a quarter-circle unit radius.
            let k: CGFloat = 4.0 / 3.0 * tan(abs(increment) / 4)
            var angle1 = theta1
            for _ in 0..<segments {
                let angle2 = angle1 + increment
                let c1 = CGPoint(
                    x: cx + rx * (cos(angle1) - k * sin(angle1)),
                    y: cy + ry * (sin(angle1) + k * cos(angle1))
                )
                let c2 = CGPoint(
                    x: cx + rx * (cos(angle2) + k * sin(angle2)),
                    y: cy + ry * (sin(angle2) - k * cos(angle2))
                )
                let point = CGPoint(x: cx + rx * cos(angle2), y: cy + ry * sin(angle2))
                path.addCurve(to: point, control1: c1, control2: c2)
                angle1 = angle2
            }
 // Numerical drift: land exactly on the endpoint.
            path.addLine(to: end)
        }
    }
}
