import SwiftUI
import PencilKit

/// The drawing surface.
///
/// A thin wrapper: PencilKit already handles Apple Pencil, palm rejection,
/// pressure and tilt, and its ink engine is the one every other Apple app uses.
/// Writing a stroke engine to match it would be weeks of work to arrive
/// somewhere worse.
struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    /// Finger drawing is allowed: most people do not own a Pencil, and a note
    /// app that only works with one is a note app most people cannot draw in.
    var allowsFingerDrawing = true

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        canvas.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
        canvas.alwaysBounceVertical = true
        canvas.backgroundColor = .clear
        canvas.isOpaque = false

        // The tool picker is a floating palette owned by the responder chain, so
        // the canvas has to be first responder for it to appear at all.
        let picker = context.coordinator.toolPicker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }

        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // Only when it genuinely differs: assigning `drawing` resets the undo
        // stack and interrupts a stroke in progress.
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let parent: DrawingCanvas
        let toolPicker = PKToolPicker()

        init(_ parent: DrawingCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }
}
