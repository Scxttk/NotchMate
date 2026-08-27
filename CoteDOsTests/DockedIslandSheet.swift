import XCTest
import SwiftUI
import AppKit
@testable import CoteDOs

/// A contact sheet of the island on each of the four borders, collapsed and
/// open, written to `/tmp/cotedos-docked/`.
///
/// The island turns when it is carried to a side border — tab strip standing on
/// end against the edge, spectrum bars stacked down it, pages sliding
/// vertically — and none of that can be judged from a passing assertion. It
/// also cannot be screenshotted on this machine: `screencapture` needs a
/// Screen Recording grant nothing here can click. So the views are mounted
/// offscreen and captured from their own backing store, the same trick
/// `MarketingShots` uses and for the same reason.
///
/// Not a regression test — it asserts only that each frame rendered at the size
/// its border calls for. Judging it is done by looking at the PNGs.
@MainActor
final class DockedIslandSheet: XCTestCase {

    private static let outputDirectory = URL(fileURLWithPath: "/tmp/cotedos-docked", isDirectory: true)
    private let scale: CGFloat = 2

    /// Every window this test made, held until it is over.
    ///
    /// The wave animates permanently on wall power (see `WaveBarsView.run`), so
    /// a hosting view keeps posting SwiftUI invalidations after its capture is
    /// done. Letting its window go at that point crashes AppKit inside
    /// `_postWindowNeedsUpdateConstraints` — a window mid-teardown being asked
    /// to schedule a layout pass. Blanking the root stops the animation; this
    /// keeps the window alive regardless.
    private var renderWindows: [NSWindow] = []

    func testRenderEveryBorder() throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)

        let viewModel = NotchViewModel()
        let activities = ActivityManager()
        let nowPlaying = NowPlayingManager()
        let shelf = FileShelfModel()
        let pomodoro = PomodoroManager(activities: activities)
        let capture = ObsidianCapture(activities: activities)
        let spectrum = SpectrumAnalyzer(bandCount: 32)

        let settings = UserSettings.shared
        let originalPillOnly = settings.pillSpectrumOnly
        defer {
            settings.pillSpectrumOnly = originalPillOnly
            viewModel.placement = .home
        }
        // The wave in the pill, so a side dock has something to stand up.
        settings.pillSpectrumOnly = true

        nowPlaying.applyForTesting(NowPlayingState(
            isRunning: true,
            isPlaying: true,
            track: NowPlayingTrack(name: "Slow Ascent", artist: "Halbmond", album: "Nordwand",
                                   artworkURL: nil, duration: 252, url: nil),
            position: 97,
            isShuffling: false
        ))
        // A frame of band levels, so the bars have a shape rather than sitting
        // at the floor. Re-published before every capture: the analyzer's own
        // source poll runs during the settle and zeroes the published signal
        // when it finds no tap, which left whole sheets of flat-lined waves.
        let bands = (0..<32).map { Float(0.25 + 0.7 * abs(sin(Double($0) * 0.5))) }
        func feedBands() { spectrum.publishForTesting(bands) }
        feedBands()

        func root() -> NotchRootView {
            NotchRootView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf,
                          activities: activities, pomodoro: pomodoro, capture: capture,
                          spectrum: spectrum)
        }

        for dock in NotchDock.allCases {
            viewModel.placement = NotchPlacement(dock: dock, along: 0)
            let panel = CGSize(width: viewModel.panelWidth, height: viewModel.panelHeight)

            viewModel.islandState = .collapsed
            viewModel.pagesSettled = false
            feedBands()
            let collapsed = try render(root(), size: panel)
            try write(collapsed, named: "\(dock.rawValue)-collapsed")

            viewModel.islandState = .expanded
            viewModel.pagesSettled = true
            for tab in NotchViewModel.Tab.allCases {
                viewModel.selectedTab = tab
                feedBands()
                try write(try render(root(), size: panel), named: "\(dock.rawValue)-\(tab.rawValue)")
            }

            // The panel turns with the island: landscape top and bottom,
            // portrait on the sides. Everything drawn above depends on it.
            XCTAssertEqual(panel.width > panel.height, dock.isHorizontal,
                           "\(dock) panel is \(panel)")
        }

        // And the corners, where the island is pinned to one end of its panel
        // rather than centred in it. Rendered at panel size with the plate
        // showing through, so the pinning is what you are looking at.
        viewModel.selectedTab = .music
        for dock in NotchDock.allCases {
            for anchor in [NotchPlacement.Anchor.start, .end] {
                viewModel.placement = NotchPlacement(dock: dock, anchor: anchor)
                let panel = CGSize(width: viewModel.panelWidth, height: viewModel.panelHeight)
                viewModel.islandState = .collapsed
                viewModel.pagesSettled = false
                feedBands()
                try write(try render(root(), size: panel), named: "corner-\(dock.rawValue)-\(anchor.rawValue)")
            }
        }
    }

    // MARK: Offscreen capture
    //
    // Lifted from `MarketingShots.render` — an `NSHostingView` in a real but
    // invisible window, because that is what makes `AsyncImage` resolve and the
    // AppKit-backed controls realize themselves. See the comment there.

    private func render<V: View>(_ view: V, size rawSize: CGSize) throws -> CGImage {
        let size = CGSize(width: rawSize.width.rounded(.up), height: rawSize.height.rounded(.up))
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderBack(nil)
        renderWindows.append(window)

        host.layoutSubtreeIfNeeded()
        settle(0.6)

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                                "no backing store for a \(size) view")
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertEqual(rep.pixelsWide, Int(size.width * scale),
                       "captured at \(rep.pixelsWide)px for \(size.width)pt — wrong backing scale")
        let image = try XCTUnwrap(rep.cgImage, "no image from the backing store")

        // Take the island out of the tree the moment it is captured: an idle
        // hosting view costs nothing, an animating one keeps a 30 Hz wave
        // running for the rest of the test.
        host.rootView = AnyView(Color.clear)
        host.layoutSubtreeIfNeeded()
        window.orderOut(nil)
        settle(0.05)
        return image
    }

    /// On a dark plate: the island is near-black on transparent, and a PNG with
    /// an alpha hole reads as white in most viewers — which is the one
    /// background it disappears against.
    private func write(_ image: CGImage, named name: String) throws {
        let width = image.width
        let height = image.height
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw XCTSkip("no bitmap context") }
        context.setFillColor(CGColor(red: 0.42, green: 0.40, blue: 0.50, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let plated = try XCTUnwrap(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: plated)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
