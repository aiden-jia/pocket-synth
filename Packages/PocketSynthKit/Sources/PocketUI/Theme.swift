import SwiftUI

/// App palette: a dark, neutral instrument look (our own design, not a device skin).
enum Theme {
    static let background = Color(red: 0.06, green: 0.065, blue: 0.075)
    static let panel = Color(red: 0.11, green: 0.115, blue: 0.13)
    static let raised = Color(red: 0.17, green: 0.175, blue: 0.20)
    static let stroke = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.5)
    static let accent = Color(red: 0.30, green: 0.85, blue: 0.78)
    static let screen = Color(red: 0.04, green: 0.08, blue: 0.08)
    static let screenText = Color(red: 0.55, green: 0.98, blue: 0.90)
    static let warm = Color(red: 1.0, green: 0.70, blue: 0.35)
}
