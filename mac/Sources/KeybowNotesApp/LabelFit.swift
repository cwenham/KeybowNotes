import AppKit

/// A font size at which a label's longest word fits on one line. In a narrow
/// tile SwiftUI would otherwise break a long word partway ("Programmin / g")
/// or cut it short ("Documenta…"); shorter labels keep the full size.
enum LabelFit {
    static func size(for label: String, base: CGFloat, weight: NSFont.Weight, width: CGFloat,
                     smallest: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: base, weight: weight)
        let widest = label.split(whereSeparator: \.isWhitespace)
            .map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        guard widest > width else { return base }
        // To the half point below, so it fits.
        return max(smallest, (base * width / widest * 2).rounded(.down) / 2)
    }
}
