import Foundation

/// A PowerPoint of pictures, one a slide, 16:9: the parts of a .pptx (Office Open XML) written into a folder, which a
/// ZIP of its contents makes the file. Only what PowerPoint and Keynote need: a master, a blank layout, a theme.
enum PowerPoint {
    private static let ns =
        #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" "#
        + #"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" "#
        + #"xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
    private static let head = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
    private static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static let type = "application/vnd.openxmlformats-officedocument.presentationml."
    private static let tree =
        #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"#

    /// Writes the parts of a deck of `pictures` (PNG, 16:9) into `folder`.
    static func write(_ pictures: [Data], into folder: URL) throws {
        let n = pictures.indices.map { $0 + 1 }
        var parts: [String: String] = [
            "[Content_Types].xml": head
                + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
                + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
                + #"<Default Extension="xml" ContentType="application/xml"/>"#
                + #"<Default Extension="png" ContentType="image/png"/>"#
                + over("/ppt/presentation.xml", type + "presentation.main+xml")
                + over("/ppt/slideMasters/slideMaster1.xml", type + "slideMaster+xml")
                + over("/ppt/slideLayouts/slideLayout1.xml", type + "slideLayout+xml")
                + over("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml")
                + n.map { over("/ppt/slides/slide\($0).xml", type + "slide+xml") }.joined() + "</Types>",
            "_rels/.rels": rels([("rId1", "officeDocument", "ppt/presentation.xml")]),
            "ppt/presentation.xml": head + "<p:presentation \(ns)>"
                + #"<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>"#
                + n.map { #"<p:sldId id="\#(255 + $0)" r:id="rId\#($0 + 1)"/>"# }.joined()
                + #"</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/>"#
                + "</p:presentation>",
            "ppt/_rels/presentation.xml.rels": rels(
                [("rId1", "slideMaster", "slideMasters/slideMaster1.xml")]
                    + n.map { ("rId\($0 + 1)", "slide", "slides/slide\($0).xml") }
                    + [("rId\(n.count + 2)", "theme", "theme/theme1.xml")]),
            "ppt/slideMasters/slideMaster1.xml": head
                + "<p:sldMaster \(ns)><p:cSld><p:spTree>\(tree)</p:spTree></p:cSld>"
                + #"<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" "#
                + #"accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" "#
                + #"folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/>"#
                + "</p:sldLayoutIdLst></p:sldMaster>",
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": rels(
                [("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")]
            ),
            "ppt/slideLayouts/slideLayout1.xml": head
                + #"<p:sldLayout \#(ns) type="blank"><p:cSld name="Blank"><p:spTree>\#(tree)</p:spTree></p:cSld>"#
                + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>",
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels": rels(
                [("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]),
            "ppt/theme/theme1.xml": theme
        ]
        for i in n {
            parts["ppt/slides/slide\(i).xml"] =
                head + "<p:sld \(ns)><p:cSld><p:spTree>\(tree)"
                + #"<p:pic><p:nvPicPr><p:cNvPr id="2" name="Slide \#(i)"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>"#
                + #"<p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"#
                + #"<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="12192000" cy="6858000"/></a:xfrm>"#
                + #"<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>"#
                + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            parts["ppt/slides/_rels/slide\(i).xml.rels"] = rels(
                [
                    ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
                    ("rId2", "image", "../media/image\(i).png")
                ])
        }
        for (path, text) in parts { try write(Data(text.utf8), folder.appendingPathComponent(path)) }
        for (i, picture) in zip(n, pictures) {
            try write(picture, folder.appendingPathComponent("ppt/media/image\(i).png"))
        }
    }

    private static func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static func over(_ part: String, _ type: String) -> String {
        #"<Override PartName="\#(part)" ContentType="\#(type)"/>"#
    }

    private static func rels(_ list: [(id: String, type: String, target: String)]) -> String {
        head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + list.map { #"<Relationship Id="\#($0.id)" Type="\#(rel + $0.type)" Target="\#($0.target)"/>"# }.joined()
            + "</Relationships>"
    }

    /// The smallest whole theme: its colours, fonts and the three styles of each kind it must list.
    private static let theme: String = {
        let colours = [
            ("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "1F1F1F"), ("lt2", "EEEEEE"), ("accent1", "007AFF"),
            ("accent2", "34C759"), ("accent3", "FF9500"), ("accent4", "FF3B30"), ("accent5", "AF52DE"),
            ("accent6", "5AC8FA"), ("hlink", "007AFF"), ("folHlink", "AF52DE")
        ].map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fill = #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#
        let line = #"<a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>"#
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
        let font = #"<a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/>"#
        return head + #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Kelp">"#
            + #"<a:themeElements><a:clrScheme name="Kelp">\#(colours)</a:clrScheme>"#
            + #"<a:fontScheme name="Kelp"><a:majorFont>\#(font)</a:majorFont><a:minorFont>\#(font)</a:minorFont>"#
            + #"</a:fontScheme><a:fmtScheme name="Kelp"><a:fillStyleLst>\#(fill + fill + fill)</a:fillStyleLst>"#
            + "<a:lnStyleLst>\(line + line + line)</a:lnStyleLst>"
            + "<a:effectStyleLst>\(effect + effect + effect)</a:effectStyleLst>"
            + "<a:bgFillStyleLst>\(fill + fill + fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
    }()
}

/// A page's own pictures and styles put inside it, so it is one file: each `src` or stylesheet `href` that names a
/// file in the page's folder (by a relative path) becomes a data URL or a `<style>`.
enum PageInline {
    private static let mimes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
        "webp": "image/webp", "mp4": "video/mp4", "woff2": "font/woff2"
    ]

    static func inline(_ html: String, folder: URL) -> String {
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: ##"(src|href)="([^"#:?]+)""##) } catch { return html }   // fixed
        let out = NSMutableString(string: html), root = folder.standardizedFileURL.path + "/"
        for match in regex.matches(in: html, range: NSRange(location: 0, length: out.length)).reversed() {
            let attr = out.substring(with: match.range(at: 1)), path = out.substring(with: match.range(at: 2))
            let file = folder.appendingPathComponent(path).standardizedFileURL
            guard file.path.hasPrefix(root), let data = FileManager.default.contents(atPath: file.path) else {
                continue
            }
            let ext = file.pathExtension.lowercased()
            if attr == "href", ext == "css" {
                // `<link href="x.css">` becomes the stylesheet itself.
                let start = out.range(
                    of: "<link", options: .backwards, range: NSRange(location: 0, length: match.range.location))
                let rest = match.range.location + match.range.length
                let end = out.range(of: ">", range: NSRange(location: rest, length: out.length - rest))
                guard start.location != NSNotFound, end.location != NSNotFound else { continue }
                let css = "<style>" + String(decoding: data, as: UTF8.self) + "</style>"
                out.replaceCharacters(
                    in: NSRange(location: start.location, length: end.location + 1 - start.location), with: css)
            } else if let mime = mimes[ext] {
                out.replaceCharacters(
                    in: match.range, with: "\(attr)=\"data:\(mime);base64,\(data.base64EncodedString())\"")
            }
        }
        return out as String
    }
}
