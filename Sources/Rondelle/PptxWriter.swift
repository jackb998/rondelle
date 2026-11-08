import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The parts of a PPTX with one picture per slide: a master, a blank layout and a theme of the plainest kind, and
/// a slide for each picture. No author, date or program name is written: a file made here says nothing about who
/// made it. Pictures are encoded again (JPEG, or PNG when they have transparency), so none carries its metadata.
enum PptxWriter {
    private static let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
    private static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
    private static let emptyTree = #"<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>"#
    private static let relsNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let officeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// The longest side of the slide: 960 pt is a 16:9 slide of 13.33 in.
    static let longSide = 960.0

    final class Builder {
        private let folder: URL
        private var pictures: [(file: String, ext: String, size: CGSize, alt: String)] = []

        init(folder: URL) { self.folder = folder }

        /// A slide with this picture. The first picture sets the shape of every slide.
        func add(_ image: CGImage, alt: String) throws {
            let alpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
            let type = alpha ? UTType.png : UTType.jpeg
            let ext = alpha ? "png" : "jpeg"
            let media = folder.appendingPathComponent("ppt/media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let name = "image\(pictures.count + 1).\(ext)"
            let file = media.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil) else {
                throw OpError.failed(L("scrittura di %@", name))
            }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw OpError.failed(L("scrittura di %@", name)) }
            let flat = alt.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
            let clean = String(flat.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(1500))
            pictures.append((name, ext, CGSize(width: image.width, height: image.height), clean.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        func finish(to temp: URL) throws {
            guard let first = pictures.first else { throw OpError.failed(L("nessuna immagine valida")) }
            let k = PptxWriter.longSide / Double(max(first.size.width, first.size.height))
            let slide = CGSize(width: (first.size.width * k).rounded(), height: (first.size.height * k).rounded())
            let emu = { (v: Double) in Int((v * 12700).rounded()) }

            var content = #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/><Default Extension="png" ContentType="image/png"/>"#
            content += #"<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>"#
            content += #"<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>"#
            content += #"<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>"#
            content += #"<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>"#
            for i in 1...pictures.count {
                content += #"<Override PartName="/ppt/slides/slide\#(i).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
            }
            try put(PptxWriter.header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"# + content + "</Types>", "[Content_Types].xml")
            try put(PptxWriter.header + #"<Relationships xmlns="\#(PptxWriter.relsNS)"><Relationship Id="rId1" Type="\#(PptxWriter.officeRel)/officeDocument" Target="ppt/presentation.xml"/></Relationships>"#, "_rels/.rels")

            // Presentation: master rId1, theme rId2, slides rId3….
            var ids = "", rels = #"<Relationship Id="rId1" Type="\#(PptxWriter.officeRel)/slideMaster" Target="slideMasters/slideMaster1.xml"/><Relationship Id="rId2" Type="\#(PptxWriter.officeRel)/theme" Target="theme/theme1.xml"/>"#
            for i in 1...pictures.count {
                ids += #"<p:sldId id="\#(255 + i)" r:id="rId\#(i + 2)"/>"#
                rels += #"<Relationship Id="rId\#(i + 2)" Type="\#(PptxWriter.officeRel)/slide" Target="slides/slide\#(i).xml"/>"#
            }
            try put(PptxWriter.header + #"<p:presentation \#(PptxWriter.ns)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\#(ids)</p:sldIdLst><p:sldSz cx="\#(emu(slide.width))" cy="\#(emu(slide.height))"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#, "ppt/presentation.xml")
            try put(PptxWriter.header + #"<Relationships xmlns="\#(PptxWriter.relsNS)">\#(rels)</Relationships>"#, "ppt/_rels/presentation.xml.rels")

            let map = "bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\""
            try put(PptxWriter.header + #"<p:sldMaster \#(PptxWriter.ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>\#(PptxWriter.emptyTree)</p:spTree></p:cSld><p:clrMap \#(map)/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>"#, "ppt/slideMasters/slideMaster1.xml")
            try put(PptxWriter.header + #"<Relationships xmlns="\#(PptxWriter.relsNS)"><Relationship Id="rId1" Type="\#(PptxWriter.officeRel)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="\#(PptxWriter.officeRel)/theme" Target="../theme/theme1.xml"/></Relationships>"#, "ppt/slideMasters/_rels/slideMaster1.xml.rels")
            try put(PptxWriter.header + #"<p:sldLayout \#(PptxWriter.ns) type="blank" preserve="1"><p:cSld name="Blank">\#(PptxWriter.emptyTree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#, "ppt/slideLayouts/slideLayout1.xml")
            try put(PptxWriter.header + #"<Relationships xmlns="\#(PptxWriter.relsNS)"><Relationship Id="rId1" Type="\#(PptxWriter.officeRel)/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>"#, "ppt/slideLayouts/_rels/slideLayout1.xml.rels")
            try put(PptxWriter.theme, "ppt/theme/theme1.xml")

            for (i, picture) in pictures.enumerated() {
                // As large as the slide allows, centred.
                let k = min(slide.width / picture.size.width, slide.height / picture.size.height)
                let w = picture.size.width * k, h = picture.size.height * k
                let x = (slide.width - w) / 2, y = (slide.height - h) / 2
                let alt = SheetOps.xml(picture.alt)
                let pic = #"<p:pic><p:nvPicPr><p:cNvPr id="2" name="Picture 1" descr="\#(alt)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="\#(emu(x))" y="\#(emu(y))"/><a:ext cx="\#(emu(w))" cy="\#(emu(h))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>"#
                try put(PptxWriter.header + #"<p:sld \#(PptxWriter.ns)><p:cSld>\#(PptxWriter.emptyTree)\#(pic)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#, "ppt/slides/slide\(i + 1).xml")
                try put(PptxWriter.header + #"<Relationships xmlns="\#(PptxWriter.relsNS)"><Relationship Id="rId1" Type="\#(PptxWriter.officeRel)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="\#(PptxWriter.officeRel)/image" Target="../media/\#(picture.file)"/></Relationships>"#, "ppt/slides/_rels/slide\(i + 1).xml.rels")
            }
            try ArchiveOps.pack(folder, to: temp, folderEntries: false)
        }

        private func put(_ text: String, _ path: String) throws {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: false, encoding: .utf8)
        }
    }

    /// A theme of one plain colour scheme and no effects: the master needs one to be a valid file.
    private static let theme: String = {
        func fills(_ n: Int) -> String { String(repeating: #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#, count: n) }
        let line = #"<a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>"#
        let accents = ["4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47"].enumerated()
            .map { "<a:accent\($0.offset + 1)><a:srgbClr val=\"\($0.element)\"/></a:accent\($0.offset + 1)>" }.joined()
        let faces = #"<a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/>"#
        return header + #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Rondelle"><a:themeElements><a:clrScheme name="Rondelle"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>"# + accents
            + #"<a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Rondelle"><a:majorFont>"# + faces
            + "</a:majorFont><a:minorFont>" + faces + #"</a:minorFont></a:fontScheme><a:fmtScheme name="Rondelle"><a:fillStyleLst>"# + fills(3)
            + "</a:fillStyleLst><a:lnStyleLst>" + line + line + line + "</a:lnStyleLst><a:effectStyleLst>"
            + String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3) + "</a:effectStyleLst><a:bgFillStyleLst>" + fills(3)
            + "</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
    }()
}
