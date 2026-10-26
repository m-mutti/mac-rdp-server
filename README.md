# mac-rdp-connect

Use a Windows PC as a terminal for your Mac. mac-rdp-connect is an RDP server for macOS:
connect from Windows with the built-in **Remote Desktop Connection** (`mstsc`), and
the Mac takes on the Windows PC's monitors and devices as if they were plugged in locally.
Nothing needs installing on Windows.

## How it fits together

```
 Windows (mstsc)                                Mac (mac-rdp-connect)
 ───────────────                                ──────────────────────
 monitor layout  ── MCS / Display Control ───▶  one CGVirtualDisplay per monitor,
                                                 same sizes, positions and DPI
 H.264 decoder   ◀─ Graphics Pipeline AVC420 ─  ScreenCaptureKit ▶ VideoToolbox (HW)
 keyboard/mouse  ── fast-path input ─────────▶  CGEvent injection, PC→Mac key map
 devices         ◀─ virtual channels ────────▶  virtual Mac devices (table below)
```

The protocol layer is [FreeRDP](https://github.com/FreeRDP/FreeRDP)'s server library
(Apache-2.0); everything macOS-specific lives in `Sources/MacRDPConnectKit`.

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

Open **mac-rdp-connect.app** (from the release DMG, or `./scripts/run.sh` after building).
It lives in the menu bar; the first launch walks through setup:

1. **Permissions:** Screen Recording (Windows sees the screen) and Accessibility (Windows'
   keyboard and mouse control the Mac), each with live status and a button to open the right
   System Settings pane. macOS applies Screen Recording after a restart, which the app offers.
2. **Sign-in:** the user name and password Windows signs in with, separate from your Mac login.
3. **Connect:** the addresses to use from Windows (local network and Tailscale), and a ready-made
   `.rdp` file to copy to the PC.

The menu bar panel shows whether Windows is connected, any permission or connection problem,
the addresses to connect to, and Start/Stop, Disconnect, Settings and the log. **Settings** has:

| Tab | What it does |
|---|---|
| Sign-in | Shows the user name and password (reveal, copy, generate) and changes them |
| Permissions | The same live checks as setup |
| Connection | Server status, port, addresses, `.rdp` file |
| Display & Keyboard | Windows key or Ctrl as ⌘, scaling, mirroring the Mac's screen, compatibility video |

The password is stored as an NT hash for sign-in and, so Settings can show it, in your login
Keychain. On Windows, open Remote Desktop Connection, enter the Mac's address, tick
*Display › Use all my monitors*, and sign in. The log is `~/Library/Logs/mac-rdp-connect.log`;
every 5 seconds it reports frames sent versus frames acknowledged by Windows.

Until the app is signed with a developer certificate, every rebuild makes macOS forget its
permissions and ask again before it reads the Keychain.

The same binary also works headless: `mac-rdp-connect serve`, `set-password`, `rdp-file`,
`doctor` (run it with no command for the app).

## Building

Requires only the Xcode Command Line Tools.

```sh
./scripts/bootstrap.sh   # one-time: CMake, OpenSSL, FreeRDP into third_party/ (no admin)
swift build
./scripts/test.sh
```

Diagnostics:

```sh
.build/debug/mac-rdp-connect doctor
.build/debug/mac-rdp-connect displays --layout 2560x1440@125,1920x1080 --seconds 10
```
