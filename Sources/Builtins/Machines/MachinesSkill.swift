import Core
import KelpKit

extension Builtins {
    /// `kelp vm`, for agents. Written whenever it's on; the daemon gives it only to chats in a home with a machine
    /// (`SessionSetup.skillArgs`).
    static let machinesSkill = SkillSpec(
        name: "kelp-vm",
        description:
                "Use when a command should run in a Linux or macOS machine instead of on this Mac, or you need to see and tap a Mac "
                + "Android or iOS app, in Kelp, the IDE this session runs in: Linux builds and tests, servers and scripts kept off the Mac, "
                + "a Mac app's UI, an app on an Android emulator or an iOS simulator. "
                + "kelp vm run <name> -- <command> runs it there, in this project's folder at the same path.",
        setting: SettingKeys.skillVM,
        body: """
        # Running commands in a Kelp machine

        This session runs inside Kelp and the `kelp` CLI is on PATH. Kelp keeps Linux and macOS machines (Apple
        Virtualization) for commands that should not run on this Mac. One machine serves every chat at once.

        - `kelp vm list` — the machines and their state. Use one that's `running` before one that sleeps; a sleeping one
          wakes in under a second, an `off` one boots in a few.
        - `kelp vm run <name> -- <command>` — runs it in the machine, in this folder: the project is shared with the
          machine at the same path, so paths in its output are yours. Its output and exit code are the command's. Each run is
          a connection of its own; run several at once if you like.
        - Choose the machine for Linux builds and tests, servers and scripts you'd rather keep off the Mac, Docker-free Linux
          tooling, and x86-64 Linux binaries (they run through Rosetta). Keep macOS work (Xcode, swift on this Mac, the
          user's apps) on the Mac.
        - What you install there (`sudo apt-get install -y …`, no password) stays, for every chat: install what the task
          needs, nothing more.
        - `~/Kelp` in a Linux or macOS machine is a folder the user sees on the Mac (the machine's tab › Files › Open in
          Finder): leave files for the user there, and take the ones they put there for you.
        - A machine pauses after 2 minutes without a connection and sleeps after 10: a server keeps running only while a
          run holds it. Start one that should stay up as a Kelp session, so the user sees it:
          `kelp session new --cmd "kelp vm run <name> -- npm run dev"`.
        - None fits (macOS, Android or iOS work, and only Linux is there): `kelp vm create <name> --image macos`
          (or android, ios) asks the user on your row first and waits up to 10 minutes for their answer, then prints
          how making it goes (macOS: over 20 GB and about 20 minutes). Ask only when the task needs it.

        ## A macOS machine's screen

        Pick it for a Mac app's UI, Safari, Xcode's simulator, anything macOS-only; Linux for the rest. Commands first:
        `kelp vm run` works there too, and costs nothing. Then the app's controls as text, then pixels last:

        - `kelp vm screenshot <name> [file]` — a PNG of its screen (prints the file); look at it with your image tool.
          Coordinates are its screen points (1280 × 800), the same `click` takes. Works at once, nothing to allow.
        - `kelp vm click <name> X Y [--right] [--double]`, `type <name> TEXT`, `key <name> cmd+space`, `scroll <name> -300 [X Y]`,
          `drag <name> X Y X2 Y2` — the pointer and keys. The screen is one: chats take turns (your turn lasts 20 s after
          your last action); while another chat's turn lasts, yours says so: wait a moment and go on.
        - Look again after each step that changes the screen; give Spotlight and app launches a second. The user sees it
          live with `kelp vm show <name>`.
        - A dialog in it asks for the password (an installer, Privacy & Security): only the user may give it, and they
          don't know it. Run `kelp vm show <name>`, then ask them to press Type Password at the top of that window.
        - `kelp vm ui <name> [--app Safari]` — the front app's controls as text: `- button "Sign in" [ref=e12] (640,412 80×24)`;
          `kelp vm press <name> e12` presses one. It needs Accessibility for Kelp Guest inside, asked the first time: its
          error says how (a click on the dialog, the switch, the user's Type Password). Screenshots and clicks don't
          need it.

        ## An Android machine

        An emulator of the user's Android SDK, the same commands through adb: `kelp vm run <name> -- <command>` is Android's
        shell (am start, pm list packages, logcat -d), `kelp vm install <name> app.apk`, then `ui`, `press`, `screenshot`,
        `click X Y` (its screen's pixels, 1080 × 2400), `type`, `key <name> back|home|enter|appswitch`, `scroll`, `drag`.
        It shares no folders: `adb push` isn't needed for an apk, `install` takes the file from here.
        `launch <name> <package>` starts an app, `open <name> <url>` a link.

        ## An iOS machine

        A simulator of the user's Xcode, with Kelp's runner in it: `kelp vm install <name> App.app` (a simulator build, e.g.
        from `xcodebuild -destination 'platform=iOS Simulator,name=Kelp <name>'`), `launch <name> <bundle-id>`, `open <name> <url>`,
        then `ui` (the launched app's controls; `--app <bundle-id>` for another, Home Screen otherwise), `press`, `screenshot`,
        `click X Y` (screen points, as its screenshots are), `type`, `key <name> home|enter|tab|delete`, `scroll`, `drag`.
        `kelp vm run <name> -- <program>` runs a program in the simulator (simctl spawn). It shuts down after 10 idle minutes:
        the next command boots it again in about 20 seconds, its apps closed.

        """
    )
}
