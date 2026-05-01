//
//  LocationSettingsPanel.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 18.04.2022.
//

import SwiftUI
import Foundation

struct LocationSettingsPanel: View {
    @EnvironmentObject var locationController: LocationController
    
    @State private var isPresentedSetToCoordinate = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var latitudeLongitude = ""
    
    // Disable location controls when in iOS device mode but device not connected
    private var shouldDisableLocationControls: Bool {
        return locationController.deviceType == 0 && // iOS
               locationController.deviceMode == .device && // Device mode
               (!locationController.isDeviceActive || locationController.tunnelStatus != "Connected")
    }
    
    var body: some View {
        VStack {
            VStack {
                GroupBox {
                    Picker("Points mode", selection: $locationController.pointsMode) {
                        Text("Single").tag(LocationController.PointsMode.single)
                        Text("Two").tag(LocationController.PointsMode.two)
                    }.pickerStyle(.segmented)

                    if locationController.pointsMode == .single {
                        Button(action: {
                            locationController.setCurrentLocation()
                        }, label: {
                            Text("Set to current location").frame(maxWidth: .infinity)
                        })
                        
                        Button(action: {
                            latitude = ""
                            longitude = ""
                            latitudeLongitude = ""
                            isPresentedSetToCoordinate = true
                        }, label: {
                            Text("Set to Coordinate").frame(maxWidth: .infinity)
                        })
                        .alert("Enter your coordinate", isPresented: $isPresentedSetToCoordinate) {
                            TextField("Latitude, Longitude", text: $latitudeLongitude)
                            Button("Move"){
                                if latitude.isEmpty || longitude.isEmpty {
                                    locationController.setToCoordinate(latLngString: latitudeLongitude)
                                } else {
                                    locationController.setToCoordinate(latString: latitude, lngString: longitude)
                                }
                            }
                            Button("Cancel", role: .cancel) { }
                        }
                    }

                    if locationController.pointsMode == .single {
                        HStack {
                            Button(action: {
                                locationController.setSelectedLocation()
                            }, label: {
                                Text("Set to A").frame(maxWidth: .infinity)
                            })
                            Button(action: {
                                locationController.savePointA()
                            }, label: {
                                Text("Save point A").frame(maxWidth: .infinity)
                            })
                        }
                    }
                    
                    if locationController.pointsMode == .two {
                        Button(action: {
                            if locationController.simulationType == .route {
                                locationController.stopSimulation()
                            } else {
                                locationController.makeRoute(autoSimulate: true)
                            }
                        }, label: {
                            Text(locationController.simulationType == .route ? "Stop simulation" : "Simulate route").frame(maxWidth: .infinity)
                        })
                        .disabled(locationController.simulationType == .fromAToB)

                        Button(action: {
                            if locationController.simulationType == .fromAToB {
                                locationController.stopSimulation()
                            } else {
                                locationController.simulateFromAToB()
                            }
                        }, label: {
                            Text(locationController.simulationType == .fromAToB ? "Stop simulation" : "Simulate from A to B").frame(maxWidth: .infinity)
                        })
                        .disabled(locationController.simulationType == .route)
                    }
                }

        if locationController.pointsMode == .two {
                GroupBox {
                    HStack(alignment: .center) {
                        Slider(value: $locationController.speed, in: 5...200, step: 5) {
                            Text("Speed")
                        }
                        Text("\(Int(locationController.speed.rounded(.up))) km/h")
                    }
                }
                
                    GroupBox {
                        if locationController.useRSD {
                            Picker("Update interval", selection: $locationController.timeScale) {
                                Text("5s").tag(5.0)
                                Text("10s").tag(10.0)
                                Text("15s").tag(15.0)
                            }
                            .pickerStyle(.segmented)
                            .onAppear {
                                locationController.timeScale = 5.0
                            }
                        } else {
                            Picker("Update interval", selection: $locationController.timeScale) {
                                Text("1s").tag(1.0)
                                Text("1.5s").tag(1.5)
                                Text("2s").tag(2.0)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
            }
            .disabled(shouldDisableLocationControls)
            .opacity(shouldDisableLocationControls ? 0.5 : 1.0)

            Divider()
                .padding(.vertical, 8)

            LocationsView()
                .environmentObject(locationController)

            Spacer()
        }
    }
}

struct LocationSettingsPanel_Previews: PreviewProvider {
    static var previews: some View {
        LocationSettingsPanel()
    }
}
