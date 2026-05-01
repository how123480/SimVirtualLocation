# SimVirtualLocation

Easy to use MacOS 11+ application for easy mocking iOS device and simulator location in realtime. Built on top of [set-simulator-location](https://github.com/MobileNativeFoundation/set-simulator-location) for iOS Simulators and [pymobiledevice3](https://github.com/doronz88/pymobiledevice3). Android support is realized with [SimVirtualLocation](https://github.com/nexron171/android-mock-location-for-development) android app which is a fork from [android-mock-location-for-development](https://github.com/amotzte/android-mock-location-for-development).

## Features

- Supports both iOS (Simulators and Physical Devices) and Android Devices.
- Set location to current Mac's location.
- Set location to a specific point on the map.
- Create a route between multiple points and simulate moving with desired speed.
- Easy to use map interface.
- **Map Search**: Easily find specific addresses or points of interest using the integrated search bar to quickly jump to desired locations.
- **Joystick Navigation**: smoothly move around the map using keyboard arrow keys (with adjustable speed in Single Point mode).

You can download compiled and signed app [here](https://skywalker-howardhoward.netlify.app/).

![App Screen Shot](https://raw.githubusercontent.com/nexron171/SimVirtualLocation/master/assets/screenshot.png)

## Usage Methods

### Basic Usage
1. Connect your device (iOS Simulator, iOS Device, or Android Device).
2. Select the target device from the device dropdown list.
3. Choose the mode (Single Point or Route).
4. Click on the map to place markers.
5. Click `Start` to begin mocking the location.
6. Click `Stop` to stop mocking.

### Keyboard Shortcuts & Joystick Navigation
The application features several global keyboard shortcuts for a seamless experience:
- **Joystick Navigation**: In **Single Point** mode, use the **Arrow Keys** (Up, Down, Left, Right) to smoothly move your location around the map like a joystick.
  - **Speed Adjustments**: Use the `Speed` slider to increase or decrease the distance the joystick moves per frame.
  - **Safe Execution**: The actual location on your physical device is only updated *after* you release the arrow keys (to prevent timeout crashes), and *only if* the device is successfully connected and started. If you haven't clicked `Start` yet, the joystick will only move the Point A marker on the map.
- **Escape (`Esc`)**: Instantly unfocus the Search bar so you can quickly return to using the Joystick without accidentally typing into the search field.
- **Debug Mode (`d`)**: Press the `d` key to quickly toggle the debug panel.

### For iOS Devices
**Option 1: Automated Setup (Recommended)**
```shell
./scripts/setup.sh
```

**Option 2: Manual Installation**
```shell
brew install python3 && python3 -m pip install -U pymobiledevice3
```

After installation:
- For iOS Device - select device from dropdown and then click on Mount Developer Image.
- If you see an error that there is no appropriate image - download one from [Xcode_Developer_Disk_Images](https://github.com/mspvirajpatel/Xcode_Developer_Disk_Images/releases).
- If your iOS version is (for example) 16.5.1 and there is only 16.5 - it's ok, just copy and rename it to 16.5.1 and put it inside Xcode at `.../Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport/`.

**For iOS 17+ devices:**
Select checkbox "iOS 17+" and provide RSD Address and RSD Port from command:
```shell
sudo pymobiledevice3 remote start-tunnel
```
This needs `sudo` because it will instantiate a low level connection between Mac and iPhone. Keep this command running while mocking location for iOS 17+.

### For Android Devices
1. Check if debugging over USB is enabled.
2. Specify ADB path (for example `/User/dev/android/tools/adb`).
3. Specify your device id (type `adb devices` in the terminal to see id).
4. Setup helper app by clicking `Install Helper App` and open it on the phone.
5. Grant permission to mock location - go to Developer settings and find `Application for mocking locations` or something similar and choose SimVirtualLocation.
6. Keep SimVirtualLocation running in background while mocking.

## Quick Setup

### Automated Installation (Recommended)
Run the setup script to automatically install all required dependencies:

```bash
./scripts/setup.sh
```

This will install:
- Xcode Command Line Tools
- uv (modern Python package manager)
- pymobiledevice3 latest version (for iOS device support, installed via `uv tool install`)

### Check Your Environment
To verify all dependencies are installed correctly:

```bash
./scripts/check-env.sh
```

## Development
This project supports both **Xcode** and **Swift Package Manager**:

### Using Xcode (Recommended for App Development)
```bash
open SimVirtualLocation.xcodeproj
```

### Using Swift Package Manager
```bash
# Open with any IDE that supports Swift Package
open Package.swift

# Or build from command line
swift build
swift test
```

For detailed Swift Package configuration, see [SWIFT_PACKAGE_SETUP.md](./SWIFT_PACKAGE_SETUP.md).

## FAQ

### How to run
If you see an alert with a warning that the app is corrupted and Apple cannot check the developer: try to press and hold `ctrl`, then click on SimVirtualLocation.app and select "Open", release `ctrl`. Now the alert should have the "Open" button. Don't forget to copy the app from the dmg image to any place on your Mac.

### If iOS device is unlisted
Try to refresh the list and if it does not help - go to Settings / Developer on iPhone and click Clear trusted computers. Replug cable and press refresh. If it still is not in the list - go to Xcode / Devices and simulators and check your device, there should not be any yellow messages. If it has - do all that it requires.

### Can't find the 'Developer Mode' option on iPhone?
If you can't find the 'Developer Mode' toggle in 'Settings > Privacy & Security', this is normal. Apple hides this option by default for security reasons.

**Solution Steps:**
1. **Connect to Computer**: Connect your iPhone to a Mac with Xcode installed using a cable.
2. **Trust Computer**: Tap 'Trust This Computer' on your phone and enter your passcode.
3. **Enable App**: Select your device in this app and click **'Connect'** (or **'Mount Developer Image'**).
4. **Check Again**: After completing the steps above, the 'Developer Mode' toggle will automatically appear at the bottom of 'Settings > Privacy & Security'.
5. **Enable and Restart**: After turning on the toggle, the phone will ask to restart. Once the restart is complete, verify that it is turned on.

## Contributors

<!-- readme: collaborators,contributors -start -->
<table>
    <tr>
        <td align="center">
            <a href="https://github.com/nexron171">
                <img src="https://avatars.githubusercontent.com/u/6318346?v=4" width="100;" alt="nexron171"/>
                <br />
                <sub><b>Sergey Shirnin</b></sub>
            </a>
        </td>
        <td align="center">
            <a href="https://github.com/sk-chanch">
                <img src="https://avatars.githubusercontent.com/u/22313319?v=4" width="100;" alt="sk-chanch"/>
                <br />
                <sub><b>Skipp</b></sub>
            </a>
        </td>
        <td align="center">
            <a href="https://github.com/styresdc">
                <img src="https://avatars.githubusercontent.com/u/10870930?v=4" width="100;" alt="styresdc"/>
                <br />
                <sub><b>styresdc</b></sub>
            </a>
        </td>
        <td align="center">
            <a href="https://github.com/how123480">
                <img src="https://avatars.githubusercontent.com/how123480" width="100;" alt="how123480"/>
                <br />
                <sub><b>howard</b></sub>
            </a>
        </td>
    </tr>
</table>
<!-- readme: collaborators,contributors -end -->
