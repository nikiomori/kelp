import Core
import Foundation

/// Makes an Android machine, which is what `VMService.create` does with the android image. The machine gets an AVD of
/// its own in the machine's folder, built from the newest arm64 system image in the user's SDK. It takes the plain
/// image rather than the Play Store one, because the Play Store image updates Google's services at every boot.
/// Nothing is downloaded.
extension VMService {
    func makeAndroid(_ machine: VMMachine) async {
        await making(machine) {
            guard let avdmanager = AndroidSDK.avdmanager, let image = AndroidSDK.newestImage() else {
                throw RPCError.invalidParams(
                    "An Android machine runs on your Android SDK (Android Studio): it needs the SDK's "
                        + "command-line tools and an arm64 system image (Android Studio › Settings › Android SDK).")
            }
            try next(machine, .device, image.split(separator: ";").dropFirst().prefix(2).joined(separator: " "))
            let avd = folder(machine.name).avd
            try Paths.ensure(avd)
            var env = ProcessInfo.processInfo.environment
            env["ANDROID_AVD_HOME"] = avd.path
            if let root = AndroidSDK.root { env["ANDROID_SDK_ROOT"] = root.path }
            // avdmanager is a Java program, so it uses Android Studio's own Java runtime when JAVA_HOME isn't set.
            // There may be no java on PATH, because the PATH launchd gives kelpd isn't the shell's.
            let studio = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
            if env["JAVA_HOME"] == nil, FileManager.default.fileExists(atPath: studio) { env["JAVA_HOME"] = studio }
            let made = try await blocking { [env] in
                try Subprocess.run(
                    [
                        avdmanager, "create", "avd", "-n", machine.name, "-k", image, "-d", "pixel_7",
                        "-p", avd.appendingPathComponent("\(machine.name).avd").path, "--force"
                    ],
                    cwd: "/", env: env, stdin: Data("no\n".utf8), timeLimit: 120)
            }
            guard made.status == 0 else {
                throw RPCError.internalError(
                    "avdmanager: " + String(decoding: made.stderr + made.stdout, as: UTF8.self))
            }
            try next(machine, .starting)
            try await blocking {
                try startHelper(machine)
                try check(ask(machine.name, .init(op: .start), wait: 620))
            }
        }
    }
}
