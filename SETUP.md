# SimVirtualLocation - Setup Scripts

## Version Information

These scripts install the following versions:

- **uv**: latest (Python package manager)
- **pymobiledevice3**: latest (installed via `uv tool install`)

## Scripts

### scripts/setup.sh
Automatically installs all required dependencies:
- Xcode Command Line Tools
- uv (Python package manager)
- pymobiledevice3 latest version (via uv tool)

Usage:
```bash
./scripts/setup.sh
```

### scripts/check-env.sh
Checks if all dependencies are correctly installed and shows version information:

Usage:
```bash
./scripts/check-env.sh
```

## What's Checked

1. **Xcode Command Line Tools** - required for compilation
2. **uv** - required for tool management
3. **pymobiledevice3** - iOS device support (installed as uv tool)

## What's NOT Checked

- Homebrew (not required)
- Python (managed automatically by uv)
- Xcode.app (optional)
- ADB (Android Debug Bridge - optional)

## Installation Method

pymobiledevice3 is installed using **`uv tool install`**, which:
- Installs the latest version of pymobiledevice3 globally in `~/.local/bin/pymobiledevice3`
- Creates an isolated environment managed by uv
- Automatically upgrades to the latest version on reinstall
- No need to activate virtual environments

## Notes

- pymobiledevice3 uses the latest available version
- uv will handle Python installation if needed
- The tool is available system-wide after installation
- If `pymobiledevice3` command is not found, add `~/.local/bin` to your PATH:
  ```bash
  export PATH="$HOME/.local/bin:$PATH"
  ```
