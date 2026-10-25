import SwiftUI
import UIKit

/// ピンチズーム・パン・ダブルタップ拡大に対応した画像ビューアーコンポーネント
/// - UIScrollView のネイティブズームエンジンを活用し、メモリ負荷と滑らかな操作性を両立
/// - 拡大中 (zoomScale > 1.01) は isZoomed を true にし、親の次／前スワイプジェスチャーを自動抑止
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    let onTap: () -> Void

    func makeUIView(context: Context) -> ImageScrollView {
        let scrollView = ImageScrollView()
        scrollView.onTap = onTap
        scrollView.onZoomChanged = { zoomed in
            DispatchQueue.main.async {
                self.isZoomed = zoomed
            }
        }
        scrollView.display(image: image)
        return scrollView
    }

    func updateUIView(_ uiView: ImageScrollView, context: Context) {
        if uiView.currentImage !== image {
            uiView.display(image: image)
        }
        uiView.onTap = onTap
    }
}

final class ImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    var onTap: (() -> Void)?
    var onZoomChanged: ((Bool) -> Void)?
    private(set) var currentImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        minimumZoomScale = 1.0
        maximumZoomScale = 4.0

        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        // ダブルタップで 1.0x ⇔ 2.5x トグル
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        // シングルタップで UI 表示・非表示トグル（ダブルタップ優先）
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    func display(image: UIImage) {
        currentImage = image
        imageView.image = image
        setZoomScale(1.0, animated: false)
        updateImageFrame()
        onZoomChanged?(false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        centerImage()
    }

    private func updateImageFrame() {
        guard let img = currentImage, bounds.width > 0, bounds.height > 0 else { return }
        let aspectWidth = bounds.width / img.size.width
        let aspectHeight = bounds.height / img.size.height
        let minRatio = min(aspectWidth, aspectHeight)

        let imageSize = CGSize(width: img.size.width * minRatio, height: img.size.height * minRatio)
        imageView.frame = CGRect(origin: .zero, size: imageSize)
        contentSize = imageSize
        centerImage()
    }

    private func centerImage() {
        let boundsSize = bounds.size
        var contentsFrame = imageView.frame

        if contentsFrame.size.width < boundsSize.width {
            contentsFrame.origin.x = (boundsSize.width - contentsFrame.size.width) / 2.0
        } else {
            contentsFrame.origin.x = 0.0
        }

        if contentsFrame.size.height < boundsSize.height {
            contentsFrame.origin.y = (boundsSize.height - contentsFrame.size.height) / 2.0
        } else {
            contentsFrame.origin.y = 0.0
        }

        imageView.frame = contentsFrame
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        onZoomChanged?(zoomScale > 1.01)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onZoomChanged?(scale > 1.01)
    }

    // MARK: - Gestures

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        onTap?()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1.0, animated: true)
            onZoomChanged?(false)
        } else {
            let pointInView = recognizer.location(in: imageView)
            let newScale: CGFloat = 2.5
            let w = bounds.width / newScale
            let h = bounds.height / newScale
            let x = pointInView.x - (w / 2.0)
            let y = pointInView.y - (h / 2.0)
            let rectToZoom = CGRect(x: x, y: y, width: w, height: h)
            zoom(to: rectToZoom, animated: true)
            onZoomChanged?(true)
        }
    }
}
