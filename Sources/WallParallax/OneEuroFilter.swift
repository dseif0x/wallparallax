import Foundation

/// 1€ filter (Casiez et al.): low jitter when still, low lag when moving fast.
struct OneEuroFilter {
    var minCutoff: Double = 1.0
    var beta: Double = 0.4
    var derivativeCutoff: Double = 1.0

    private var value: Double?
    private var derivative: Double = 0
    private var time: Double?

    mutating func reset() {
        value = nil
        time = nil
        derivative = 0
    }

    mutating func filter(_ x: Double, at t: Double) -> Double {
        guard let prev = value, let prevT = time, t > prevT else {
            value = x
            time = t
            return x
        }
        let dt = t - prevT
        let rawDerivative = (x - prev) / dt
        derivative += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawDerivative - derivative)
        let cutoff = minCutoff + beta * abs(derivative)
        let result = prev + Self.alpha(cutoff: cutoff, dt: dt) * (x - prev)
        value = result
        time = t
        return result
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
