# Writing Kelp extensions

An extension is a folder in `~/.kelp/extensions/<id>/` with an `extension.json`. No build step:
Kelp reloads it when the files change. Commands run with `/bin/zsh -lc` in the current workspace
directory, so anything you can do in a terminal you can surface in the IDE.

Quick start: `kelp ext new my-thing`.
Useful while developing: `kelp ext list`, `kelp ext reload`, `kelp ext disable <id>`.

## extension.json
```json
{
  "id": "docker",
  "name": "Docker",
  "version": "1.0.0",
  "description": "Containers on this Mac",
  "icon": "shippingbox",
  "contributes": {
    "panels":   [],
    "editors":  [],
    "commands": [],
    "settings": [],
    "themes":   [],
    "iconThemes": [],
    "agents":   [],
    "languages": []
  }
}
```
`icon` and every other `icon` field is an SF Symbol name (see the SF Symbols app).

## Views: panels (right inspector) and editors (center tabs)
Both take the same view definitions; `editors` also appear in the editor area's "+" menu.

### list — rows from a command
```json
{
  "id": "containers",
  "title": "Containers",
  "icon": "shippingbox",
  "list": {
    "command": "docker ps -a --format '{{json .}}'",
    "refresh": 5,
    "title": "${Names}",
    "subtitle": "${Image} · ${Status}",
    "icon": "shippingbox",
    "status": { "field": "State", "map": { "running": "working", "exited": "done", "dead": "ended" } },
    "empty": "No containers",
    "actions": [
      { "title": "Open Shell", "icon": "terminal", "terminal": "docker exec -it ${ID} sh" },
      { "title": "Logs", "icon": "text.alignleft", "terminal": "docker logs -f --tail 200 ${ID}" },
      { "title": "Stop", "icon": "stop.circle", "run": "docker stop ${ID}", "confirm": "Stop ${Names}?" },
      { "title": "Ask Agent Why It Failed", "icon": "sparkles", "agent": "Container ${Names} (${Image}) is ${Status}. Find out why." }
    ],
    "toolbar": [
      { "title": "Prune", "icon": "trash", "terminal": "docker system prune" }
    ]
  }
}
```
- `command` prints a JSON array, or one JSON object per line. Each object is a row.
- `${Field}` reads a field of the row (`${a.b}` for nested), `${setting:key}` a setting,
  `${workspace.path}`, `${workspace.branch}`, `${project.path}`, `${file}` (the focused file).
  Inside commands, values are shell-quoted for you: each becomes an exported variable (`$KELP_V1`, …) the command
  reads. Code another program runs keeps it data too: in `sh -c '…'` / `"…"` (any path to the shell, after `env` too),
  `eval`, a here-document fed to `sh`, it's that shell's variable; in `ssh host '…'` / `"…"` it arrives quoted for the
  host's shell. In `python3 -c`, `perl -e`, `node -e` or `osascript -e` code, `${Field}` is left as the variable's name:
  read it there as the environment variable `KELP_V1` (the first placeholder, `KELP_V2` the next…).
- Plainest of all: every field of the row and each value above is also exported by name, `KELP_<name>` (`.` and other
  signs as `_`: `$KELP_title`, `$KELP_workspace_path`). Write `"$KELP_title"` in a command, or read it from the
  environment in any program, and nothing has to be quoted. Over `ssh` the host doesn't get them: use `${Field}` there.
- A row shows `icon` only when it reads a field (`"${kind}"`): a fixed icon is the panel's, already on its tab.
  A `subtitle` that comes out empty takes no line.
- `status` maps a field to a status dot: `working`, `waiting`, `done`, `idle`, `ended`.
- The first action is the default (double-click / Return); all of them are in the row's context menu.
- `toolbar`: the panel's bar shows the first one in words and the rest as icons (their `title` is the tooltip).
- `refresh`: seconds between reloads (0 = only on open and after actions).

### badge — a mark on a panel's icon
A panel (list or web) may add `"badge": { "command": "gh pr list --search review-requested:@me --json number --jq length", "refresh": 120 }`.
The command runs every `refresh` seconds (60 by default) while the panel is in the inspector, even when it isn't shown, and prints:
a number (a grey count; 0 or nothing: no badge), any other text (a dot, gone once the panel is opened, back when the
text changes), or either after `!` (red: something failed). A command that fails shows a red dot.
A web panel can also set it itself: `kelp.badge(3)`, `kelp.badge("!")`, `kelp.badge(null)`.

