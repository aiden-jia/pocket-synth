import SwiftUI
import SynthCore

/// Status-screen content for the Tuner and Game modes (SYNTH_SPEC §4).
struct ToolContent: View {
    let tool: ToolScreen
    let detail: String?

    var body: some View {
        switch tool {
        case .tuner(let reading): TunerContent(reading: reading)
        case .game(let g): GameMenuContent(game: g)
        }
    }
}

struct TunerContent: View {
    let reading: TunerReading?

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(reading?.name ?? "—")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.screenText.opacity(0.1)).frame(height: 6)
                    // ±5 cents "in tune" zone and the centre line.
                    Capsule().fill(Theme.accent.opacity(0.25)).frame(width: w * 0.1, height: 6).offset(x: w * 0.45)
                    Rectangle().fill(Theme.screenText.opacity(0.5)).frame(width: 2, height: 16).offset(x: w / 2 - 1)
                    if let r = reading {
                        Circle().fill(color).frame(width: 14, height: 14)
                            .offset(x: w * (r.cents + 50) / 100 - 7)
                            .animation(.easeOut(duration: 0.1), value: r.cents)
                    }
                }
                .frame(height: 16)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            .padding(.horizontal, 24)
            Text(reading.map { String(format: "%+.0f ¢ · %.1f Hz", $0.cents, $0.hz) } ?? "PLAY OR SING A NOTE")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.screenText.opacity(0.7))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var color: Color {
        guard let r = reading else { return Theme.screenText.opacity(0.5) }
        return r.inTune ? Theme.accent : Theme.warm
    }
}

struct GameMenuContent: View {
    let game: GameScreen

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            if !game.running {
                Text(game.song)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.screenText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("TIER \(game.tier) · \(game.bpm) BPM · SPEED \(game.speedPercent)%"
                     + (game.best.map { " · BEST \($0)%" } ?? ""))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.screenText.opacity(0.75))
                Text(game.result ?? "←→ SONG · ↑↓ SPEED · CLICK START")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(game.result == nil ? Theme.screenText.opacity(0.55) : Theme.warm)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The running game: chords fall down their pad's column to the hit line at the bottom
/// of the screen, so each note lands right above the pad that plays it.
struct GameLaneView: View {
    /// Column centres (one per pad), in the screen's own coordinates.
    let columns: [CGFloat]
    let lane: (Double) -> GameLane?

    var body: some View {
        TimelineView(.animation) { _ in
            let l = lane(AppModel.now)
            Canvas { ctx, size in
                guard let l else { return }
                let top: CGFloat = 30, hitY = size.height - 22
                let colWidth = columns.count > 1 ? (columns[1] - columns[0]) * 0.78 : 40
                // Hit line.
                ctx.fill(Path(CGRect(x: 10, y: hitY - 1, width: size.width - 20, height: 2)),
                         with: .color(Theme.screenText.opacity(0.45)))
                for n in l.notes where n.result != .perfect && n.result != .good {
                    guard columns.indices.contains(n.pad - 1) else { continue }
                    let y = hitY - CGFloat(n.position) * (hitY - top)
                    let rect = CGRect(x: columns[n.pad - 1] - colWidth / 2, y: y - 5, width: colWidth, height: 10)
                    let color = n.result == .miss ? Color.red.opacity(0.5) : Theme.screenText
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color))
                }
                // Progress along the bottom edge.
                ctx.fill(Path(CGRect(x: 10, y: size.height - 8, width: (size.width - 20) * l.progress, height: 3)),
                         with: .color(Theme.screenText.opacity(0.35)))
                if let c = l.countdown {
                    ctx.draw(Text("\(c)").font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.screenText.opacity(0.8)), at: CGPoint(x: size.width / 2, y: size.height / 2))
                }
                if let f = l.flash {
                    let color: Color = f == .perfect ? Theme.accent : f == .good ? Theme.warm : .red
                    ctx.draw(Text(f.label).font(.system(size: 18, weight: .heavy, design: .monospaced)).foregroundColor(color),
                             at: CGPoint(x: size.width / 2, y: hitY - 26))
                }
                ctx.draw(Text("\(l.combo)× · \(l.accuracy)%").font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.screenText.opacity(0.8)), at: CGPoint(x: size.width - 70, y: 40))
            }
        }
    }
}
