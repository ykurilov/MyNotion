import AppKit
import Attachments
import NotesCore
import PageEditor

/// Файлы для образцов картинок, файлов и видео (галерея `--ui-gallery`, «богатая» страница замеров): блоки образцов
/// ссылаются на файлы, которых на Mac нет. Картинки рисуются градиентом нужного размера, прочее — короткий файл.
/// Имена «загружается.png» и «ждёт-отправки.png» остаются без файла — для снимков заглушек.
@MainActor
enum SampleMedia {
    static let placeholderNames: Set<String> = ["загружается.png", "ждёт-отправки.png"]

    /// `pageIds` — только эти страницы (замер на эталоне в 1 000 страниц не перебирает их все).
    static func materialize(in store: NotesStore, attachments: AttachmentStore, pageIds: [UUID]? = nil) {
        let ids = pageIds ?? ((try? store.pageOutline().map(\.id)) ?? [])
        let refs = Optional(ids.flatMap { id in
            (try? store.pageContent(id)?.blocks) ?? []
        })?.filter { BlockKind.withAttachments.contains($0.kind) }.flatMap(\.props.attachmentRefs) ?? []
        var done: Set<UUID> = []
        for ref in refs where done.insert(ref.id).inserted && attachments.fileURL(for: ref.id) == nil {
            guard !placeholderNames.contains(ref.name) else { continue }
            let data = ref.contentType.hasPrefix("public.png") || ref.contentType == "public.jpeg" ? image(named: ref.name)
                : Data("Образец файла «\(ref.name)» для галереи MyNotion.\n".utf8)
            try? attachments.adoptSampleCopy(data, as: ref)
        }
        // Заглушка «Ждёт отправки с другого Mac» — как у файла, которого нет на сервере.
        for ref in refs where ref.name == "ждёт-отправки.png" {
            try? attachments.markWaitingForOtherMac(ref.id)
        }
    }

    /// Картинка 1600 × 900: мягкий градиент со своим оттенком у каждого имени.
    private static func image(named name: String) -> Data {
        let width = 1_600, height = 900
        let hue = CGFloat(abs(name.hashValue % 360)) / 360
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [NSColor(hue: hue, saturation: 0.35, brightness: 0.95, alpha: 1).cgColor,
                      NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.7, alpha: 1).cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