### web — any UI you like
```json
{ "id": "dashboard", "title": "Emulator", "icon": "iphone", "web": "index.html" }
```
The page (relative to the extension folder) gets `window.kelp`:
```js
await kelp.exec("adb devices")            // {code, stdout, stderr}, runs in the workspace
kelp.terminal("emulator -avd Pixel_8")    // opens a terminal tab
kelp.open("https://localhost:3000")       // URL → browser tab, path → file tab (never a terminal: or agent: URI)
kelp.agent("Write a test for the parser") // new agent tab with this prompt typed, for the user to send
await kelp.settings.get("my.key"); await kelp.settings.set("my.key", 3)
kelp.workspace                            // {name, path, branch, project}
kelp.on("settings", s => …); kelp.on("workspace", w => …)
kelp.badge(2)                             // the panel icon's badge (see badge above)
```

## Actions (list rows, toolbars, commands)
Exactly one of:
| key | does |
| --- | --- |
| `terminal` | opens a terminal tab running the command |
| `run` | runs the command in the background; output shown only on failure |
| `open` | opens a URL (browser tab) or a path (file tab) |
| `agent` | starts the default agent in a new tab with this prompt |
Optional: `confirm` (question shown first), `icon`.

## commands
```json
{ "id": "docker.prune", "title": "Docker: Prune Unused Data", "terminal": "docker system prune", "key": "cmd+shift+k", "menu": "Tools" }
```
Shown in the command palette (⇧⌘P) and the menu bar: `menu` is File, Edit, View, Run, Window or Help (Tools when
left out). `key` binds a shortcut; Settings › Keyboard can change it. `kelp run <id>` runs a command, and
`kelp ui state` lists every command id, Kelp's own too.

## settings
```json
{ "key": "docker.refresh", "title": "Refresh interval", "type": "number", "default": 5, "description": "Seconds" }
```
Types: `boolean`, `number`, `string`, `enum` (with `"options": ["a", "b"]`), `color`. A `number` with `"options": ["0", "15"]` shows as a picker of those values.
They appear in Settings under the extension's name and in `~/.kelp/settings.json`. `"group": "Refresh"` puts a setting and
the ones after it with the same group under that heading.

## themes
```json
{
  "id": "dracula", "name": "Dracula", "appearance": "dark",
  "terminal": { "background": "#282a36", "foreground": "#f8f8f2", "cursor": "#f8f8f2", "selection": "#44475a",
                "palette": ["#21222c","#ff5555","#50fa7b","#f1fa8c","#bd93f9","#ff79c6","#8be9fd","#f8f8f2",
                            "#6272a4","#ff6e6e","#69ff94","#ffffa5","#d6acff","#ff92df","#a4ffff","#ffffff"] },
  "editor": { "background": "#282a36", "text": "#f8f8f2", "keyword": "#ff79c6", "string": "#f1fa8c",
              "comment": "#6272a4", "type": "#8be9fd", "number": "#bd93f9", "function": "#50fa7b" }
}
```
Without `window`, the panels and the editor area take the theme's colours. With it, the theme builds the window itself:
```json
{
  "id": "sea", "name": "Sea", "appearance": "dark",
  "terminal": { "background": "#031c20", "foreground": "#cfeee8", "opacity": 0.65, "shader": "bloom" },
  "editor": { "background": "#031c20", "text": "#cfeee8", "opacity": 0.8 },
  "window": { "surface": "#021316", "border": "#4de8c229", "radius": 12, "accent": "#4de8c2", "font": "mono",
              "ambient": "motes", "ambientColors": ["#4de8c2", "#38d9d9"] }
}
```
- `terminal.opacity`, `editor.opacity`: under 1, what's under them shows through and the editor area loses its fill. Settings › Appearance › Terminal opacity overrides it for any theme.
- `terminal.shader`: `crt` (rows of light, a glow, dark corners) or `bloom` (bright text bleeds into the dark). Still images: they cost only when a terminal draws.
- `window.surface`: the panels and the gap round the editor area: a colour, or `material` for macOS's own, with the desktop behind it. `surfaceOpacity` lets the desktop through a colour too.
- `window.card`, `border`, `borderWidth`, `radius`: the editor area. `border` takes `#rrggbbaa`.
- `window.accent`: the chrome's accent (native controls keep the system's). `window.font`: the chrome's face, `mono`, `serif` or `rounded`.
- `window.ambient`: what moves behind it all, in `ambientColors`: `aurora` (slow wide lights), `motes` (specks rising), `grid` (a drafting grid, still). It stops while Kelp isn't the active app, and under Reduce Motion.

