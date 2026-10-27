# mac-rdp-server

**An RDP server for your Mac.** Connect from any Windows PC with the Remote Desktop Connection
app that's already built into Windows, and use your Mac across all of your Windows monitors, with
the keyboard, mouse and other peripherals plugged into the PC.

```
  Windows PC                                  Mac
  ┌───────────────────────────┐               ┌───────────────────────────┐
  │ Remote Desktop Connection │    picture    │ mac-rdp-server            │
  │ (built into Windows)      │ ◀──────────── │                           │
  │                           │               │                           │
  │ monitor 1    monitor 2    │   keyboard,   │ display 1    display 2    │
  │                           │   mouse and   │                           │
  │                           │  peripherals  │                           │
  │                           │ ────────────▶ │                           │
  └───────────────────────────┘               └───────────────────────────┘
```

## Advantages

- **Nothing to install on Windows.** It works with Windows' own Remote Desktop Connection.
- **Multiple displays.** Every Windows monitor becomes a real Mac display with the same
  resolution, arrangement and scaling. A monitor at 125% on Windows is Retina-sharp on the Mac.
  It works even if the Mac itself has a single screen.
- **Your peripherals, connected to the Mac.** The keyboard and mouse on the PC work as if they
  were plugged into the Mac, and more peripherals are being added (see [Peripherals](#peripherals)).
- **Smooth and sharp.** Hardware H.264 encoding on Apple silicon, frame pacing that keeps latency
  low, and a cursor drawn on Windows so it never lags.
- **Secure.** Windows must prove the password before anything is shown (Network Level
  Authentication), over a connection encrypted with the Mac's own certificate.
- **Simple.** A menu bar app with guided setup: permissions, password, and the address to
  connect to.

## Requirements

- A Mac with Apple silicon, running macOS 14 or later.
- A Windows 10 or 11 PC with Remote Desktop Connection.
- Both on the same network, or connected through a VPN such as Tailscale.

## Install

1. Download the `.dmg` from [Releases](../../releases), open it, and drag **mac-rdp-server**
   into **Applications**.
2. The app isn't notarized by Apple yet, so clear the download quarantine in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/mac-rdp-server.app
   ```
3. Open **mac-rdp-server**. Setup walks you through:
   - **Permissions:** *Screen Recording* lets Windows see the Mac's screen, and *Accessibility*
     lets the Windows keyboard and mouse control it.
   - **Sign-in:** the user name and password Windows signs in with. This is separate from your
     Mac login password.
   - **Connect:** the address to use from Windows.

From then on mac-rdp-server lives in the menu bar, and its server runs whenever the app is open.

## Connect from Windows

1. Open **Remote Desktop Connection** (search for "Remote Desktop" in the Start menu).
2. Enter the Mac's address, shown in the mac-rdp-server menu.
3. Click **Show Options › Display** and tick **Use all my monitors**.
4. Click **Connect**, sign in with the user name and password from setup, and accept the
   certificate prompt the first time.

Every monitor fills with the Mac. While you're connected, the Mac's own screen is turned off, as
a PC's is when you use it over Remote Desktop. To finish, close the Remote Desktop window; the
Mac's screen stays asleep. **Save Remote Desktop File…** in the app creates a ready-made
`.rdp` file you can copy to the PC and double-click instead.

## Peripherals

| Peripheral | Status |
|---|---|
| Monitors: any number, mixed resolutions and scaling | ✅ Works |
| Keyboard and mouse, including the scroll wheel, back/forward buttons and typed text from any language | ✅ Works |
| Security keys and Windows Hello (FIDO2, passkeys) | 🚧 Built in. Mac apps can use them once Apple approves this app's virtual-device permission (macOS 15 or later) |
| Clipboard: text, formatted text and images, both ways | ✅ Built in |
| Clipboard: files | Planned |
| Speakers and headset | Planned |
| Microphone | Planned |
| Drives and folders | Planned |
| Webcam | Planned |
| Other USB devices | Not planned: macOS allows this only with a kernel extension |

## Settings

The menu bar panel shows whether Windows is connected, the addresses to connect to, and any
problem that needs attention. **Settings** has four tabs:

| Tab | What it's for |
|---|---|
| Sign-in | See the user name and password (show, copy, generate) and change them |
| Permissions | Check Screen Recording, Accessibility and clipboard access, and fix them |
| Connection | Start or stop the server, change the port, save a `.rdp` file |
| Display & Keyboard | Windows key or Ctrl as ⌘, scaling, whether the Mac's own screen turns off, mirrors Windows or stays as extra space |

## Troubleshooting

- **Windows connects but stays black:** turn on *Compatibility video* in Settings › Display &
  Keyboard.
- **Keyboard and mouse do nothing:** check Settings › Permissions. After installing a new
  version, macOS can show Accessibility as allowed while ignoring it. Remove mac-rdp-server from
  the list in System Settings with **−**, then allow it again.
- **Can't connect:** check the address in the menu, and that the Mac is awake and logged in.
  The server uses TCP port 3389.
- **Copy and paste doesn't cross over:** in Remote Desktop Connection, open **Show Options ›
  Local Resources** and tick **Clipboard**. Other clipboard-sharing apps can get in the way.
- **macOS asks before Windows can paste:** macOS 15.4 and later can ask each time another app
  reads the clipboard. In Settings › Permissions, set Clipboard to *Always Allow*.
- **Security keys aren't offered:** in Remote Desktop Connection, open **Show Options › Local
  Resources › More…** and tick **WebAuthn (Windows Hello or security keys)**.
- **Logs:** menu bar › **Open Log**, or `~/Library/Logs/mac-rdp-server.log`.

## Limitations

- One Windows connection at a time. A new connection takes over: the previous one is
  disconnected and the Mac's displays are rebuilt for the new PC's monitors.
- The Mac must already be logged in; connecting to the login screen isn't supported yet.
- Releases are signed with the project's own certificate but not notarized by Apple, so the
  download needs the quarantine step above. Updates from 0.2.1 on keep the app's permissions;
  updating from an earlier version asks for them once more.

## How it works

mac-rdp-server speaks the Remote Desktop Protocol through [FreeRDP](https://github.com/FreeRDP/FreeRDP)'s
server library. When Windows connects, it reports its monitors, and the Mac creates a virtual
display for each one with the same size, position and scaling. ScreenCaptureKit captures every
display, the Apple silicon media engine encodes it as H.264, and the stream travels over
Remote Desktop's graphics pipeline, one stream per monitor. Keyboard and mouse input comes back
and is replayed as native macOS events. Peripherals use Remote Desktop's own redirection
channels; security keys, for example, arrive through WebAuthn redirection and appear on the Mac
as a USB security key.

## Building from source

Only the Xcode Command Line Tools are needed. The bootstrap script builds CMake, OpenSSL and
FreeRDP into `third_party/` without Homebrew or admin rights.

```sh
./scripts/bootstrap.sh   # one time
./scripts/make-signing-identity.sh   # one time: lets rebuilds keep their permissions
swift build
./scripts/test.sh        # tests
./scripts/bundle.sh      # builds build/mac-rdp-server.app
./scripts/run.sh         # opens the app and follows its log
```

The app's binary also works from the command line: `mac-rdp-server serve` runs the server
without the menu bar app, and `set-password`, `rdp-file` and `doctor` cover setup and checks.

| Path | Contents |
|---|---|
| `Sources/CRDPServer` | C layer over FreeRDP's server: sessions, graphics, display control, WebAuthn, clipboard |
| `Sources/MacRDPKit` | macOS pieces: virtual displays, capture, H.264, input, CBOR/CTAP, clipboard formats |
| `Sources/MacRDPHost` | The server: sessions, streams, cursor, sign-in, security key, clipboard |
| `Sources/MacRDPApp` | The menu bar app: setup, settings, status |
| `Sources/mac-rdp-server` | Entry point and command line |

## Acknowledgements

Built on [FreeRDP](https://github.com/FreeRDP/FreeRDP) and [OpenSSL](https://www.openssl.org),
both under the Apache License 2.0.
