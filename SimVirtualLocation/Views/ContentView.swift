//
//  ContentView.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 20.02.2022.
//

import SwiftUI
import MapKit

struct ContentView: View {

    let mapView: MapView
    @ObservedObject var locationController: LocationController
    @State private var showSidePanel: Bool = true
    @State private var isDebugMode: Bool = false
    @State private var eventMonitor: Any?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack {
            ZStack(alignment: .topLeading) {
                // 地圖底層
                ZStack(alignment: .bottomTrailing) {
                    ZStack(alignment: .bottomLeading) {
                        mapView.frame(minWidth: 400)
                        
                        if isDebugMode {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(locationController.logs.reversed()) { log in
                                            Text("\(locationController.dateFormatter.string(from: log.date)): \(log.message)")
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundColor(.white)
                                                .id(log.id)
                                        }
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(width: 400)
                                .frame(maxHeight: 250)
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(8)
                                .padding()
                                .onChange(of: locationController.logs.count) { _ in
                                    if let lastId = locationController.logs.first?.id {
                                        withAnimation {
                                            proxy.scrollTo(lastId, anchor: .bottom)
                                        }
                                    }
                                }
                                .onAppear {
                                    if let lastId = locationController.logs.first?.id {
                                        proxy.scrollTo(lastId, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                    
                    // 地圖縮放按鈕
                    VStack {
                        Image(systemName: "plus")
                            .foregroundColor(Color.white)
                            .frame(width: 32, height: 32)
                            .background(Color.secondary)
                            .opacity(0.5)
                            .cornerRadius(16)
                            .onTapGesture {
                                var region: MKCoordinateRegion = mapView.mkMapView.region
                                region.span.latitudeDelta /= 2.0
                                region.span.longitudeDelta /= 2.0
                                mapView.mkMapView.setRegion(region, animated: true)
                            }
                        Image(systemName: "minus")
                            .foregroundColor(Color.white)
                            .frame(width: 32, height: 32)
                            .background(Color.secondary)
                            .opacity(0.5)
                            .cornerRadius(16)
                            .onTapGesture {
                                var region: MKCoordinateRegion = mapView.mkMapView.region
                                region.span.latitudeDelta *= 2.0
                                region.span.longitudeDelta *= 2.0
                                mapView.mkMapView.setRegion(region, animated: true)
                            }
                        Image(systemName: "location")
                            .foregroundColor(Color.white)
                            .frame(width: 32, height: 32)
                            .background(Color.secondary)
                            .opacity(0.5)
                            .cornerRadius(16)
                            .onTapGesture {
                                locationController.updateMapRegion(force: true)
                            }
                    }
                    .padding()
                    .padding(.bottom, 20)
                    .padding(.trailing, showSidePanel ? 360 : 0) 
                    .animation(.spring(), value: showSidePanel)
                }

                // 搜尋框 (左上)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                            .padding(.leading, 12)
                        TextField("Search location...", text: $locationController.searchQuery)
                            .focused($isSearchFocused)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding(8)
                            .onSubmit {
                                locationController.performFullSearch()
                            }
                    }
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                    .cornerRadius(8)
                    .padding()

                    if (!locationController.searchResults.isEmpty || !locationController.fullSearchResults.isEmpty) && !locationController.searchQuery.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                if !locationController.fullSearchResults.isEmpty {
                                    ForEach(locationController.fullSearchResults, id: \.self) { item in
                                        Button(action: {
                                            locationController.selectMapItem(item)
                                        }) {
                                            HStack(spacing: 12) {
                                                Image(systemName: "mappin.and.ellipse")
                                                    .foregroundColor(.red)
                                                    .frame(width: 20)

                                                VStack(alignment: .leading) {
                                                    Text(item.name ?? item.placemark.title ?? "Unknown")
                                                        .font(.headline)
                                                        .foregroundColor(.primary)
                                                    if let title = item.placemark.title, title != item.name {
                                                        Text(title)
                                                            .font(.subheadline)
                                                            .foregroundColor(.secondary)
                                                    }
                                                }
                                            }
                                            .padding(.vertical, 8)
                                            .padding(.horizontal)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        Divider()
                                    }
                                } else {
                                    ForEach(locationController.searchResults, id: \.self) { completion in
                                        Button(action: {
                                            locationController.selectSearchCompletion(completion)
                                        }) {
                                            HStack(spacing: 12) {
                                                Image(systemName: completion.subtitle.contains(",") ? "building.2.fill" : "mappin.and.ellipse")
                                                    .foregroundColor(.blue)
                                                    .frame(width: 20)

                                                VStack(alignment: .leading) {
                                                    Text(completion.title)
                                                        .font(.headline)
                                                        .foregroundColor(.primary)
                                                    if !completion.subtitle.isEmpty {
                                                        Text(completion.subtitle)
                                                            .font(.subheadline)
                                                            .foregroundColor(.secondary)
                                                    }
                                                }
                                            }
                                            .padding(.vertical, 8)
                                            .padding(.horizontal)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 300)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }
                }
                .frame(width: 300)

                // 右側收合按鈕與面板
                HStack(spacing: 0) {
                    Spacer()
                        .allowsHitTesting(false) // 讓點擊穿透 Spacer 到地圖與按鈕
                    
                    // 收合按鈕 (拉桿) - 稍微加寬並美化
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                            .frame(width: 28, height: 80)
                            .shadow(radius: 5)
                        
                        Image(systemName: showSidePanel ? "chevron.right" : "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring()) {
                            showSidePanel.toggle()
                        }
                    }
                    .padding(.trailing, showSidePanel ? -14 : 10) // 展開時讓拉桿與面板重疊，收合時靠右邊緣
                    .zIndex(1)

                    if showSidePanel {
                        HStack(alignment: .top, spacing: 0) {
                            HStack(alignment: .top, spacing: 0) {
                                // 設定面板 (Control Panel)
                                VStack(spacing: 16) {
                                    if locationController.showAndroidOption {
                                        Picker("Device mode", selection: $locationController.deviceType) {
                                            Text("iOS").tag(0)
                                            Text("Android").tag(1)
                                        }.labelsHidden().pickerStyle(.segmented)
                                    }

                                    if locationController.deviceType == 0 {
                                        iOSPanel()
                                            .environmentObject(locationController)
                                    } else {
                                        AndroidPanel()
                                            .environmentObject(locationController)
                                    }

                                    Spacer()

                                    Button(action: {
                                        let log = locationController.logs.map { entry in
                                            let date = locationController.dateFormatter.string(from: entry.date)
                                            let message = entry.message
                                            return "\(date): \(message)"
                                        }.joined(separator: "\n\n")
                                        let pasteboard = NSPasteboard.general
                                        pasteboard.declareTypes([.string], owner: nil)
                                        pasteboard.setString(log, forType: .string)
                                    }) {
                                        HStack {
                                            Image(systemName: "doc.on.doc")
                                            Text("Logs")
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .frame(width: 300)
                                .padding(20)
                            }
                            .background(
                                ZStack {
                                    Color.gray.opacity(0.15) // 透明灰
                                    Rectangle().fill(.ultraThinMaterial)
                                }
                            )
                            .cornerRadius(20)
                            .shadow(color: Color.black.opacity(0.2), radius: 15, x: -5, y: 5)
                            .padding(.vertical, 40)
                            .padding(.trailing, 20)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 800, minHeight: 500)
            .animation(.spring(), value: showSidePanel)
            .modifier(Alert(isPresented: $locationController.showingAlert, text: locationController.alertText))
        }
        .frame(minHeight: 800)
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                let isKeyDown = event.type == .keyDown
                
                // Handle Esc key (keyCode 53) to unfocus
                if isKeyDown, event.keyCode == 53 {
                    if isSearchFocused {
                        isSearchFocused = false
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        return nil
                    }
                }

                // Toggle Debug Mode (d)
                if isKeyDown,
                   event.charactersIgnoringModifiers == "d",
                   !event.modifierFlags.contains(.command),
                   !event.modifierFlags.contains(.control),
                   !event.modifierFlags.contains(.option) {

                    if isSearchFocused {
                        return event
                    }

                    if let firstResponder = NSApp.keyWindow?.firstResponder,
                       firstResponder.isKind(of: NSTextView.self) {
                        return event
                    }

                    isDebugMode.toggle()
                    return nil
                }

                // Joystick
                if [123, 124, 125, 126].contains(event.keyCode) {
                    if isSearchFocused {
                        return event
                    }
                    locationController.handleKeyEvent(event)
                    return event
                }

                return event
            }
        }        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    init(mapView: MapView, locationController: LocationController) {
        self.mapView = mapView
        self.locationController = locationController
    }
}

// 輔助擴展，用於自定義圓角
extension View {
    func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: RectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let p1 = CGPoint(x: rect.minX, y: rect.minY)
        let p2 = CGPoint(x: rect.maxX, y: rect.minY)
        let p3 = CGPoint(x: rect.maxX, y: rect.maxY)
        let p4 = CGPoint(x: rect.minX, y: rect.maxY)

        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))

        if corners.contains(.topRight) {
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)
        } else {
            path.addLine(to: p2)
        }

        if corners.contains(.bottomRight) {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)
        } else {
            path.addLine(to: p3)
        }

        if corners.contains(.bottomLeft) {
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)
        } else {
            path.addLine(to: p4)
        }

        if corners.contains(.topLeft) {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
        } else {
            path.addLine(to: p1)
        }

        path.closeSubpath()
        return path
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let mapView = MapView()
        let locationController = LocationController(mapView: mapView)
        ContentView(mapView: mapView, locationController: locationController)
    }
}

struct Alert: ViewModifier {
    let isPresented: Binding<Bool>
    let text: String

    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content
                .alert(text, isPresented: isPresented) {
                    Text("OK")
                }
        } else {
            content.alert(isPresented: isPresented) {
                SwiftUI.Alert(
                    title: Text(text)
                )
            }
        }
    }
}
