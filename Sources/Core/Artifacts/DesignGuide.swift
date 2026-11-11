import Foundation

/// What `kelp artifact guide design|dashboard` prints: a short core every canvas needs, and the parts read only when
/// one is needed (`kelp artifact guide design <part>`). Each is fixed text, so it stays in the agent's prompt cache.
extension Artifacts {
    public static let designParts = ["system", "craft", "deck"]

    /// The core for a canvas of `kind` (a design or a dashboard). `system`: whether the project has its design system
    /// yet (`.kelp/design/`).
    static func canvasCore(_ kind: Kind, system: Bool) -> String {
        let systemLine =
            system
            ? "The project's design system is in `.kelp/design/`: read DESIGN.md and kit.css before the first board, "
                + "and build with its classes and tokens (`var(--accent)`); never restyle what the kit already draws."
            : "The project has no design system yet (`.kelp/design/`): make it first, from its code: "
                + "`kelp artifact guide design system`. One turn, and every later design reuses it."
        return """
            Run `kelp artifact new \(kind.rawValue) "<title>"`: it makes the folder and prints its paths; Kelp opens the
            canvas beside you and redraws it each time you save. Nothing to publish.

            \(systemLine)

            Files (Kelp draws the frames, the rows, each board in light and dark, and the page around each board):
            - `canvas.json`: `{"boards": [{"file": "boards/A-welcome.html", "row": "A. Steps one at a time",
              "title": "Welcome", "w": 1280}]}`. Rows show in the order of their first board. `w` always; `h` only for a
              fixed frame (a phone 390×844, a poster, an app's panel), otherwise a board is as tall as what it holds. A
              fixed frame is the whole screen: its root fills it (`min-height: 100vh`).
            - `boards/<name>.html`: one screen, as a fragment: no <html>, <head> or <body>, no scripts (they don't run).
              Colours, fonts, sizes and spacing only through the tokens, never typed in: then the dark board is right
              too.
            - `data-id="title"` on every element worth pointing at (headings, buttons, fields, cards): the user's marks
              come back to you by it.
            - Levers the user moves without you: up to 4 lines at the top of a board,
              `<!-- tweak --highlight: #1f7a5a -->` (a colour) or `<!-- tweak --gap: 12px (8px, 12px, 16px) -->`
              (choices), used as `var(--highlight)`. A tweak is one value for light and dark: name it for what it
              moves, never after a token.

            How to work:
            \(kind == .dashboard ? dashboardStart : designStart)
            2. Write all the boards and canvas.json in one go (parallel writes). No generator scripts: the kit is
               the shared part.
            3. Run `kelp artifact check <name>` once and fix what it lists. Don't screenshot, open or read back the
               page: the user sees it beside you.
            4. Answer in two lines: what is on the canvas, what you assumed. The user's marks arrive as
               `Marks on <canvas>: boards/A.html 1 [data-id=title] «Welcome»: bigger | …`: edit those elements in
               place, never rewrite a board; the user may have changed a board by hand (its text, a style), so read
               it again first. `Picked “A. …”` means: build that row out, drop the others from
               canvas.json.

            Before the first board, read `kelp artifact guide design craft` (once a session). In short: real content,
            no lorem ipsum or invented
            numbers ([YOUR PRICE] instead); no gradient washes, emoji, cards with a coloured left border; text 4.5:1;
            touch targets 44px on a phone, while a Mac app keeps the Mac's own sizes; real <button>, <a href>,
            <label>; a phone is 390 wide, a page 1280–1440.

            """
    }

    private static let designStart = """
        1. If the look is open (no system, nothing said about it), make 2–3 small direction boards first, a row each
           ("A. Dense list", "B. Cards"), each different on one axis you can name; say why in a line each and stop.
           Otherwise build the screens straight away. A deck: `kelp artifact guide design deck`.
        """

    private static let dashboardStart = """
        1. Get the numbers first (run the commands, read the files). A board per view, 1280 wide: the figures that
           matter, large, with a label; then charts as inline SVG coloured from the tokens; then the table they came
           from. Every figure carries where it came from and when: `<b data-value data-source="gh run list, 11 Nov
           10:00">42</b>`; the check lists one without. To bring it up to date, the user asks you again.
        """

    static func designPart(_ part: String) -> String? {
        switch part {
        case "system": designSystem
        case "craft": designCraft
        case "deck": designDeck
        default: nil
        }
    }

