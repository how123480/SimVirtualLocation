//
//  LocationHelperScript.swift
//  SimVirtualLocation
//
//  Embedded source of the persistent location helper plus interpreter
//  discovery. The script is written to Application Support at runtime so the
//  gitignored project.pbxproj never needs a new resource entry, and the
//  script always matches the app version.
//

import Foundation

enum LocationHelperScript {

    /// Python source. Protocol: line-delimited JSON on stdin/stdout, strictly
    /// one response per request; `{"ok":true,"ready":true}` once the DVT
    /// connection is up. stdin EOF = clean exit; the async context managers
    /// then clear the simulated location, so a dead helper naturally restores
    /// the device's real location.
    /// Exit codes: 0 clean, 2 no tunnel for udid, 3 unsupported
    /// pymobiledevice3 (import layout differs), 4 runtime error.
    static let source = #"""
import asyncio
import json
import sys


def out(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


try:
    from pymobiledevice3.tunneld.api import get_tunneld_device_by_udid, get_tunneld_devices
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
except ImportError as exc:
    out({"ok": False, "fatal": True, "error": "unsupported pymobiledevice3: %s" % exc})
    sys.exit(3)


async def serve(loc):
    reader = asyncio.StreamReader()
    loop = asyncio.get_running_loop()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    out({"ok": True, "ready": True})
    while True:
        line = await reader.readline()
        if not line:
            return
        try:
            msg = json.loads(line)
        except ValueError:
            out({"ok": False, "error": "bad json"})
            continue
        cmd = msg.get("cmd")
        try:
            if cmd == "set":
                await loc.set(float(msg["lat"]), float(msg["lng"]))
                out({"ok": True, "cmd": "set"})
            elif cmd == "clear":
                await loc.clear()
                out({"ok": True, "cmd": "clear"})
            elif cmd == "ping":
                out({"ok": True, "cmd": "ping"})
            elif cmd == "quit":
                out({"ok": True, "cmd": "quit"})
                return
            else:
                out({"ok": False, "error": "unknown cmd: %r" % cmd})
        except Exception as exc:
            out({"ok": False, "error": str(exc)})


async def main(udid):
    rsd = await get_tunneld_device_by_udid(udid)
    if rsd is None:
        # tunneld's JSON keys can differ in case from usbmux UDIDs; retry
        # case-insensitively and close the connections we don't keep.
        for candidate in await get_tunneld_devices():
            if rsd is None and getattr(candidate, "udid", "").lower() == udid.lower():
                rsd = candidate
            else:
                try:
                    await candidate.close()
                except Exception:
                    pass
    if rsd is None:
        out({"ok": False, "fatal": True, "error": "no tunnel for device"})
        return 2
    try:
        # NOTE: iOS drops the simulated location when this DTX connection dies —
        # the app's "dead helper restores real location" safety net relies on it.
        async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as loc:
            await serve(loc)
    finally:
        try:
            await rsd.close()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        out({"ok": False, "fatal": True, "error": "usage: location-helper.py <udid>"})
        sys.exit(4)
    try:
        sys.exit(asyncio.run(main(sys.argv[1])) or 0)
    except Exception as exc:
        out({"ok": False, "fatal": True, "error": str(exc)})
        sys.exit(4)
"""#

    /// Writes the helper script into
    /// ~/Library/Application Support/SimVirtualLocation/ and returns its URL.
    static func materialize() throws -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = base.appendingPathComponent("SimVirtualLocation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("location-helper.py")
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Resolves the Python interpreter of the installed pymobiledevice3 by
    /// reading its shebang (uv / pipx installs point the console script at
    /// their venv's python). Returns nil when the file has no usable shebang
    /// — callers treat that as "helper unsupported" and fall back to the CLI.
    static func findInterpreter(pymobiledevice3Path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: pymobiledevice3Path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256),
              let head = String(data: data, encoding: .utf8),
              head.hasPrefix("#!") else { return nil }
        let firstLine = head.components(separatedBy: .newlines)[0]
        let interpreter = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !interpreter.isEmpty,
              FileManager.default.isExecutableFile(atPath: interpreter) else { return nil }
        return interpreter
    }
}
