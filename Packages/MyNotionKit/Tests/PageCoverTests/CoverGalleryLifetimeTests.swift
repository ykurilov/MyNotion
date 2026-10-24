import AppKit
import Testing
@testable import PageCover

@Suite("Галерея обложек: время жизни пикселей")
struct CoverGalleryLifetimeTests {
    @Test("Все градиенты и цвета сохраняют крайние пиксели после создания других обложек")
    func imagesOwnTheirPixels() throws {
        let images = try CoverGallery.items.map { item in
            (item, try #require(CoverGallery.image(for: item)))
        }
        // Имитируем возврат на страницу и работу других обложек после выхода bitmap() из scope.
        let later = try (0..<16).map { index in
            try #require(CoverGallery.image(for: CoverGallery.items[index % CoverGallery.items.count]))
        }
        withExtendedLifetime(later) {
            for (item, image) in images {
                let endpoints: (UInt32, UInt32)
                switch item.fill {
                case .solid(let color): endpoints = (color, color)
                case .grid(_, let colors): endpoints = (colors.first!, colors.last!)
                }
                let data = image.dataProvider!.data! as Data
                let first = Array(data.prefix(4))
                let lastOffset = (image.height - 1) * image.bytesPerRow + (image.width - 1) * 4
                let last = Array(data[lastOffset..<(lastOffset + 4)])
                #expect(first == rgba(endpoints.0), "\(item.id): начало \(first), ожидалось \(rgba(endpoints.0))")
                #expect(last == rgba(endpoints.1), "\(item.id): конец \(last), ожидалось \(rgba(endpoints.1))")
            }
        }
    }

    private func rgba(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255), 255]
    }
}
