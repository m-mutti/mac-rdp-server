# OpenConnect

Use a Windows PC as a terminal for your Mac. OpenConnect is an RDP server for macOS:
connect from Windows with the built-in **Remote Desktop Connection** (`mstsc`), and
the Mac takes on the Windows PC's monitors and devices as if they were plugged in locally.
Nothing needs installing on Windows.

## How it fits together

```
 Windows (mstsc)                                Mac (openconnect-host)
 ───────────────                                ──────────────────────
 monitor layout  ── MCS / Display Control ───▶  one CGVirtualDisplay per monitor,
                                                 same sizes, positions and DPI
 H.264 decoder   ◀─ Graphics Pipeline AVC420 ─  ScreenCaptureKit ▶ VideoToolbox (HW)
 keyboard/mouse  ── fast-path input ─────────▶  CGEvent injection, PC→Mac key map
 devices         ◀─ virtual channels ────────▶  virtual Mac devices (table below)
```

The protocol layer is [FreeRDP](https://github.com/FreeRDP/FreeRDP)'s server library
(Apache-2.0); everything macOS-specific lives in `Sources/OpenConnectKit`.

## Devices

| Windows device | RDP channel | Appears on the Mac as | Requires |
|---|---|---|---|
| Monitors (any count, mixed DPI) | Monitor layout, Display Control (MS-RDPEDISP), Graphics Pipeline (MS-RDPEGFX) | Virtual displays | Screen Recording permission |
| Keyboard, mouse | Fast-path input | Native input events | Accessibility permission |
| Speakers / headset | Audio output (MS-RDPEA) | "Windows Speakers" output device | One-time admin install of an audio driver (HAL plug-in) |
| Microphone | Audio input (MS-RDPEAI) | "Windows Microphone" input device | Same driver |
| Clipboard: text, images, files | MS-RDPECLIP | Mac pasteboard | — |
| Drives / folders | File system redirection (MS-RDPEFS) | Volume in Finder | — |
| Security key: FIDO2, passkeys, Windows Hello | WebAuthn redirection (MS-RDPEWA, Windows 11) | USB security key (virtual FIDO HID) | Apple Developer account with the `com.apple.developer.hid.virtual.device` entitlement |
| Security key: PIV / smart card | Smart card redirection (MS-RDPESC) | Smart card reader | One-time admin install of a reader driver |
| Webcam | Video capture redirection (MS-RDPECAM, Windows 11) | Camera | Developer ID signing (camera extension) |
| Arbitrary USB devices | RemoteFX USB (MS-RDPEUSB) | — | **Not planned:** needs a kernel extension and Reduced Security boot on Apple silicon |

## Status

**Working (verified on macOS 26.3 / M4):**
- RDP server on FreeRDP 3.32: NLA sign-in only (no TLS-only or legacy RDP security),
  self-signed certificate, one client at a time.
- One virtual display per Windows monitor, with the same size, position and scaling
  (a 4K monitor at 150% "looks like" 2560×1440, like a Retina Mac). Physical screens mirror
  the primary so no window lands where you can't see it. Everything reverts on disconnect.
- One hardware H.264 stream per monitor over the graphics pipeline (AVC420), with flow
  control on frame acknowledgements so latency doesn't build up.
- Keyboard (Win key = Command by default), mouse, wheel, back/forward buttons, Unicode text,
  and a locally drawn cursor that matches the Mac's cursor shape.
- Live re-layout when the client resizes or changes monitors (display control channel).

**Next:** clipboard, then the audio driver for speakers and microphone, smart cards and drives;
then signed builds for the FIDO security key and webcam, a menu bar app, and launch at login.

## Using it

On the Mac:

```sh
./scripts/bootstrap.sh                                         # one-time toolchain build
./scripts/bundle.sh                                            # builds build/OpenConnect.app
build/OpenConnect.app/Contents/MacOS/openconnect-host set-password
./scripts/run.sh                                               # starts the server, follows the log
```

The first start asks for **Screen Recording** and **Accessibility** for OpenConnect; allow both,
then start it again. Until the app is signed with a developer certificate, every rebuild makes
macOS forget these permissions.

On Windows, either double-click the file from `openconnect-host rdp-file`, or open
Remote Desktop Connection, enter the Mac's address, tick *Display › Use all my monitors*,
and sign in with your Mac user name and the OpenConnect password.

Options for `serve` / `run.sh`: `--keys windowsShortcuts` (Ctrl acts as Command),
`--physical extend`, `--scaling native`, `--h264 baseline` (if Windows connects but stays black).
The log is `~/Library/Logs/OpenConnect.log`; every 5 seconds it reports frames sent versus
frames acknowledged by Windows.

## Building

Requires only the Xcode Command Line Tools.

```sh
./scripts/bootstrap.sh   # one-time: CMake, OpenSSL, FreeRDP into third_party/ (no admin)
swift build
./scripts/test.sh
```

Diagnostics:

```sh
.build/debug/openconnect-host doctor
.build/debug/openconnect-host displays --layout 2560x1440@125,1920x1080 --seconds 10
```
