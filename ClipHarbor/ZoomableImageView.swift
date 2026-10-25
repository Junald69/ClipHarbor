import SwiftUI
import UIKit

/// ピンチズーム・パン・ダブルタップ拡大・スワイプ移動に対応した画像ビューアーコンポーネント
/// - UIScrollView のネイティブズームエンジンを活用し、メモリ負荷と滑らかな操作性を両立
/// - 拡大中 (zoomScale > 1.01) は isZoomed を true にし、次／前スワイプジェスチャーを自動抑止
/// - bounds 決定前（初回 makeUIView）の 0x0 によるブラックアウトを解消（layoutSubviews / updateImageFrame で再計算）
/// - 画像切り替え時も zoomScale = 1.0, contentOffset = .zero に初期化して新しいアスペクト比で再配置
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    let onTap: () -> Void
    var onSwipeNext: (() -> Void)? = nil
    var onSwipePrevious: (() -> Void)? = nil

    func makeUIView(context: Context) -> ImageScrollView {
        let scrollView = ImageScrollView()
        scrollView.onTap = onTap
        scrollView.onSwipeNext = onSwipeNext
        scrollView.onSwipePrevious = onSwipePrevious
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
        uiView.onSwipeNext = onSwipeNext
        uiView.onSwipePrevious = onSwipePrevious
    }
}

final class ImageScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let imageView = UIImageView()
    var onTap: (() -> Void)?
    var onSwipeNext: (() -> Void)?
    var onSwipePrevious: (() -> Void)?
    var onZoomChanged: ((Bool) -> Void)?
    private(set) var currentImage: UIImage?

    private var lastBoundsSize: CGSize = .zero
    private var needsLayoutUpdate: Bool = false
    private var swipePanGesture: UIPanGestureRecognizer?

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

        // 未ズーム時の水平スワイプ検出（次へ／前へ移動）
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        addGestureRecognizer(pan)
        self.swipePanGesture = pan
    }

    func display(image: UIImage) {
        currentImage = image
        imageView.image = image
        setZoomScale(1.0, animated: false)
        contentOffset = .zero
        needsLayoutUpdate = true

        if bounds.width > 0 && bounds.height > 0 {
            updateImageFrame()
            lastBoundsSize = bounds.size
            needsLayoutUpdate = false
        }
        onZoomChanged?(false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize || needsLayoutUpdate {
            lastBoundsSize = bounds.size
            needsLayoutUpdate = false
            updateImageFrame()
        } else {
            centerImage()
        }
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

    // MARK: - UIGestureRecognizerDelegate

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == swipePanGesture {
            // 未ズーム時 (zoomScale <= 1.01) のみスワイプ判定を有効にする
            // 拡大中は画像の端までスクロールしても誤って次へ移動しない
            guard zoomScale <= 1.01 else { return false }
            guard let pan = swipePanGesture else { return false }
            let velocity = pan.velocity(in: self)
            // 水平方向が垂直方向より優位 (abs(vx) > abs(vy) * 1.5) かつ十分な水平速度がある場合のみ開始
            return abs(velocity.x) > abs(velocity.y) * 1.5 && abs(velocity.x) > 150
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == swipePanGesture || otherGestureRecognizer == swipePanGesture {
            // 未ズーム時は UIScrollView の pan と共存可能
            return zoomScale <= 1.01
        }
        return false
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

    @objc private func handleSwipePan(_ recognizer: UIPanGestureRecognizer) {
        guard zoomScale <= 1.01 else { return }
        guard recognizer.state == .ended else { return }
        let translation = recognizer.translation(in: self)
        let velocity = recognizer.velocity(in: self)

        // 水平優位性判定（斜めドラッグを確実に除外）
        guard abs(translation.x) > abs(translation.y) * 1.5 else { return }

        // 移動量しきい値 (50pt以上) または高速フリック (速度400pt/s以上かつ20pt以上移動)
        if translation.x < -50 || (velocity.x < -400 && translation.x < -20) {
            // 指を右から左へ = 次へ (Next)
            onSwipeNext?()
        } else if translation.x > 50 || (velocity.x > 400 && translation.x > 20) {
            // 指を左から右へ = 前へ (Previous)
            onSwipePrevious?()
        }
    }
}
