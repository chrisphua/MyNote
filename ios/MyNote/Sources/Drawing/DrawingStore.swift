import Foundation
import PencilKit

/// Where ink lives.
///
/// Strokes are kept in their own file, not inside the note. A page of
/// handwriting is tens of kilobytes, and a device rewrites its *entire* backup
/// file whenever anything changes — so putting drawings in the note would mean
/// re-uploading every drawing in it on every debounced keystroke. Keeping each
/// drawing beside the note means only the one that changed has to move.
///
/// The block carries the id and nothing else, which is also what lets Android
/// show a drawing it cannot open without having to download it first.
enum DrawingStore {
    /// Not in Documents: this is app data the user restores from a backup, not
    /// files they should be rummaging through in the Files app.
    private static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drawings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).drawing")
    }

    static func load(_ id: String) -> PKDrawing? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        // A drawing written by a newer PencilKit can fail to decode. Returning
        // nil shows an empty canvas, which is wrong but recoverable; throwing
        // here would take the whole note down with it.
        return try? PKDrawing(data: data)
    }

    static func save(_ drawing: PKDrawing, id: String) throws {
        try drawing.dataRepresentation().write(to: url(for: id), options: .atomic)
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    static func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// A rendering for the note, sized to the width it will be shown at.
    ///
    /// `PKDrawing.image(from:)` renders the ink's own bounds, so an empty
    /// drawing has a zero-size rect and would crash the renderer — hence the
    /// guard rather than an optional-chained call.
    static func preview(_ drawing: PKDrawing, width: CGFloat, scale: CGFloat) -> UIImage? {
        let bounds = drawing.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return drawing.image(from: bounds, scale: scale)
    }
}
