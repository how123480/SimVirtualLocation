# Swift Package Setup

This project supports being built and run as a Swift Package.

## Requirements
- macOS 13.0+
- Swift 5.9+

## Building and Running

You can open `Package.swift` in Xcode or any other IDE that supports Swift Package Manager.

### Command Line
To build the project from the command line:
```bash
swift build
```

To run the application:
```bash
swift run SimVirtualLocation
```

To run the tests:
```bash
swift test
```

## Structure
The `Package.swift` file defines the following targets:
- `SimVirtualLocation`: The main executable target containing the views, models, and logic.
- `SimVirtualLocationTests`: The test target for the application.
