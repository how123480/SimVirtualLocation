//
//  Main.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 20.02.2022.
//

import SwiftUI
import AppKit

@main
struct SimVirtualLocationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            let mapView = MapView()
            let locationController = LocationController(mapView: mapView)
            ContentView(mapView: mapView, locationController: locationController)
        }
        // Immersive map window: the map bleeds under the (hidden) title bar and
        // the traffic lights float over it, like first-party Maps. The hidden
        // title-bar strip is still the window-drag region, and SwiftUI's top
        // safe area keeps overlays clear of the traffic lights.
        .windowStyle(.hiddenTitleBar)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // SPM-built executables ship without a proper app bundle / Info.plist.
        // Without an explicit regular activation policy the process launches as
        // .accessory, so its windows can never become key — keyboard events are
        // silently dropped. Force .regular so makeKey / firstResponder work.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Deferred one runloop turn so the SwiftUI window exists before we
        // try to make it key.
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
            }
        }
    }
}
