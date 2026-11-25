import AppKit
import Testing
import WebKit

@testable import BuiltinFiles

/// A page on a device's screen lays out at the device's width, scaled down to fit the pane; as designed it fills the
/// pane at its own zoom. The stage hides with its web view.
@MainActor @Test func aDevicesScreenFitsThePane() {
    let web = WKWebView()
    let stage = DeviceStage(web)
    stage.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    stage.device = NSSize(width: 390, height: 844)
    stage.layout()
    let k = (600 - 40) / 844.0
    #expect(abs(web.pageZoom - k) < 0.001)
    #expect(web.frame.width == (390 * k).rounded() && web.frame.midX == 400 && web.frame.maxY == 580)
    stage.device = nil
    stage.layout()
    #expect(web.frame == stage.bounds && web.pageZoom == 1)
    web.isHidden = true
    #expect(stage.isHidden)
}
