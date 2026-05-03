//
//  iOSDeviceSettings.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 18.04.2022.
//

import SwiftUI

struct iOSDeviceSettings: View {
    @EnvironmentObject var locationController: LocationController
    
    var body: some View {
        GroupBox {
            if locationController.showSimulatorOption {
                Picker("Device mode", selection: $locationController.deviceMode) {
                    Text("Simulator").tag(LocationController.DeviceMode.simulator)
                    Text("Device").tag(LocationController.DeviceMode.device)
                }.labelsHidden().pickerStyle(.segmented)
            }

            if locationController.deviceMode == .simulator {
                Picker("Simulator:", selection: $locationController.selectedSimulator) {
                    ForEach(locationController.bootedSimulators, id: \.id) { simulator in
                        Text(simulator.name)
                    }
                }

                Button(action: {
                    Task {
                        await locationController.refreshDevices()
                    }
                }, label: {
                    Text("Refresh").frame(maxWidth: .infinity)
                })
            }

            if locationController.deviceMode == .device {
                Picker("Device:", selection: $locationController.selectedDevice) {
                    ForEach(locationController.connectedDevices, id: \.id) { device in
                        Text("\(device.name) (\(device.version))")
                    }
                }

                Button(action: {
                    Task {
                        await locationController.refreshDevices()
                    }
                }, label: {
                    Text("Refresh").frame(maxWidth: .infinity)
                })
                
                Button(action: {
                    if locationController.deviceStatus.isActive {
                        Task { await locationController.stopDevice() }
                    } else {
                        locationController.startDevice()
                    }
                }) {
                    HStack {
                        Image(systemName: locationController.deviceStatus.isActive ? "stop.circle.fill" : "play.circle.fill")
                        Text(locationController.deviceStatus.isActive ? "Stop" : "Start")
                        // Display corresponding status string (from DeviceStatus enum)
                        if !locationController.deviceStatus.displayText.isEmpty {
                            Text("(\(locationController.deviceStatus.displayText))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(locationController.deviceStatus.isActive ? .red : .blue)
                .id("device-status-\(locationController.deviceStatus.displayText)")
            }
        }
    }
}

struct iOSDeviceSettings_Previews: PreviewProvider {
    static var previews: some View {
        iOSDeviceSettings()
    }
}
