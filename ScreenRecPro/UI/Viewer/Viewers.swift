import AVKit
import ImageIO
import SwiftUI

/// Port of Android's PlayerActivity. Leaving counts toward the interstitial cadence.
struct PlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var share = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player { VideoPlayer(player: player).ignoresSafeArea(edges: .bottom) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: { Image(systemName: "xmark") }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { share = true } label: { Label(L("share"), systemImage: "square.and.arrow.up") }
                    Spacer()
                    Button { reopen(.trim(urls: [url], mode: .trim)) } label: { Label(L("trim_video"), systemImage: "scissors") }
                    Spacer()
                    Button { reopen(.studio(urls: [url], mode: .edit)) } label: { Label(L("edit_video"), systemImage: "slider.horizontal.3") }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: { Label(L("delete"), systemImage: "trash") }
                }
            }
            .toolbarBackground(.black, for: .bottomBar, .navigationBar)
            .toolbarColorScheme(.dark, for: .bottomBar, .navigationBar)
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $share) { ShareSheet(items: [url]) }
        .confirmationDialog(L("delete"), isPresented: $confirmDelete) {
            Button(L("delete"), role: .destructive) {
                if let item = MediaLibrary.shared.videos.first(where: { $0.url == url }) {
                    MediaLibrary.shared.delete([item])
                }
                SoundFx.dismiss()
                close()
            }
        }
    }

    private func close() {
        player?.pause()
        Router.shared.closeFeature()
    }

    private func reopen(_ route: Route) {
        player?.pause()
        Router.shared.route = nil
        onMain(after: 0.45) { Router.shared.open(route) }
    }
}

/// Port of Android's PhotoViewerActivity: pinch to zoom, share, edit, delete.
struct PhotoViewerView: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var share = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if MediaLibrary.kindOf(url) == .gif {
                    AnimatedImageView(url: url)
                } else if let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(MagnificationGesture()
                            .onChanged { scale = max(1, min(6, lastScale * $0)) }
                            .onEnded { _ in lastScale = scale; if scale == 1 { offset = .zero; lastOffset = .zero } })
                        .simultaneousGesture(DragGesture()
                            .onChanged { g in
                                guard scale > 1 else { return }
                                offset = CGSize(width: lastOffset.width + g.translation.width,
                                                height: lastOffset.height + g.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset })
                        .onTapGesture(count: 2) {
                            withAnimation { scale = scale > 1 ? 1 : 2.5; lastScale = scale; offset = .zero; lastOffset = .zero }
                        }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { Router.shared.closeFeature() } label: { Image(systemName: "xmark") }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { share = true } label: { Label(L("share"), systemImage: "square.and.arrow.up") }
                    Spacer()
                    if MediaLibrary.kindOf(url) == .photo {
                        Button {
                            Router.shared.route = nil
                            onMain(after: 0.45) {
                                Router.shared.open(.photoEditor(url, startWithBrush: false))
                            }
                        } label: { Label(L("edit_photo"), systemImage: "slider.horizontal.3") }
                        Spacer()
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label(L("delete"), systemImage: "trash") }
                }
            }
            .toolbarBackground(.black, for: .bottomBar, .navigationBar)
            .toolbarColorScheme(.dark, for: .bottomBar, .navigationBar)
        }
        .sheet(isPresented: $share) { ShareSheet(items: [url]) }
        .confirmationDialog(L("delete"), isPresented: $confirmDelete) {
            Button(L("delete"), role: .destructive) {
                if let item = MediaLibrary.shared.photos.first(where: { $0.url == url }) {
                    MediaLibrary.shared.delete([item])
                }
                SoundFx.dismiss()
                Router.shared.closeFeature()
            }
        }
    }
}

/// Plays a GIF from disk (UIImage.animatedImage from the ImageIO frames).
struct AnimatedImageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let count = CGImageSourceGetCount(src)
            var frames: [UIImage] = []
            var duration = 0.0
            for i in 0..<count {
                guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
                frames.append(UIImage(cgImage: cg))
                let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
                let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                duration += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
            view.image = UIImage.animatedImage(with: frames, duration: max(0.1, duration))
        }
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}
}
