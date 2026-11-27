#if os(macOS)
import AppKit
#endif
import SwiftUI

/// The SDK's green pixel-art pony (from sdk/docs/public/logo.png), drawn as crisp vector
/// pixels so it scales to any size. Use `.frame(width:)` / `.frame(height:)` to size it;
/// the aspect ratio (48:51) is kept.
struct StudioLogo: View {
    /// Brand green (the pony's body colour), for accents elsewhere in the UI.
    static let brandGreen = Color(red: 0x0F / 255, green: 0x8D / 255, blue: 0x5C / 255)

    var body: some View {
        Canvas { context, size in
            let cell = min(size.width / CGFloat(Self.columns), size.height / CGFloat(Self.rows.count))
            let origin = CGPoint(
                x: (size.width - cell * CGFloat(Self.columns)) / 2,
                y: (size.height - cell * CGFloat(Self.rows.count)) / 2
            )
            // Outline-coloured silhouette first so anti-aliased seams between cells never show.
            for (index, color) in Self.palette.enumerated() {
                let key = Character(String(index + 1))
                var path = Path()
                for (r, row) in Self.rows.enumerated() {
                    for (c, ch) in row.enumerated() where ch != "." && (index == 0 || ch == key) {
                        path.addRect(CGRect(
                            x: origin.x + CGFloat(c) * cell, y: origin.y + CGFloat(r) * cell,
                            width: cell, height: cell
                        ))
                    }
                }
                context.fill(path, with: .color(color))
            }
        }
        .aspectRatio(CGFloat(Self.columns) / CGFloat(Self.rows.count), contentMode: .fit)
        .accessibilityLabel("Studio")
    }

    // MARK: - Pixel data

    /// 1 = outline, 2 = dark, 3 = shade, 4 = body (brand green), 5 = light, 6 = highlight.
    private static let palette: [Color] = [0x052F1C, 0x085743, 0x1D8352, 0x0F8D5C, 0x199C64, 0x24B66E].map {
        Color(red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }

    private static let columns = 48

    private static let rows: [[Character]] = [
        "...........................1.....11111111.......",
        "..........................161..116666662211.....",
        ".........................1261.13222226662221....",
        "........................12235122222222266221....",
        "........................121251223333322226221...",
        "........................1212251222233332226221..",
        "........................1212251122223333222221..",
        ".......................1121222411112223333222211",
        ".......................1122122442221111333322221",
        "......................16112224444422222111111111",
        "......................15211244444444444222221...",
        "......................15221444444444444444441...",
        ".....................135221444444411444441141...",
        ".....................136221444444416444441641...",
        ".....................126621444444411444441141...",
        ".....................123651444444411444441161...",
        ".....................1226651444444444446666661..",
        ".....................12226614444444444446666661.",
        "......................1222614444444444444444441.",
        "......................1322114444444444444144141.",
        "......................1332124644444444444444441.",
        ".....111111............132124641344444444444441.",
        "....15555551...........13312444211444444444441..",
        "...1556666651..........1331244442211111111111...",
        "..155622222551..........13124444422221..........",
        "..156222333251111111111111244444442221..........",
        ".1552223333311466666666666444444444221..........",
        ".1552233322113666666666664444444444441..........",
        ".1522233211146644444444444444444446661..........",
        ".1522232211366444444444444444444466661..........",
        ".1522232211464444444444444444444466661..........",
        ".1522232211444444444444444444444466661..........",
        ".1522232211444444444444444444444466661..........",
        ".1122233211444444444444444444444466661..........",
        "..112233211444444444444444444444666641..........",
        "...1223321114444444444444444466666641...........",
        "...1223321.12444441444444444466666311...........",
        "...1223211.12444441444444414466164121...........",
        "..1122321.122444312222222212466111221...........",
        "..1223211.124444111111111112466122231...........",
        "11223211..1244441221......12466122331...........",
        "1223211...1244412221......12466122331...........",
        "111111....1244412221......12466122331...........",
        "..........1244412221......124661223331..........",
        "..........1244412221......124661223331..........",
        "..........1244412221......124666123331..........",
        "..........1244412221......124466123331..........",
        "..........124441111.......124444123331..........",
        "..........124431..........12444411111...........",
        "...........1111...........1244431...............",
        "...........................11111................",
    ].map(Array.init)
}

/// The macOS app icon (same design as Resources/AppIcon.icns): the pony on a light mint
/// squircle. Used to set the Dock icon when running unbundled via `swift run`.
struct StudioAppIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 1024
            ZStack {
                RoundedRectangle(cornerRadius: 185.4 * s, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0xF4 / 255, green: 0xFB / 255, blue: 0xF7 / 255),
                                 Color(red: 0xCD / 255, green: 0xEB / 255, blue: 0xDC / 255)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .shadow(color: .black.opacity(0.3), radius: 10 * s, y: 10 * s)
                    .frame(width: 824 * s, height: 824 * s)
                StudioLogo()
                    .frame(width: 48 * 12.2 * s)
                    .offset(y: -10 * s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    #if os(macOS)
    /// Renders the icon to an `NSImage` for `NSApp.applicationIconImage`.
    /// (The iOS app icon comes from the asset catalog.)
    @MainActor static func image(size: CGFloat = 512) -> NSImage? {
        let renderer = ImageRenderer(content: StudioAppIcon().frame(width: size, height: size))
        renderer.scale = 2
        return renderer.nsImage
    }
    #endif
}
