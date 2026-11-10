import Foundation

/// What `kelp artifact guide design` prints: a short core every design needs, and the parts read only when one is
/// needed (`kelp artifact guide design <part>`). Each is fixed text, so it stays in the agent's prompt cache.
extension Artifacts {
    public static let designParts = ["system", "craft"]

    /// The core. `system`: whether the project has its design system yet (`.kelp/design/`).
    static func designCore(system: Bool) -> String {
        let systemLine =
            system
            ? "The project's design system is in `.kelp/design/`: read DESIGN.md and kit.css before the first board, "
                + "and build with its classes and tokens (`var(--accent)`); never restyle what the kit already draws."
            : "The project has no design system yet (`.kelp/design/`): make it first, from its code: "
                + "`kelp artifact guide design system`. One turn, and every later design reuses it."
        return """
            Run `kelp artifact new design "<title>"`: it makes the folder and prints its paths; Kelp opens the canvas
            beside you and redraws it each time you save. Nothing to publish.

            \(systemLine)

            Files (Kelp draws the frames, the rows, each board in light and dark, and the page around each board):
            - `canvas.json`: `{"boards": [{"file": "boards/A-welcome.html", "row": "A. Steps one at a time",
              "title": "Welcome", "w": 1280}]}`. Rows show in the order of their first board. `w` always; `h` only for a
              fixed frame (a phone 390×844, a poster), otherwise a board is as tall as what it holds.
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
            1. If the look is open (no system, nothing said about it), make 2–3 small direction boards first, a row each
               ("A. Dense list", "B. Cards"), each different on one axis you can name; say why in a line each and stop.
               Otherwise build the screens straight away.
            2. Write all the boards and canvas.json in one go (parallel writes). No generator scripts: the kit is
               the shared part.
            3. Run `kelp artifact check <name>` once and fix what it lists. Don't screenshot, open or read back the
               page: the user sees it beside you.
            4. Answer in two lines: what is on the canvas, what you assumed. The user's marks arrive as
               `Marks on <canvas>: boards/A.html 1 [data-id=title] «Welcome»: bigger | …`: edit those elements in
               place, never rewrite a board. `Picked “A. …”` means: build that row out, drop the others from
               canvas.json.

            Craft, in short (more: `kelp artifact guide design craft`): real content, no lorem ipsum or invented
            numbers ([YOUR PRICE] instead); no gradient washes, emoji, cards with a coloured left border; text 4.5:1;
            touch targets 44px; real <button>, <a href>, <label>; a phone is 390 wide, a page 1280–1440.

            """
    }

    static func designPart(_ part: String) -> String? {
        switch part {
        case "system": designSystem
        case "craft": designCraft
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
        2. `kit.css`: the project's components as classes, named as the project names them (`.button.primary`,
           `.list-row`, `.sidebar`, `.badge`), with their states (`:hover`, `.selected`, `[disabled]`), built only from
           the tokens. This is what keeps designs from drifting: a board is mostly these classes.
        3. `DESIGN.md`, at most 60 lines: what the product is and for whom; its voice; which class for what; Do and
           Don't lists with the project's real rules (sizes, one accent, how errors show).

        Then make the design you were asked for. Change the system only when the user asks: every design uses it.

        """

    private static let designCraft = """
        # Craft for designs

        - Decide the look before the first board: the system's, a brand the user names, or one direction you can name
          in four words. Without a system, a neutral grey with one accent; never cream-and-serif or purple gradients
          by habit.
        - Options: 2–4, each on an axis you can name (density, layout, navigation), with the same names across turns.
          Why each one and what it costs go in your answer, not on the board.
        - Content: the subject's real words, units and terms; missing facts as [YOUR PRICE]. Copy from the user's
          side of the screen: a button says what it does.
        - Type: a scale of 4–5 sizes from the tokens; running text about 65 characters wide; headings balanced.
        - Layout: siblings with flex or grid and gap, not margins; repeated rows share edges and paddings; text that
          outgrows its box wraps, never clips. A page works at 390 wide too: rows stack, tables scroll in their box.
        - Colour: the accent marks the one thing to do; state (error, warning, done) has its own colours and a word or
          icon too; colours that must be told apart differ in lightness.
        - Accessible as drawn: real controls, `aria-label` on icon-only buttons, visible focus, contrast 4.5:1
          (3:1 at 24px and up) in both themes.
        - Icons as inline SVG strokes in currentColor, one set and weight; no emoji.
        - Leave out what wasn't asked: no extra sections, fake stats, testimonials or decorative blobs.

        """
}
