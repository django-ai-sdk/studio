import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Small cross-platform shims so shared views don't need #if for the common cases.
// Platform-specific views (composer text view, split panel, …) still use #if os(...) locally.

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

enum Platform {
    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Puts plain text on the clipboard.
    @MainActor static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    /// Opens a URL outside the app (default browser, Mail, …).
    @MainActor static func openExternally(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// PNG data for uploads.
    var pngRepresentation: Data? {
        #if os(macOS)
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return pngData()
        #endif
    }
}

extension View {
    /// A `frame(minWidth:idealWidth:minHeight:idealHeight:)` that only applies on macOS — sheet
    /// sizes there; iOS sheets size themselves to the screen.
    func macSheetFrame(minWidth: CGFloat, idealWidth: CGFloat, minHeight: CGFloat, idealHeight: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight)
        #else
        self
        #endif
    }
}
