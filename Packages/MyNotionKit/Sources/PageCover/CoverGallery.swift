import CoreGraphics
import Foundation

/// Галерея «Цвета и градиенты» (research R1; contracts/pages-ui.md, «Галерея»): id и порядок — как в окне «Change cover»
/// Notion 7.39. Цвета сняты 20.10.2026 с картинок `notion.so/images/page-cover/<id>.png|jpg` (в сборку не кладутся):
/// заливка — цветом картинки, градиент — сеткой 8 × 8 средних цветов, растянутой с сглаживанием. Ни файлов, ни сети.
public enum CoverGallery {
    public struct Item: Sendable, Hashable {
        public let id: String
        /// Подпись плитки для доступности.
        public let title: String
        let fill: Fill
        /// Ширина к высоте исходной картинки Notion: по ней видна та же часть при сдвиге, что у Notion.
        public let aspectRatio: CGFloat
    }

    enum Fill: Sendable, Hashable {
        case solid(UInt32)
        /// Цвета по строкам сверху вниз, `side` × `side`.
        case grid(side: Int, colors: [UInt32])
    }

    public static let items: [Item] = [
        Item(id: "solid_red", title: "Красный", fill: .solid(0xEB5757), aspectRatio: 2),
        Item(id: "solid_yellow", title: "Жёлтый", fill: .solid(0xF9BF52), aspectRatio: 2),
        Item(id: "solid_blue", title: "Синий", fill: .solid(0x1C9ACE), aspectRatio: 2),
        Item(id: "solid_beige", title: "Бежевый", fill: .solid(0xFFEFE3), aspectRatio: 2),
        Item(id: "gradients_8", title: "Бирюзово-коралловый", fill: .grid(side: 8, colors: [
            0x319DA2, 0x33A4AC, 0x36ADB7, 0x39B4C0, 0x3CB7C3, 0x3EB6C0, 0x40B2B9, 0x40AEB3, 0x4CB0B1, 0x4EB7BA, 0x51BFC5, 0x55C6CD,
            0x58C9D0, 0x5AC7CD, 0x5BC3C7, 0x5CBFC1, 0x6BBEBC, 0x6DC5C4, 0x71CCCD, 0x74D2D4, 0x77D4D7, 0x79D2D4, 0x7ACECE, 0x7BCAC8,
            0x8BC2BC, 0x8DC7C3, 0x90CECB, 0x94D2D0, 0x97D3D2, 0x99D1CF, 0x9ACDC9, 0x9BC9C4, 0xA8B8B0, 0xAABCB5, 0xAEC0BB, 0xB1C3BF,
            0xB4C3BF, 0xB6C0BC, 0xB7BCB7, 0xB7B8B2, 0xC1A098, 0xC3A39B, 0xC6A69F, 0xC9A7A1, 0xCCA6A0, 0xCDA29D, 0xCE9E98, 0xCF9A94,
            0xD48078, 0xD6827A, 0xD9837C, 0xDB837D, 0xDE807B, 0xE07D77, 0xE17873, 0xE1756F, 0xE15F57, 0xE35F58, 0xE65F59, 0xE85D58,
            0xEA5B56, 0xEC5752, 0xED534E, 0xEE504B,
        ]), aspectRatio: 1),
        Item(id: "gradients_2", title: "Зелёно-красный", fill: .grid(side: 8, colors: [
            0x8FB59E, 0x96B599, 0x9AB595, 0x9CB491, 0x99B38E, 0x93B18C, 0x8CAF8A, 0x84AE89, 0xAA9D84, 0xAF9C7F, 0xB39B79, 0xB49975,
            0xB39871, 0xAF966F, 0xA9956D, 0xA4946C, 0xC1856C, 0xC48266, 0xC78060, 0xC97D5A, 0xC87B56, 0xC67953, 0xC37851, 0xC07750,
            0xD16F58, 0xD36B51, 0xD6674A, 0xD76343, 0xD85F3E, 0xD85C3A, 0xD75A37, 0xD65836, 0xDA5E49, 0xDB5841, 0xDD5339, 0xDF4D32,
            0xE1472B, 0xE34327, 0xE53F23, 0xE63C21, 0xDD523F, 0xDD4C37, 0xDE462F, 0xE03E26, 0xE4371F, 0xE83019, 0xEC2A15, 0xEF2512,
            0xDC4E3A, 0xDA4832, 0xDA402A, 0xDD3721, 0xE12E19, 0xE72412, 0xED1C0D, 0xF31609, 0xDA5139, 0xD64A32, 0xD44229, 0xD63821,
            0xDB2D19, 0xE32111, 0xEC170B, 0xF30E07,
        ]), aspectRatio: 1),
        Item(id: "gradients_11", title: "Пастельный", fill: .grid(side: 8, colors: [
            0x453447, 0x613A45, 0x7C4042, 0x92453F, 0x9F473B, 0xA24538, 0x9B4135, 0x8C3C33, 0x565367, 0x765B65, 0x936262, 0xAA675F,
            0xB6695C, 0xB66759, 0xA96256, 0x955B55, 0x697588, 0x8D7E86, 0xAD8684, 0xC48C82, 0xCE8D7E, 0xC98B7C, 0xB8857A, 0x9E7D78,
            0x7E95A8, 0xA49FA6, 0xC5A8A4, 0xDBADA2, 0xE2AF9F, 0xD9AB9D, 0xC3A59B, 0xA59D9A, 0x90B0C3, 0xB7BBC1, 0xD7C4BF, 0xEBCABD,
            0xEFCABB, 0xE3C7B9, 0xCAC0B7, 0xA9B7B7, 0x9EC6D8, 0xC4D1D7, 0xE2DAD5, 0xF4DFD3, 0xF5DFD1, 0xE6DBCF, 0xCBD4CE, 0xAACCCD,
            0xA7D6E8, 0xCAE1E7, 0xE6E9E5, 0xF5EDE3, 0xF3EDE1, 0xE3E9E0, 0xC8E3DF, 0xA8DBDE, 0xACE1F3, 0xCCEBF2, 0xE5F2F1, 0xF1F6EF,
            0xEEF6EE, 0xDDF2EC, 0xC3ECEB, 0xA4E5EA,
        ]), aspectRatio: 1),
        Item(id: "gradients_4", title: "Розовый", fill: .grid(side: 8, colors: [
            0xFF3877, 0xFF3988, 0xFF398F, 0xFF3990, 0xFF398F, 0xFF398B, 0xFF3881, 0xFF376D, 0xFF398A, 0xFF3992, 0xFF3993, 0xFF3993,
            0xFF3992, 0xFF3990, 0xFF388B, 0xFF3880, 0xFF388D, 0xFF388F, 0xFF388E, 0xFF388D, 0xFF388C, 0xFF388B, 0xFF3889, 0xFF3883,
            0xFF3887, 0xFF3888, 0xFF3886, 0xFF3785, 0xFF3784, 0xFF3784, 0xFF3782, 0xFF377F, 0xFF377E, 0xFF377E, 0xFF377D, 0xFF377B,
            0xFF377B, 0xFF377B, 0xFF377A, 0xFF3777, 0xFF3672, 0xFF3673, 0xFF3672, 0xFF3670, 0xFF366F, 0xFF366F, 0xFF366F, 0xFF366B,
            0xFF3564, 0xFF3566, 0xFF3564, 0xFF3563, 0xFF3562, 0xFF3562, 0xFF3561, 0xFF355D, 0xFF3450, 0xFF3454, 0xFF3454, 0xFF3453,
            0xFF3452, 0xFF3452, 0xFF3451, 0xFF344B,
        ]), aspectRatio: 1),
        Item(id: "gradients_10", title: "Сине-алый", fill: .grid(side: 8, colors: [
            0x115D87, 0x125080, 0x25346B, 0x2F1D4E, 0x241935, 0x222126, 0x40251B, 0x692111, 0x1A6B97, 0x146091, 0x1B497F, 0x203564,
            0x1D314C, 0x26363C, 0x4A3730, 0x743023, 0x3279A6, 0x2472A3, 0x206193, 0x234F78, 0x28485F, 0x3B474C, 0x60423C, 0x87382C,
            0x5B84B1, 0x4882B1, 0x3D76A2, 0x3E6585, 0x4B5767, 0x624E4F, 0x82433B, 0xA13628, 0x8C8EBA, 0x7892BC, 0x698BAE, 0x6A778E,
            0x786169, 0x8F4F4B, 0xA74034, 0xBC3121, 0xBB98C3, 0xA9A2C7, 0x9AA1BD, 0x988D9B, 0xA56E6E, 0xB7534A, 0xC83F31, 0xD52F1E,
            0xDFA2CC, 0xD2B5D6, 0xC5BDD0, 0xC1ABB0, 0xC9847F, 0xD65F53, 0xE14435, 0xE83220, 0xF3ACD4, 0xEBC7E3, 0xE2D9E5, 0xDECBC9,
            0xE29F95, 0xEA6F62, 0xEF4D3D, 0xF23624,
        ]), aspectRatio: 1),
        Item(id: "gradients_5", title: "Сине-малиновый", fill: .grid(side: 8, colors: [
            0x3D54D7, 0x4660D9, 0x506EDB, 0x5A7EDC, 0x658FDD, 0x6F9FDE, 0x78AEDE, 0x80BCDE, 0x514ECA, 0x5959CB, 0x6265CD, 0x6B73CD,
            0x7582CE, 0x7E90CE, 0x869ECD, 0x8DAACD, 0x6748BA, 0x6E51BB, 0x765BBB, 0x7E67BC, 0x8673BB, 0x8E7FBB, 0x958BBA, 0x9B95B9,
            0x7F41A8, 0x8548A8, 0x8B50A8, 0x925AA7, 0x9963A6, 0xA06DA5, 0xA577A3, 0xAA7FA1, 0x973A93, 0x9C3F93, 0xA14592, 0xA74C91,
            0xAC538F, 0xB15B8D, 0xB6628B, 0xBA6888, 0xAE337E, 0xB2367D, 0xB63A7B, 0xBB3F79, 0xBF4377, 0xC34974, 0xC64D71, 0xC9526E,
            0xC42C68, 0xC72E67, 0xCA3064, 0xCD3262, 0xD0355F, 0xD3375B, 0xD53A58, 0xD73D55, 0xD72754, 0xD92652, 0xDB264F, 0xDD274C,
            0xDF2748, 0xE12844, 0xE32940, 0xE42A3D,
        ]), aspectRatio: 1),
        Item(id: "gradients_3", title: "Сумеречный", fill: .grid(side: 8, colors: [
            0x5B3942, 0x64434B, 0x725255, 0x826161, 0x95726B, 0xA88173, 0xBB8E79, 0xCB997D, 0x553E4B, 0x5E4954, 0x6C575E, 0x7C6669,
            0x8E7674, 0xA2867C, 0xB49382, 0xC59E86, 0x4D4658, 0x565060, 0x635E6B, 0x736D76, 0x857D80, 0x988C89, 0xAB9A8F, 0xBCA593,
            0x434F67, 0x4C5970, 0x58667A, 0x687585, 0x7A848F, 0x8D9497, 0xA0A19E, 0xB2ADA2, 0x395977, 0x41627F, 0x4D6E89, 0x5C7D94,
            0x6D8C9E, 0x819BA7, 0x94A9AD, 0xA6B5B2, 0x2F6186, 0x366A8E, 0x427698, 0x5084A2, 0x6293AC, 0x75A2B5, 0x88B0BC, 0x9BBCC1,
            0x266893, 0x2E709A, 0x387CA3, 0x4689AE, 0x5898B7, 0x6BA7C0, 0x7FB5C7, 0x92C2CD, 0x206D9B, 0x2775A2, 0x3280AB, 0x408DB5,
            0x519BBF, 0x64AAC8, 0x78B9CF, 0x8BC6D5,
        ]), aspectRatio: 1),
    ]

