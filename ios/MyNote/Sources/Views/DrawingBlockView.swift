import SwiftUI
import PencilKit
import MyNoteCore

/// A drawing inside a note: a preview that opens a full canvas when tapped.
///
/// Editing happens in a sheet rather than inline. Ink and text want opposite
/// things from a scroll view — one needs every drag to draw, the other needs
/// every drag to scroll — and trying to share a gesture space makes both worse.
struct DrawingBlockView: View {
    let attachmentId: String
    let onEdited: () -> Void

    @Environment(ThemeManager.self) private var theme
    @State private var drawing = PKDrawing()
    @State private var isEditing = false
    @State private var loaded = false

    var body: some View {
        Button {
            isEditing = true
        } label: {
            content
        }
        .buttonStyle(.plain)
        .onAppear {
            guard !loaded else { return }
            drawing = DrawingStore.load(attachmentId) ?? PKDrawing()
            loaded = true
        }
        .sheet(isPresented: $isEditing) {
            DrawingEditor(attachmentId: attachmentId, drawing: $drawing, onSave: onEdited)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image = DrawingStore.preview(drawing, width: 0, scale: UIScreen.main.scale) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 320)
                .padding(8)
                .background(theme.current.surface)
                .clipShape(RoundedRectangle(cornerRadius: theme.current.cornerRadius))
                .accessibilityLabel("Drawing")
        } else {
            // Empty, or written by a PencilKit we could not read.
            RoundedRectangle(cornerRadius: theme.current.cornerRadius)
                .fill(theme.current.surface)
                .frame(height: 140)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "scribble.variable").font(.system(size: 24))
                        Text("Tap to draw").font(theme.current.font(.caption))
                    }
                    .foregroundStyle(theme.current.textSecondary)
                }
                .accessibilityLabel("Empty drawing")
        }
    }
}

/// Full-screen canvas with PencilKit's own tool palette.
private struct DrawingEditor: View {
    let attachmentId: String
    @Binding var drawing: PKDrawing
    let onSave: () -> Void

    @Environment(ThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var working = PKDrawing()
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            DrawingCanvas(drawing: $working)
                .background(theme.current.background)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Drawing")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { save() }
                    }
                }
                .onAppear { working = drawing }
                .alert("Couldn't save the drawing", isPresented: $saveFailed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Your device may be out of space. The drawing is still on screen — try again once you've freed some up.")
                }
        }
    }

    private func save() {
        do {
            try DrawingStore.save(working, id: attachmentId)
            drawing = working
            onSave()
            dismiss()
        } catch {
            // Do not dismiss: dismissing would throw the work away silently,
            // which is the one outcome worse than an alert.
            saveFailed = true
        }
    }
}
