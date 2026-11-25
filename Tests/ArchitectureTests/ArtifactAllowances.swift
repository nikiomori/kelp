/// The artifacts' own ways of touching files that `theAppDoesntTouchProjectFiles` allows: exports written where the user
/// picked, a video's leftovers, a doc's linked files looked for. Kept apart, as the artifact tab's exports grew.
let artifactPagesTouchFiles: [String: (Int, String)] = [
    "Builtins/Files/MarkdownTab+Motion.swift": (2, "a video's half taken away on Cancel, a failed mix's leftover"),
    "Builtins/Files/Artifacts/MotionMovie.swift": (1, "a video written over the file picked in a save panel"),
    "Builtins/Files/Artifacts/DeckExport.swift": (1, "a deck made as a design, as a PDF where the user picked"),
    "Builtins/Files/Artifacts/DocExport.swift": (2, "a document as Markdown or Word where the user picked"),
    "Builtins/Files/Artifacts/PageCheck.swift": (1, "whether a file a doc links to is there"),
    "Builtins/Files/Artifacts/PageExport.swift": (
        9,
        "a page exported where the user picked (a save panel, or kelp artifact export's path) and its folder of "
            + "boards, and a video's check left in the temporary folder for kelp artifact export"
    ),
    "Builtins/Files/Artifacts/PowerPoint.swift": (
        3, "a PowerPoint's parts in a temporary folder, and a page's pictures put inside its one-file export"
    )
]