## iconThemes
File icon themes in VS Code's format, so existing ones work unchanged:
```json
{ "id": "my-icons", "label": "My Icons", "path": "icons/theme.json" }
```
`path` is a VS Code file icon theme: `iconDefinitions` (each with an `iconPath` to an SVG or PNG), then `file`, `folder`,
`folderExpanded`, `fileExtensions`, `fileNames`, `folderNames`, `folderNamesExpanded`, `languageIds` and a `light` section.
Font icons (`fontCharacter`) aren't drawn. A VS Code extension needs no `extension.json`: Settings › Extensions › Install…
takes its `.vsix` or its folder (`package.json` → `contributes.iconThemes`). Pick the theme in Settings › Appearance › File Icon Theme.

## agents
Same format as `~/.kelp/agents/*.json`: `{ "id", "name", "command", "args", "resumeArgs", … }`.

## languages
Which files a language covers, the language server that gives them completion and jump to definition, and the
commands that run, test and format them:
```json
{
  "id": "python",
  "extensions": ["py"],
  "server": { "command": "pyright-langserver", "args": ["--stdio"], "install": "npm i -g pyright" },
  "run": "python3 ${file}",
  "test": "python3 -m pytest ${file} -k ${symbol}",
  "format": "ruff format -"
}
```
`id` is the LSP language id. `extensions` match in any case; `"fileNames": ["Dockerfile"]` matches whole names.
Kelp's own are swift, typescript, typescriptreact, javascript, javascriptreact, python, go and rust; a language with
the same `id` replaces one. When `command` isn't on PATH, opening a file says so, with a button that runs `install`
in a terminal.

`run` and `test` open a terminal tab in the workspace's folder: Run › Run File and Test at Cursor, and ⌘R / ⌘U when
the project's `.kelp.yaml` has no `run` / `test`. `format` gets the file's text on stdin and prints it formatted, run
in the file's folder (Format Document, ⌃⇧I; Settings › Editor › Format on save). In all three, `${file}`,
`${relativeFile}` (to the workspace), `${dir}` (the file's folder), `${line}`, `${symbol}` (the function or class
around the cursor, from the language server, else the word under it) and `${workspace}` are filled in, shell-quoted;
any other `${…}` is left to the shell.

## The library
[github.com/nikiomori/kelp-extensions](https://github.com/nikiomori/kelp-extensions) holds extensions people shared,
each reviewed before it's merged. Kelp downloads exactly the commit that was reviewed and, before installing, shows
which commands the extension can run.
- Install: Settings › Extensions › Library, or `kelp ext search [text]` then `kelp ext install <id>`.
  `kelp ext update [id]` brings what came from GitHub up to date (the old copy goes to the Trash).
- Any other GitHub folder installs the same way, without the review:
  `kelp ext install https://github.com/me/repo` (the repo is the extension) or `…/tree/<branch>/<folder>`: what it can
  run is shown and asked about first (`--yes` installs without asking; without a terminal it's needed).
  A folder on disk: `kelp ext install ./my-ext`.
- Share yours: a pull request adding `extensions/<id>/` to that repo — `extension.json` (its `id` is the folder's name;
  `name`, `version` like `1.0.0` and `description` required) and a `README.md`; no binaries, symlinks or files over
  1 MB. Changing one later needs a new `version`. The repo's README has the `gh` commands.
- A team's own library: the `extensions.library` setting is the URL of its `index.json` (same format, written by
  that repo's `scripts/index.py`).

## Tips for agents writing extensions
- Start from `kelp ext new <id>`; keep everything in that folder.
- Test the list `command` in a terminal first: it must print JSON.
- `kelp ext reload` reloads all extensions; errors show in Settings → Extensions.