    private static let designSystem = """
        # The project's design system, in .kelp/design/

        Write it once from the project's own code (its stylesheets, theme, Tailwind config, a UI kit's constants such as
        an app's Metrics and colours), not from taste: exact values, never rounded. Three files:

        1. `tokens.json`. Kelp turns it into CSS variables on every board, in light and dark:
           ```json
           {
             "color": {
               "bg": {"light": "#fafaf8", "dark": "#161617"},
               "surface": {"light": "#ffffff", "dark": "#1f1f21"},
               "text": {"light": "#1c1c1e", "dark": "#ececec"},
               "muted": {"light": "#5f6168", "dark": "#a1a3a8"},
               "line": {"light": "#e2e2de", "dark": "#333336"},
               "accent": {"light": "#1f7a5a", "dark": "#5cc79c"}
             },
             "font": {"body": "-apple-system, sans-serif", "mono": "ui-monospace, monospace"},
             "size": {"small": "12px", "body": "15px", "h2": "22px", "h1": "34px"},
             "space": {"1": "4px", "2": "8px", "3": "12px", "4": "16px", "6": "24px", "8": "32px"},
             "radius": {"s": "4px", "m": "8px", "l": "12px"}
           }
           ```
           A colour is `--<name>` (`var(--accent)`), any other token `--<group>-<name>` (`var(--space-4)`,
           `var(--font-body)`). A value is one string for both themes or `{"light", "dark"}`. Kelp sets each board's
           page from `bg`, `text`, `font.body` and `size.body`: keep those names. Add the project's own (`warning`,
           `selection`), and check every text colour against its ground at 4.5:1 in both themes.
        2. `kit.css`: first the plain elements as the project draws them (`a`, `button`, `input`, headings, lists:
           in an app a row that opens something is not underlined text), then the project's components as classes,
           named as the project names them (`.button.primary`, `.list-row`, `.sidebar`, `.badge`), with their states
           (`:hover`, `.selected`, `[disabled]`), built only from the tokens. Then its icons and marks as classes, since
           a board loads no files: a one-colour symbol as `.icon.doc { mask: url("data:image/svg+xml,…") center /
           contain no-repeat; background: currentColor }`, a logo (the project's, the products it works with) as a
           `background-image` data URL, each drawn from the project's own assets or the symbols it uses. This is what
           keeps designs from drifting and looking generic: a board is mostly these classes.
        3. `DESIGN.md`, at most 60 lines: what the product is and for whom; its voice; which class for what; Do and
           Don't lists with the project's real rules (sizes, one accent, how errors show).

        Then make the design you were asked for. Change the system only when the user asks: every design uses it.

        """

    private static let designDeck = """
        # A deck as a design

        For slides in the project's own look (its fonts, colours, components); plain Markdown slides are
        `kelp artifact guide slides`.

        - A board per slide, `"w": 1920, "h": 1080`, without a `row`: each is a row of its own, in the deck's order.
        - The first slide is the title; one idea a slide; nothing smaller than 24px; at most 4–5 sizes.
        - A slide is laid out to fit its frame (the check says when one runs over): too much is two slides, not
          smaller type.
        - The user presents it with Present in the canvas's bar (← → step, Esc ends) and prints a page a slide.

        """

    private static let designCraft = """
        # Craft for designs

        Look
        - Decide the look before the first board: the system's, a brand the user names, or one direction you can name
          in four words. Without a system, a neutral grey with one accent; never cream-and-serif or purple gradients
          by habit.
        - Options: 2–4, each on an axis you can name (density, layout, navigation), with the same names across turns.
          Why each one and what it costs go in your answer, not on the board.
        - Use what the system has: its components, icons and logos (an agent's or a product's name gets its logo
          beside it where the product shows one), not look-alikes drawn again.

        States: a screen is judged by them
        - Draw the states the brief names and the ones every such screen has: in a list one row selected and one
          under the pointer (frozen, as a real row), a row being worked on, an empty state, an error or offline state
          when the data can fail, a disabled control when one can't be used yet. A board per state, or one board
          showing several rows each in its own.
        - An empty state: what goes here, why it's empty, and the one action that fills it, with a verb that says
          what it does ("New Doc", not "Make…").

        Content
        - The subject's real words, units and terms; missing facts as [YOUR PRICE]. Full product names ("Claude
          Code", not "Claude"). The project's own case rules (DESIGN.md); "…" is one character.
        - Times say what the heading around them doesn't: under Today a clock time (14:20), this week a weekday, older
          a date (Nov 6); never "1d" under Yesterday.
        - Copy from the user's side of the screen: a button says what it does.

        Layout and type
        - A scale of 4–5 sizes from the tokens; running text about 65 characters wide; headings balanced.
        - Siblings with flex or grid and gap, not margins; repeated rows share edges and paddings; columns of numbers
          and times line up (tabular digits, a fixed column). Text that outgrows its box wraps, never clips.
        - A page works at 390 wide too: rows stack, tables scroll in their box.

        A product's website
        - Header: the logo (the system's), 3–4 section links, and the main action again on the right.
        - Hero: a short line above the headline (version, platform), the headline, one sentence under it, the main
          action and a quieter second one, then the requirement line (OS, price); then a picture of the product.
        - Each feature: a small label, a heading, one or two sentences, three short points (a check icon each), and a
          picture beside it, sides alternating; the same spacing between every section.
        - Pictures of the product are filled and true to it: every pane has content, lines at the product's own
          spacing, text in them 11px or larger; crop to the part that matters rather than draw a half-empty window.

        Colour and access
        - The accent marks the one thing to do; state (error, warning, done) has its own colours and a word or icon
          too; colours that must be told apart differ in lightness.
        - A filled button's label is 4.5:1 on its fill: darken the fill if the accent is too light.
        - Real controls, `aria-label` on icon-only buttons, visible focus, contrast 4.5:1 (3:1 at 24px and up) in
          both themes. Icons in one set and weight, in currentColor; no emoji.
        - Leave out what wasn't asked: no extra sections, fake stats, testimonials or decorative blobs.

        """
}
