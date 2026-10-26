/// A `.rdp` file that opens Windows Remote Desktop with the right settings.
public enum RemoteDesktopFile {
    public static func contents(address: String, port: UInt16, user: String) -> String {
        let lines = [
            "full address:s:\(address)\(port == 3389 ? "" : ":\(port)")",
            "username:s:\(user)",
            // Full screen across every monitor; each becomes a Mac display.
            "screen mode id:i:2",
            "use multimon:i:1",
            "dynamic resolution:i:1",
            "smart sizing:i:0",
            "session bpp:i:32",
            "connection type:i:7",
            "networkautodetect:i:1",
            "bandwidthautodetect:i:1",
            "displayconnectionbar:i:1",
            // Windows-key shortcuts go to the Mac while full screen.
            "keyboardhook:i:2",
            "redirectclipboard:i:1",
            "redirectwebauthn:i:1",
            "audiomode:i:0",
            "audiocapturemode:i:1",
            "autoreconnection enabled:i:1",
            // The Mac uses a self-signed certificate: Windows asks once.
            "authentication level:i:2",
            "prompt for credentials:i:0",
            "negotiate security layer:i:1",
            "enablecredsspsupport:i:1",
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
