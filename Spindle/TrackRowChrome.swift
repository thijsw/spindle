import SpindleCore
import SwiftUI

// Row furniture shared by the track table and the tag editor, so the two
// lists look identical (same number column, duration style and striping).

/// Two-digit track number in the fixed left column.
struct TrackNumberLabel: View {
    let number: Int

    var body: some View {
        Text(String(format: "%02d", number))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 28, alignment: .trailing)
    }
}

/// "m:ss" duration in the tertiary monospaced style.
struct TrackDurationLabel: View {
    let seconds: Double?

    var body: some View {
        Text(seconds.map(DisplayFormat.minutesSeconds) ?? "")
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.tertiary)
    }
}

extension View {
    /// Zebra striping keyed on the track number: even rows are tinted.
    func trackRowBackground(number: Int) -> some View {
        background(
            number.isMultiple(of: 2) ? Color.secondary.opacity(0.05) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
    }
}
