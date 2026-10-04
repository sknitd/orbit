import Foundation
import NotchCore

enum CommandHelpers {
    static let notifyScript = """
    #!/usr/bin/env python3
    import argparse, json, os, socket, stat, sys, time, uuid
    p = argparse.ArgumentParser(description="Send local Orbit activity metadata; no command is executed.")
    p.add_argument("kind", choices=("start", "finish"))
    p.add_argument("--id", required=True); p.add_argument("--label", required=True)
    p.add_argument("--exit-code", type=int); p.add_argument("--duration", type=float)
    a = p.parse_args(); activity_id = str(uuid.UUID(a.id))
    if not a.label.strip() or len(a.label.encode()) > 160 or any(ord(c) < 32 or ord(c) == 127 for c in a.label): p.error("label must be short, nonempty metadata")
    message = dict(version=1, kind=a.kind, id=activity_id, label=a.label, at=time.time())
    if a.kind == "finish":
        if a.exit_code is None or a.duration is None or not -255 <= a.exit_code <= 255 or not 0 <= a.duration <= 604800: p.error("finish needs a valid exit code and measured duration")
        message.update(exitCode=a.exit_code, duration=a.duration)
    elif a.exit_code is not None or a.duration is not None: p.error("start cannot contain an exit result")
    root = "/tmp/notchorbitplus-%d" % os.getuid(); endpoint = root + "/activities.sock"
    try:
        d = os.stat(root, follow_symlinks=False); s = os.stat(endpoint, follow_symlinks=False)
        if d.st_uid != os.getuid() or s.st_uid != os.getuid() or not stat.S_ISDIR(d.st_mode) or not stat.S_ISSOCK(s.st_mode) or stat.S_IMODE(d.st_mode) != 0o700 or stat.S_IMODE(s.st_mode) != 0o600: raise OSError("listener ownership or permissions are invalid")
        data = json.dumps(message, allow_nan=False).encode()
        if len(data) > 4096: raise OSError("activity metadata exceeds 4096 bytes")
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client: client.sendto(data, endpoint)
    except (OSError, ValueError) as error:
        print("orbit-notify: " + str(error), file=sys.stderr); sys.exit(1)
    """
    static let runScript = """
    #!/usr/bin/env python3
    import argparse, os, subprocess, sys, time, uuid
    p = argparse.ArgumentParser(description="Run your explicitly supplied local command and report its measured activity.")
    p.add_argument("--label", default=None); p.add_argument("command", nargs=argparse.REMAINDER)
    a = p.parse_args(); command = a.command
    if command and command[0] == "--": command = command[1:]
    if not command: p.error("supply a command after --")
    label = a.label or os.path.basename(command[0])
    if not label.strip() or len(label.encode()) > 160 or any(ord(c) < 32 or ord(c) == 127 for c in label): p.error("use a short nonempty label")
    notifier = os.path.join(os.path.dirname(os.path.realpath(__file__)), "orbit-notify")
    activity_id = str(uuid.uuid4())
    def notify(kind, *extra):
        try: subprocess.run([sys.executable, notifier, kind, "--id", activity_id, "--label", label, *extra], check=False)
        except OSError as error: print("orbit-run notification: " + str(error), file=sys.stderr)
    notify("start")
    started = time.monotonic()
    try: code = subprocess.run(command, shell=False).returncode
    except KeyboardInterrupt: code = 130
    except OSError as error: print("orbit-run: " + str(error), file=sys.stderr); code = 127
    notify("finish", "--exit-code", str(code), "--duration", str(time.monotonic() - started))
    sys.exit(code if code >= 0 else 128 - code)
    """
    static func install(in directory: URL, resources: URL? = nil) throws {
        guard let resources = resources ?? Bundle.main.url(forResource: "CommandHelpers", withExtension: nil) else {
            throw CommandActivityError.invalid("The app's CommandHelpers resources are missing. Reinstall a verified app build.")
        }
        var scripts: [(String, Data)] = []
        for (name, expected) in [("orbit-notify", notifyScript), ("orbit-run", runScript)] {
            let resource = resources.appendingPathComponent(name)
            let values = try resource.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 32_768 else {
                throw CommandActivityError.invalid("A bundled command helper is missing or invalid.")
            }
            let bytes = try Data(contentsOf: resource)
            guard bytes == Data((expected + "\n").utf8) else { throw CommandActivityError.invalid("A bundled command helper differs from this app version; no helper was installed.") }
            scripts.append((name, bytes))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CommandActivityError.invalid("The helper directory must be an ordinary owned directory.") }
        for (name, bytes) in scripts {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                let original = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard original.isRegularFile == true, original.isSymbolicLink != true else { throw CommandActivityError.invalid("A nonregular file occupies \(name); no helper was replaced.") }
                if try Data(contentsOf: url) != bytes { try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent("\(name).\(UUID().uuidString).backup")) }
            }
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
