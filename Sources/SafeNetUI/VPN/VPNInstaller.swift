import Foundation
import SafeNetCore

/// Installs / removes the root helper. macOS asks the user for an administrator password in its own
/// dialog (`do shell script … with administrator privileges`); SafeNet never sees the password.
public enum VPNInstaller {
    /// What gets installed: this app's executable and a verified sing-box (`SingBoxRelease`).
    public struct Sources: Equatable {
        public var executable: String
        public var singBoxDir: String
    }

    /// This build's executable (nil outside an .app: a dev build cannot install the helper).
    public static func appExecutable(bundle: Bundle = .main) -> String? {
        guard bundle.bundleIdentifier != nil else { return nil }
        return bundle.executableURL?.path
    }

    /// sing-box version this build installs.
    public static func bundledSingBoxVersion(bundle: Bundle = .main) -> String? { SingBoxRelease.version }

    /// The installed helper answers and matches this build (protocol and sing-box version).
    public static func isCurrent(_ s: VPNHelperStatus, bundledSingBox: String?) -> Bool {
        s.protocolVersion == VPNHelperVersion.protocolVersion && (bundledSingBox == nil || s.singBoxVersion == bundledSingBox)
    }

    static func launchdPlist(uid: uid_t) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(VPNHelperPaths.label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(VPNHelperPaths.helperBinary)</string>
            <string>--vpn-helper</string>
            <string>\(uid)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>StandardErrorPath</key><string>/Library/Logs/SafeNet/vpn-helper.log</string>
        </dict>
        </plist>
        """
    }

    /// Single-quoted for /bin/sh.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Shell script run as root. Copies (never links) into root-owned locations, so later changes
    /// to the app bundle cannot alter what runs as root.
    public static func installScript(_ src: Sources, uid: uid_t) -> String {
        let d = VPNHelperPaths.installDir
        let plist = launchdPlist(uid: uid)
        return """
        set -e
        /bin/launchctl bootout system/\(VPNHelperPaths.label) 2>/dev/null || true
        /bin/rm -rf \(q(d))
        /bin/mkdir -p \(q(d)) /Library/Logs/SafeNet
        /bin/cp \(q(src.executable)) \(q(VPNHelperPaths.helperBinary))
        /bin/cp \(q(src.singBoxDir + "/sing-box")) \(q(src.singBoxDir + "/LICENSE")) \(q(src.singBoxDir + "/VERSION")) \(q(d))/
        /usr/sbin/chown -R root:wheel \(q(d))
        /bin/chmod 755 \(q(d)) \(q(VPNHelperPaths.helperBinary)) \(q(VPNHelperPaths.singBox))
        /bin/chmod 644 \(q(d + "/LICENSE")) \(q(d + "/VERSION"))
        /bin/cat > \(q(VPNHelperPaths.plist)) <<'SAFENET_PLIST'
        \(plist)
        SAFENET_PLIST
        /usr/sbin/chown root:wheel \(q(VPNHelperPaths.plist))
        /bin/chmod 644 \(q(VPNHelperPaths.plist))
        /bin/launchctl bootstrap system \(q(VPNHelperPaths.plist))
        """
    }

    public static func uninstallScript() -> String {
        """
        /bin/launchctl bootout system/\(VPNHelperPaths.label) 2>/dev/null || true
        /bin/rm -f \(q(VPNHelperPaths.plist)) \(q(VPNHelperPaths.socket))
        /bin/rm -rf \(q(VPNHelperPaths.installDir)) \(q(VPNHelperPaths.workDir))
        """
    }

    /// AppleScript string literal.
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs `script` as root after macOS's password dialog. Blocking: call off the main thread.
    /// nil = done; else the error ("отменено" when the user cancelled).
    public static func runAsAdmin(_ script: String, prompt: String) -> String? {
        let apple = "do shell script \(appleScriptString(script)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return "osascript не запустился: \(error.localizedDescription)" }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if msg.contains("-128") { return "отменено" }
        return msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ошибка \(p.terminationStatus)" : String(msg.prefix(300))
    }

    /// Downloads sing-box if needed (blocking), then installs the helper (password dialog).
    public static func install(cacheDir: URL) -> String? {
        guard let exe = appExecutable() else { return "помощник ставится только из SafeNet.app (не из разработческой сборки)" }
        let dir: URL
        switch SingBoxRelease.ensure(in: cacheDir) {
        case .success(let d): dir = d
        case .failure(let e): return e.description
        }
        let src = Sources(executable: exe, singBoxDir: dir.path)
        return runAsAdmin(installScript(src, uid: getuid()),
                          prompt: "SafeNet устанавливает системный помощник VPN (создаёт туннель и не выпускает трафик мимо VPN).")
    }

    public static func uninstall() -> String? {
        runAsAdmin(uninstallScript(), prompt: "SafeNet удаляет системный помощник VPN.")
    }
}
