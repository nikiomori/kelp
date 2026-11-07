import Core
import Foundation

/// Making an Android machine (`VMService.create` with the android image): an AVD of its own, in its folder, from the newest
/// arm64 system image the user's SDK has (the plain one before Play Store's, which updates Google's services at every
/// boot). Nothing is downloaded.
extension VMService {
    func makeAndroid(_ m: VMMachine) async {
        await making(m) {
            guard let avdmanager = AndroidSDK.avdmanager, let image = AndroidSDK.newestImage() else {
                throw RPCError.invalidParams(
                    "An Android machine runs on your Android SDK (Android Studio): it needs the SDK's "
                        + "command-line tools and an arm64 system image (Android Studio › Settings › Android SDK).")
            }
            step(m, .device, image.split(separator: ";").dropFirst().prefix(2).joined(separator: " "))
            let avd = file(m.name, "avd")
            try Paths.ensure(avd)
            var env = ProcessInfo.processInfo.environment
            env["ANDROID_AVD_HOME"] = avd.path
            if let root = AndroidSDK.root { env["ANDROID_SDK_ROOT"] = root.path }
            // avdmanager is Java: Android Studio's own runtime when none is on PATH (launchd's isn't the shell's).
            let studio = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
            if env["JAVA_HOME"] == nil, FileManager.default.fileExists(atPath: studio) { env["JAVA_HOME"] = studio }
            let made = try await blocking { [env] in
                try Subprocess.run(
                    [
                        avdmanager, "create", "avd", "-n", m.name, "-k", image, "-d", "pixel_7",
                        "-p", avd.appendingPathComponent("\(m.name).avd").path, "--force"
                    ],
                    cwd: "/", env: env, stdin: Data("no\n".utf8), timeLimit: 120)
            }
            guard made.status == 0 else {
                throw RPCError.internalError(
                    "avdmanager: " + String(decoding: made.stderr + made.stdout, as: UTF8.self))
            }
            step(m, .starting)
            try await blocking {
                try startHelper(m)
                try check(ask(m.name, .init(op: .start), wait: 620))
            }
        }
    }
}
