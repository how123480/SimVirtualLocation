# SimVirtualLocation

Easy to use MacOS 11+ application for easy mocking iOS device and simulator location in realtime. Built on top of  [set-simulator-location](https://github.com/MobileNativeFoundation/set-simulator-location) for iOS Simulators and [pymobiledevice3](https://github.com/doronz88/pymobiledevice3). Android support is realized with [SimVirtualLocation](https://github.com/nexron171/android-mock-location-for-development) android app which is fork from [android-mock-location-for-development](https://github.com/amotzte/android-mock-location-for-development).

Posibilities:
- supports both iOS and Android
- set location to current Mac's location
- set location to point on map
- make route between two points and simulate moving with desired speed

You can dowload compiled and signed app [here](https://github.com/nexron171/SimVirtualLocation/releases).

![App Screen Shot](https://raw.githubusercontent.com/nexron171/SimVirtualLocation/master/assets/screenshot.png)

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

For detailed Swift Package configuration, see [SWIFT_PACKAGE_SETUP.md](./SWIFT_PACKAGE_SETUP.md)

### Using Non-Xcode Editors (VS Code, Neovim, etc.)

If you develop with editors other than Xcode, you need `buildServer.json` to enable **LSP (Language Server Protocol)** features such as code completion, jump-to-definition, and inline diagnostics.

This file is the configuration for [xcode-build-server](https://github.com/SolaWing/xcode-build-server), which bridges **SourceKit-LSP** with Xcode's build system via **BSP (Build Server Protocol)**.

#### Why is it needed?

SourceKit-LSP relies on the **index store** that Xcode generates inside `DerivedData/` during compilation. The `buildServer.json` tells SourceKit-LSP where to find that index store through the `build_root` field. Without it, your editor cannot resolve types or navigate symbols.

**Key fields that affect LSP indexing:**

| Field | Purpose |
|---|---|
| `build_root` | Points to the DerivedData path. LSP reads the index store from here. **Most critical field.** |
| `workspace` | Points to the `.xcworkspace`, used to resolve project structure and targets. |
| `scheme` | Determines which scheme's build configuration and targets are used for indexing. |

> **Important:** You must **build the project in Xcode at least once** before LSP can work. The index store is only generated during compilation. After a clean build or DerivedData reset, build again in Xcode to restore LSP functionality.

#### How to Generate

1. Install xcode-build-server:
   ```bash
   brew install xcode-build-server
   ```

2. Generate `buildServer.json` in the project root:
   ```bash
   xcode-build-server config -project SimVirtualLocation.xcodeproj -scheme SimVirtualLocation
   ```

3. (Optional) If using a workspace instead of a project:
   ```bash
   xcode-build-server config -workspace SimVirtualLocation.xcworkspace -scheme SimVirtualLocation
   ```

#### When to Regenerate

- After DerivedData is cleaned or its hash path changes
- After switching Xcode versions
- After running `xcodebuild clean`

> **Note:** `buildServer.json` is gitignored because it contains machine-specific absolute paths. Each developer must generate it locally.

## FAQ
---
### How to run
If you see an alert with warning that app is corrupted and Apple can not check the developer: try to press and hold `ctrl`, then click on SimVirtualLocation.app and select "Open", release `ctrl`. Now alert should have the "Open" button. Don't forget to copy app from dmg image to any place on your Mac.

### For iOS devices
**Option 1: Automated Setup (Recommended)**
```shell
./setup.sh
```

**Option 2: Manual Installation**
```shell
brew install python3 && python3 -m pip install -U pymobiledevice3
```

After installation:
- For iOS Device - select device from dropdown and then click on Mount Developer Image
- If you see an error that there is no appropriate image - download one from https://github.com/mspvirajpatel/Xcode_Developer_Disk_Images/releases
- If your iOS version is (for example) 16.5.1 and there is only 16.5 - it's ok, just copy and rename it to 16.5.1 and put it inside Xcode at `.../Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport/`

**For iOS 17+ devices:**
Select checkbox "iOS 17+" and provide RSD Address and RSD Port from command:
```shell
sudo pymobiledevice3 remote start-tunnel
```
This needs sudo because it will instantiate a low level connection between Mac and iPhone. Keep this command running while mocking location for iOS 17+.

### If iOS device is unlisted

Try to refresh list and if it does not help - go to Settings / Developer on iPhone and click Clear trusted computers. Replug cable and press refresh. If it still not in list - go to Xcode / Devices and simulators and check your device, there are should not be any yellow messages. If it has - make all that it requires.

---
### For Android
1. Check if debugging over USB is enabled
1. Specify ADB path (for example `/User/dev/android/tools/adb`)
1. Specify your device id (type `adb devices` in the terminal to see id)
1. Setup helper app by clicking `Install Helper App` and open it on the phone
1. Grant permission to mock location - go to Developer settings and find `Application for mocking locations` or something similar and choose SimVirtualLocation
1. Keep SimVirtualLocation running in background while mocking

### Contributors

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
    </tr>
</table>
<!-- readme: collaborators,contributors -end -->
