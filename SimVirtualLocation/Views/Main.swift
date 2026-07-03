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
