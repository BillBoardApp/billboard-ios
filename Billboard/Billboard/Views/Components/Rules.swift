import SwiftUI

// Civic Record's rules (spec 2.7). Rules do the structural work that boxes and shadows did: a
// thin-thick double rule under front matter and the masthead, a 2 pt ink rule over section heads,
// hairlines between sections, dotted rules between ledger rows, a perforation above a slip's stub.
// Every rule is decoration, so each is hidden from VoiceOver.

/// A straight line across the middle of its frame, for stroked (dashed or dotted) rules.
private struct HorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// 1 pt `rule`: between bill-page sections, list rows, inside roll sheets, sheet edges.
struct HairlineRule: View {
    var body: some View {
        BillboardColors.separator
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// `ruleHeavy` (ink): 2 pt over tab-root and list section heads; 1.5 pt under tally column heads.
struct HeavyRule: View {
    var width: CGFloat = 2

    var body: some View {
        BillboardColors.ruleHeavy
            .frame(height: width)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// Thick over thin: 2 pt `ruleHeavy`, a 2 pt gap, 1 pt `ruleHeavy`. Under bill, member and Weekly
/// Brief front matter.
struct DoubleRule: View {
    var body: some View {
        VStack(spacing: 2) {
            BillboardColors.ruleHeavy.frame(height: 2)
            BillboardColors.ruleHeavy.frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// Thin over thick on navy: 1 pt white at 38%, a 2 pt gap, 2 pt white at 88%. Under the wordmark
/// in the Bills masthead.
struct MastheadRule: View {
    var body: some View {
        VStack(spacing: 2) {
            BillboardColors.textOnNavy.opacity(0.38).frame(height: 1)
            BillboardColors.textOnNavy.opacity(0.88).frame(height: 2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// 1 pt `rule2` dots (dash 1, gap 2.5, round caps): between ledger rows, local results lines and
/// the sealed sheet's blank cells.
struct DottedRule: View {
    var body: some View {
        HorizontalLine()
            .stroke(BillboardColors.rule2, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 2.5]))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// 1 pt `rule2` dashes (3 on, 3 off): the perforation above a bill slip's stub.
struct PerforationRule: View {
    var body: some View {
        HorizontalLine()
            .stroke(BillboardColors.rule2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// The 50% mark on every Yea / Nay split bar: 2 pt `ruleHeavy`, standing 4 pt above and below the
/// bar. Overlay it on the bar, centred; it fills the bar's width and draws at the middle.
struct MajorityTick: View {
    var barHeight: CGFloat = 8

    /// How far the tick stands above and below the bar.
    static let overhang: CGFloat = 4

    var body: some View {
        BillboardColors.ruleHeavy
            .frame(width: 2, height: barHeight + 2 * Self.overhang)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}
