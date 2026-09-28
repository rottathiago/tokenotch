import AppKit
import CoreGraphics

/// Detects whether a full-screen application window is active on a given display.
enum FullScreenDetector {
    /// Pure function checking whether any layer 0 window belonging to `frontmostPID`
    /// matches or spans the `screenBounds`.
    static func isFullScreen(
        screenBounds: CGRect,
        frontmostPID: pid_t,
        windows: [(pid: pid_t, layer: Int, bounds: CGRect)],
        safeAreaTopInset: CGFloat = 0,
        // The usable desktop on this display, in the same coordinates. Null
        // when the caller cannot say, which keeps the older rules exactly as
        // they were.
        visibleBounds: CGRect = .null
    ) -> Bool {
        for window in windows {
            guard window.pid == frontmostPID, window.layer == 0 else { continue }
            let b = window.bounds

            // Must match screen width (within small tolerance for window borders/rounding)
            guard abs(b.origin.x - screenBounds.origin.x) <= 4,
                  abs(b.width - screenBounds.width) <= 4 else {
                continue
            }

            // Case 1: Spans full screen height (e.g. video, game, or non-notched screen with hidden menu bar)
            if abs(b.origin.y - screenBounds.origin.y) <= 4 &&
               abs(b.height - screenBounds.height) <= 4 {
                return true
            }

            // A window that merely fills the usable desktop is zoomed, not full
            // screen. The rules below otherwise read the two as identical on a
            // display carrying no Dock: the promise that "a window zoomed
            // against the Dock is not full screen" quietly depended on the Dock
            // being there to stop it short of the bottom edge. On a second
            // display it usually is not, so a maximised window took the notch
            // off that screen and left it on the built-in one.
            if !visibleBounds.isNull, matches(b, visibleBounds) { continue }

            // Case 2: Full-screen window on a notched MacBook or with menu bar present.
            // Starts right below notch/menu bar, reaches bottom of screen,
            // and occupies the available display area.
            let maxTopInset = max(safeAreaTopInset, 40.0) + 4.0
            let reachesBottom = abs(b.maxY - screenBounds.maxY) <= 4
            let startsNearTop = b.origin.y >= screenBounds.origin.y - 4 &&
                                b.origin.y <= screenBounds.origin.y + maxTopInset
            let occupiesMainArea = b.height >= screenBounds.height - (maxTopInset + 10)

            if reachesBottom && startsNearTop && occupiesMainArea {
                return true
            }
        }
        return false
    }

    /// Same rect within the tolerance the rules above already use for borders
    /// and rounding.
    private static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= 4 && abs(lhs.origin.y - rhs.origin.y) <= 4
            && abs(lhs.width - rhs.width) <= 4 && abs(lhs.height - rhs.height) <= 4
    }

    /// Whether a full-screen window is currently showing on one display.
    ///
    /// Deliberately independent of which app is frontmost. Focus on a second
    /// display must not reveal the notch over a full-screen app still filling
    /// this one, and an app's full-screen window is often owned by a different
    /// process than the small toolbar or overlay drawn above it — Electron and
    /// Chromium apps such as VS Code and Chrome split windows across helper
    /// processes, so matching only the frontmost window's owner misses them.
    ///
    /// Every window is measured rather than only the front one. Judging depth
    /// by how much of the display a window covers cannot work across the
    /// displays this runs on: an ordinary 1270pt window is most of a laptop
    /// screen but under a quarter of an ultrawide, so any such threshold either
    /// ignores real full-screen apps or hides the notch on a plain desktop.
    /// The geometry rules below are the discriminator instead — an ordinary
    /// window stops short of the Dock or the screen edge.
    static func isFullScreenOnDisplay(
        screenBounds: CGRect,
        windows: [(pid: pid_t, layer: Int, bounds: CGRect)],
        ownPID: pid_t,
        safeAreaTopInset: CGFloat = 0,
        visibleBounds: CGRect = .null
    ) -> Bool {
        for window in windows where window.layer == 0 && window.pid != ownPID {
            if isFullScreen(screenBounds: screenBounds, frontmostPID: window.pid,
                            windows: [window], safeAreaTopInset: safeAreaTopInset,
                            visibleBounds: visibleBounds) {
                return true
            }
        }
        return false
    }

    static func isFullScreenAppVisible(on screen: NSScreen? = NSScreen.main) -> Bool {
        guard let screen = screen ?? NSScreen.main else { return false }

        // Convert NSScreen (AppKit coordinates: origin bottom-left of primary screen)
        // to CoreGraphics coordinates (origin top-left of primary screen).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgScreenBounds = CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )

        // The usable desktop, converted the same way. On a display with no
        // Dock this is the whole screen minus the menu bar, which is exactly
        // the shape a zoomed window takes.
        let cgVisibleBounds = CGRect(
            x: screen.visibleFrame.minX,
            y: primaryHeight - screen.visibleFrame.maxY,
            width: screen.visibleFrame.width,
            height: screen.visibleFrame.height
        )

        let safeTop: CGFloat
        if #available(macOS 12.0, *) {
            safeTop = screen.safeAreaInsets.top
        } else {
            safeTop = 0
        }

        if let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            var extractedWindows: [(pid: pid_t, layer: Int, bounds: CGRect)] = []
            for info in windowInfoList {
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      let layer = info[kCGWindowLayer as String] as? Int,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
                else { continue }
                extractedWindows.append((pid: pid, layer: layer, bounds: bounds))
            }

            return isFullScreenOnDisplay(
                screenBounds: cgScreenBounds,
                windows: extractedWindows,
                ownPID: ProcessInfo.processInfo.processIdentifier,
                safeAreaTopInset: safeTop,
                visibleBounds: cgVisibleBounds
            )
        }

        return false
    }
}
