import Core
import KelpKit

extension Builtins {
    /// `kelp browser`, for agents. Always written: which chats get it is the daemon's choice (Settings' In Web Projects /
    /// Always / Never, and each project's).
    static let browserSkill = SkillSpec(
        name: "kelp-browser",
        description:
            "Use when you need to see or try a web page — the app you're building on its dev server, a form, a page's "
            + "text — in Kelp, the IDE this session runs in: open it in a tab beside you that the user watches, read it, click, "
            + "type, run JavaScript, take a screenshot, read its console and requests. Done with kelp browser, not a headless browser.",
        body: """
            # Using a web page in Kelp

            This session runs inside Kelp and the `kelp` CLI is on PATH. `kelp browser` drives a page tab beside your
            terminal: the user sees every step. It's Safari's engine (WebKit), in Kelp's window. To only read a public
            page, an API or docs, fetch it (curl, your fetch tool): the browser is for using a page, one its script
            draws, your dev server.

            - `kelp browser open localhost:3000` — opens the page (or takes your page there) and prints its url and
              title once it loaded; `error` says why it didn't. The page has cookies and storage of its own, so you
              start logged out. `--shared` uses the user's instead: only when they ask, it acts as them, and Kelp asks
              them first, for that one site; going to another site is blocked (the console says so) until you open it
              with `--shared` again. Every other command drives a page you opened: the user's own tabs aren't yours.
            - `kelp browser reload` — after you change the code: loads it all again, nothing from the cache (opening the
              address it shows does the same).
            - `kelp browser snapshot` — what's on the page, a line an element: `- button "Save" [ref=e12]`, `- textbox
              "Email" [ref=e3]: "a@b.c"`, `- link "Docs" [ref=e5] -> /docs`. Read it rather than a screenshot. An
              element keeps its ref while it's on the page; what came since your last snapshot ends in `[new]` (the menu
              a click opened, an error under a field). Text shows only as a person sees it (not transparent); a frame of
              the page's own site is read too, another site's isn't (a screenshot shows it). On a long page the middle
              is cut: `snapshot --find "cart"` keeps the lines that mention it (and what they sit in), `snapshot e7`
              only what's in e7.
            - `kelp browser click e12`, `kelp browser type e3 "a@b.c" [--submit]` — refs from a snapshot (one the page
              no longer has says so). Both wait until the page is quiet, then `change` says what they did: `new page`,
              `page changed` or `nothing changed` (a click that did nothing: look why before trying again). Kelp's
              pointer moves to the element and it glows a moment, so the user sees it. Something over it (a cookie
              banner, a dialog) stops the action with what covers it, as it would stop a person: close or answer that
              first. `type` replaces the text a key at a time; `shows` says what the field shows when the page made it
              something else (a mask, a length limit). A select takes an option's text or value (any case, or the one it
              starts with; a wrong one lists them), a date field its own format (`2026-03-14`, time `09:30`).
            - `kelp browser drag e4 e9` — e4 dragged onto e9 as a person drags (pressed, moved, let go): sortable lists,
              boards, sliders; what can be dragged shows as `draggable`. Onto a zone with no ref, give a CSS selector
              (`drag e4 ".column.done"`). The page must take the drop there, or the error says so.
            - `kelp browser upload e9 photo.png [more…]` — files into a file field: its ref, its label's, or the button
              over a hidden one; with no field, they're dropped on e9 (a drop zone). A file chooser the page opens by
              itself is cancelled.
            - Downloads (a `download` link, an attachment, a file the page can't show) land in `$TMPDIR/kelp-downloads`:
              the action's answer lists them under `downloads` with their path and size once done, and so does
              `console`.
            - A page's `alert` / `confirm` / `prompt` doesn't stop you: the action's answer lists it under `dialogs`
              (`confirm "Delete?" → dismissed`) and so does `console`. They get OK / Cancel / Cancel unless you said
              before the click: `kelp browser dialog accept ["text for a prompt"]` or `dialog dismiss`, for the next one
              only.
            - `kelp browser press Escape` (`Enter`, `Tab`, `Shift+Tab`, `ArrowDown`, … `[ref]` to focus one first) —
              closes a menu, moves through a list, submits. Not for text: `type` it.
            - `kelp browser hover e7` — menus that open on hover from script; pure CSS `:hover` doesn't follow.
            - `kelp browser scroll [down|up|top|bottom|e7]` — the page or its main scrolling pane; prints where it is,
              and waits a little for what scrolling loads. `kelp browser back` — the previous page.
            - `kelp browser wait --text "Saved" [--selector ".toast"] [--timeout 10]` — until it shows.
            - `kelp browser eval "document.querySelectorAll('li').length"` — an expression in the page, its value as
              JSON; for statements, `(() => { … })()`.
            - `kelp browser screenshot [file.png]` — prints where it went; look at it with your image reading.
            - `kelp browser viewport 390x844` — the page at that size (CSS pixels), for a layout at a phone's or
              tablet's width; prints the size the page now has. `viewport reset` fills the pane again. Only the size:
              the user agent, touch and pixel ratio stay a Mac's.
            - `kelp browser console [--clear]` — what the page logged: `console.*`, uncaught errors, resources that
              failed to load, and `[page] url` at each load. `--clear` empties it once printed, so the next call shows
              only what's new.
            - `kelp browser network [--clear]` — the page's loads and its `fetch` / XHR calls: `200 GET url (fetch, 34
              ms)`, `failed POST url (fetch, 12 ms: TypeError…)`. Images, scripts and styles show only when they fail
              (in console).
            - `kelp browser info` — where the page is now.

            After a click or a submit that misbehaves, read `console` and `network` before guessing.

            Clicks and typing are DOM events: a page that only takes trusted ones (some payment and captcha widgets)
            ignores them. Tell the user rather than work around it.

            The user can take your page over (a bar over it says an agent uses it): then only snapshot, screenshot,
            wait, console, network and info work, and the error says so. Wait for them or ask; don't open another page
            around it.

            """
    )
}
