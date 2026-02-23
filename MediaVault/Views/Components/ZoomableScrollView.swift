import UIKit
import SwiftUI

/// UIScrollView-based pinch-zoom container.
/// At 1x zoom the pan gesture is suppressed so the parent TabView can swipe pages.
struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    @Binding var showOverlay: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PassthroughScrollView {
        let sv = PassthroughScrollView()
        sv.minimumZoomScale = 1.0
        sv.maximumZoomScale = 5.0
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.backgroundColor = .clear
        sv.delegate = context.coordinator

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = .clear
        sv.addSubview(iv)

        // Give PassthroughScrollView a direct reference so layoutSubviews
        // can keep the frame correct without going through the coordinator.
        sv.managedImageView = iv
        context.coordinator.imageView = iv

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleSingleTap))
        singleTap.require(toFail: doubleTap)
        sv.addGestureRecognizer(singleTap)

        return sv
    }

    func updateUIView(_ sv: PassthroughScrollView, context: Context) {
        // Frame management is handled entirely by PassthroughScrollView.layoutSubviews,
        // which fires after every Auto Layout pass when bounds are already final.
        // Nothing to do here.
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableScrollView
        weak var imageView: UIImageView?

        init(_ parent: ZoomableScrollView) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let iv = imageView else { return }
            let b = scrollView.bounds.size
            iv.frame.origin = CGPoint(
                x: iv.frame.width  < b.width  ? (b.width  - iv.frame.width)  / 2 : 0,
                y: iv.frame.height < b.height ? (b.height - iv.frame.height) / 2 : 0
            )
        }

        @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard let sv = gr.view as? UIScrollView else { return }
            if sv.zoomScale > sv.minimumZoomScale {
                sv.setZoomScale(sv.minimumZoomScale, animated: true)
            } else {
                let pt = gr.location(in: imageView)
                let w = sv.bounds.width / 2.5
                let h = sv.bounds.height / 2.5
                sv.zoom(to: CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h), animated: true)
            }
        }

        @objc func handleSingleTap() {
            parent.showOverlay.toggle()
        }
    }
}

/// Keeps the imageView filling its bounds at 1x zoom (via layoutSubviews, not updateUIView),
/// and blocks the pan gesture at minimum zoom so the parent TabView can handle page swipes.
final class PassthroughScrollView: UIScrollView {
    weak var managedImageView: UIImageView?

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only reset when not zoomed so we don't fight an in-progress pinch.
        guard let iv = managedImageView, zoomScale <= minimumZoomScale else { return }
        if iv.frame.size != bounds.size {
            iv.frame = bounds
            contentSize = bounds.size
        }
    }

    override func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
        if gr === panGestureRecognizer {
            return zoomScale > minimumZoomScale
        }
        return super.gestureRecognizerShouldBegin(gr)
    }
}