    public static var ids: [String] { items.map(\.id) }

    public static func item(_ id: String) -> Item? { items.first { $0.id == id } }

    /// «Добавить обложку» — случайная из галереи, как у Notion.
    public static func random(using generator: inout some RandomNumberGenerator) -> Item {
        items.randomElement(using: &generator)!
    }

    /// Картинка заливки: у градиента — сетка цветов, которую рисующий растягивает со сглаживанием.
    /// Неизвестный id (от более новой версии) — `nil`: рисуется заглушка.
    static func image(for item: Item) -> CGImage? {
        switch item.fill {
        case .solid(let color): bitmap(side: 1, colors: [color])
        case .grid(let side, let colors): bitmap(side: smoothSide, colors: smoothed(side: side, colors: colors))
        }
    }

    /// Сетка, растянутая системой, видна квадратами: сначала — гладкая сетка `smoothSide` × `smoothSide`
    /// плавной (кубической Эрмита) смесью соседних цветов, её дорастягивает рисование.
    static let smoothSide = 96

    private static func smoothed(side: Int, colors: [UInt32]) -> [UInt32] {
        func channel(_ color: UInt32, _ shift: UInt32) -> Double { Double(color >> shift & 0xFF) }
        func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        var result: [UInt32] = []
        result.reserveCapacity(smoothSide * smoothSide)
        for row in 0..<smoothSide {
            // Центры ячеек исходной сетки — в серединах её клеток.
            let y = min(max((Double(row) + 0.5) / Double(smoothSide) * Double(side) - 0.5, 0), Double(side - 1))
            let y0 = Int(y), y1 = min(y0 + 1, side - 1), ty = ease(y - Double(y0))
            for column in 0..<smoothSide {
                let x = min(max((Double(column) + 0.5) / Double(smoothSide) * Double(side) - 0.5, 0), Double(side - 1))
                let x0 = Int(x), x1 = min(x0 + 1, side - 1), tx = ease(x - Double(x0))
                let corners = (colors[y0 * side + x0], colors[y0 * side + x1], colors[y1 * side + x0], colors[y1 * side + x1])
                var mixed: UInt32 = 0
                for shift: UInt32 in [16, 8, 0] {
                    let top = channel(corners.0, shift) * (1 - tx) + channel(corners.1, shift) * tx
                    let bottom = channel(corners.2, shift) * (1 - tx) + channel(corners.3, shift) * tx
                    mixed |= UInt32((top * (1 - ty) + bottom * ty).rounded()) << shift
                }
                result.append(mixed)
            }
        }
        return result
    }

    private static func bitmap(side: Int, colors: [UInt32]) -> CGImage? {
        var bytes = colors.flatMap { [UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF), 0xFF] }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
