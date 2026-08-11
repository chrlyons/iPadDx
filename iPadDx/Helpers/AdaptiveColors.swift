import SwiftUI
import UIKit

extension Color {
    /// Single point of light/dark adaptation for every semantic color.
    ///
    /// The system colors are tuned to sit on a dark background; on a light
    /// background the same hue reads washed out, so it is resolved for light
    /// mode and darkened until it holds contrast against white. Passing `nil`
    /// (the default on every helper below) returns the base color unchanged —
    /// that's what call sites with no `\.colorScheme` in scope get, so adding
    /// the parameter never changes existing behaviour on its own.
    static func adaptive(_ base: Color, scheme: ColorScheme?) -> Color {
        guard scheme == .light else { return base }
        let lightTraits = UITraitCollection { $0.userInterfaceStyle = .light }
        let resolved = UIColor(base).resolvedColor(with: lightTraits)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return base
        }
        return Color(
            hue: Double(hue),
            saturation: Double(min(saturation * 1.1, 1)),
            brightness: Double(brightness * 0.78),
            opacity: Double(alpha)
        )
    }

    /// Adaptive grade color that works in both light and dark mode.
    static func gradeColor(_ grade: String, scheme: ColorScheme? = nil) -> Color {
        let base: Color = switch grade {
        case "Excellent": .green
        case "Good": .blue
        case "Fair": .orange
        case "Poor": .red
        default: .gray
        }
        return adaptive(base, scheme: scheme)
    }

    /// Adaptive latency color based on value and color scheme.
    static func latencyColor(_ ms: Double, scheme: ColorScheme? = nil) -> Color {
        let base: Color = if ms < 10 {
            .green
        } else if ms < 30 {
            .blue
        } else if ms < 100 {
            .orange
        } else {
            .red
        }
        return adaptive(base, scheme: scheme)
    }

    /// Bridge transport color.
    static func bridgeColor(_ bridge: String, scheme: ColorScheme? = nil) -> Color {
        let base: Color = switch bridge {
        case "native": .blue
        case "cordova": .orange
        case "reactnative": .cyan
        case "flutter": .indigo
        case "capacitor": .teal
        default: .gray
        }
        return adaptive(base, scheme: scheme)
    }

    /// Anomaly severity color.
    static func anomalyColor(_ severity: AnomalySeverity, scheme: ColorScheme? = nil) -> Color {
        let base: Color = switch severity {
        case .warning: .yellow
        case .critical: .red
        }
        return adaptive(base, scheme: scheme)
    }

    /// Thermal state color.
    static func thermalColor(_ state: String, scheme: ColorScheme? = nil) -> Color {
        let base: Color = switch state {
        case "Nominal": .green
        case "Fair": .yellow
        case "Serious": .orange
        case "Critical": .red
        default: .gray
        }
        return adaptive(base, scheme: scheme)
    }

    /// Trend direction color.
    static func trendColor(_ direction: TrendDirection, scheme: ColorScheme? = nil) -> Color {
        let base: Color = switch direction {
        case .improving: .green
        case .stable: .blue
        case .degrading: .red
        }
        return adaptive(base, scheme: scheme)
    }

    /// Good / caution / bad color for a measured value.
    /// Lower is better by default (CPU, jitter, packet loss); set
    /// `higherIsBetter` for values like battery level.
    static func thresholdColor(
        _ value: Double,
        good: Double,
        caution: Double,
        higherIsBetter: Bool = false,
        scheme: ColorScheme? = nil
    ) -> Color {
        let base: Color = if higherIsBetter {
            value >= good ? .green : value >= caution ? .orange : .red
        } else {
            value <= good ? .green : value <= caution ? .orange : .red
        }
        return adaptive(base, scheme: scheme)
    }

    /// Binary healthy/problem color.
    static func statusColor(_ isHealthy: Bool, scheme: ColorScheme? = nil) -> Color {
        adaptive(isHealthy ? .green : .red, scheme: scheme)
    }
}
