import SwiftUI
import MetalKit

/// The full-screen Metal view: camera, light and markers. Taps and drags go to the controller.
struct ARMetalView: UIViewRepresentable {
    let controller: LumenController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.backgroundColor = .black
        if let renderer = LightRenderer(view: view) {
            view.delegate = renderer
            context.coordinator.renderer = renderer     // MTKView.delegate is weak
            controller.attach(renderer: renderer)
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let controller: LumenController
        var renderer: LightRenderer?
        private var draggingCorner = false

        init(controller: LumenController) {
            self.controller = controller
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            controller.tap(at: gesture.location(in: view), viewSize: view.bounds.size)
        }

        /// Dragging a window corner while marking.
        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            switch gesture.state {
            case .began:
                // The pan is recognised after the finger has moved a little: test where it first touched.
                let t = gesture.translation(in: view)
                let start = CGPoint(x: location.x - t.x, y: location.y - t.y)
                draggingCorner = controller.beginCornerDrag(at: start, viewSize: view.bounds.size)
                if draggingCorner { controller.updateCornerDrag(at: location, viewSize: view.bounds.size) }
            case .changed:
                if draggingCorner { controller.updateCornerDrag(at: location, viewSize: view.bounds.size) }
            default:
                if draggingCorner { controller.endCornerDrag() }
                draggingCorner = false
            }
        }
    }
}
