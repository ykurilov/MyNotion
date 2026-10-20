import AppKit
import AVFoundation
import AVKit

/// Проигрыватель видеофайла (research R8): `AVPlayerView` создаётся по нажатию «Играть» и отпускается, когда вид
/// уходит с экрана; в окне играет одно видео.
@MainActor
public final class VideoFilePlayerView: NSView {
    public let fileURL: URL
    public private(set) var playerView: AVPlayerView?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public var isPlaying: Bool { playerView != nil }

    public func play() {
        guard playerView == nil else { return }
        if let window { EmbeddedPlayers.willStart(self, in: window) }
        let view = AVPlayerView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        let player = AVPlayer(url: fileURL)
        view.player = player
        addSubview(view)
        playerView = view
        player.play()
    }

    public func close() {
        guard let view = playerView else { return }
        view.player?.pause()
        view.player = nil
        view.removeFromSuperview()
        playerView = nil
        EmbeddedPlayers.didClose(self)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            close()
        } else if playerView != nil {
            EmbeddedPlayers.willStart(self, in: window!)
        }
    }
}

/// Первый кадр видеофайла (research R8): снимок `AVAssetImageGenerator`, сохраняется рядом с файлом
/// (`.poster.jpg`) — второй раз не считается.
public enum VideoPoster {
    public static func image(forVideoAt url: URL) async -> NSImage? {
        let poster = url.deletingLastPathComponent().appendingPathComponent(".poster.jpg")
        if let saved = NSImage(contentsOf: poster) { return saved }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_920, height: 1_920)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? data.write(to: poster)
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
