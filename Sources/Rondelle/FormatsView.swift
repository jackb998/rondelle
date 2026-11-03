import SwiftUI

/// Settings → Formati: what converts to what, one table per kind of file, built from the convert wheels
/// themselves (so it is never out of date). Click two formats, or a cell, to see if a conversion exists.
struct FormatsPane: View {
    struct Table: Identifiable {
        let title: String
        let symbol: String
        let rows: [String]       // input extensions
        var id: String { title }
    }

    private let tables = [
        Table(title: "Immagini", symbol: "photo.on.rectangle", rows: ["jpg", "png", "heic", "webp", "tiff", "gif", "bmp", "avif", "dng", "cr3", "nef", "arw"]),
        Table(title: "PDF", symbol: "doc.richtext", rows: ["pdf"]),
        Table(title: "Documenti", symbol: "doc.text", rows: ["docx", "doc", "rtf", "rtfd", "odt", "html", "txt", "md", "webarchive", "pages"]),
        Table(title: "Fogli di calcolo", symbol: "tablecells", rows: ["xlsx", "ods", "csv", "tsv", "numbers"]),
        Table(title: "Video", symbol: "film", rows: ["mov", "mp4", "m4v"]),
        Table(title: "Audio", symbol: "waveform", rows: ["mp3", "m4a", "wav", "aiff", "flac", "caf"]),
        Table(title: "Sottotitoli", symbol: "captions.bubble", rows: ["srt", "vtt"]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(L("Clicca un formato di partenza e uno di arrivo (o direttamente una casella): verde se Rondelle sa convertire, rosso se no. Un terzo clic azzera."))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                ForEach(tables) { table in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L(table.title), systemImage: table.symbol).font(.headline)
                        ConversionTable(rows: table.rows)
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct ConversionTable: View {
    let rows: [String]
    private let columns: [String]
    private let possible: [String: Set<String>]

    /// A clicked format: a row (input) or a column (output).
    private enum Pick: Equatable { case row(Int), column(Int) }
    @State private var picks: [Pick] = []
    @State private var hover: (row: Int, column: Int)?

    init(rows: [String]) {
        self.rows = rows
        var columns: [String] = []
        var possible: [String: Set<String>] = [:]
        for ext in rows {
            let targets = ActionCatalog.convertTargets(forExtension: ext)
            possible[ext] = Set(targets)
            // Merge keeping the wheel's order: a missing format goes right after the one before it in this row.
            for (i, t) in targets.enumerated() where !columns.contains(t) {
                let after = i > 0 ? columns.firstIndex(of: targets[i - 1]).map { $0 + 1 } : 0
                columns.insert(t, at: after ?? columns.count)
            }
        }
        self.columns = columns
        self.possible = possible
        #if DEBUG
        // Snapshots: RONDELLE_TABLE_PICK="row,column" (picked cell) and RONDELLE_TABLE_HOVER="row,column".
        let env = ProcessInfo.processInfo.environment
        func pair(_ key: String) -> (Int, Int)? {
            let n = (env[key] ?? "").split(separator: ",").compactMap { Int($0) }
            return n.count == 2 && n[0] < rows.count && n[1] < columns.count ? (n[0], n[1]) : nil
        }
        if let (r, c) = pair("RONDELLE_TABLE_PICK") { _picks = State(initialValue: [.row(r), .column(c)]) }
        if let (r, c) = pair("RONDELLE_TABLE_HOVER") { _hover = State(initialValue: (r, c)) }
        #endif
    }

    private var pickedRow: Int? { picks.compactMap { if case .row(let r) = $0 { return r } else { return nil } }.last }
    private var pickedColumn: Int? { picks.compactMap { if case .column(let c) = $0 { return c } else { return nil } }.last }

    private func can(_ r: Int, _ c: Int) -> Bool { possible[rows[r]]?.contains(columns[c]) ?? false }

    /// First click picks a line; a click on the other axis completes the pair; the next click resets.
    private func tap(_ pick: Pick) {
        if pickedRow != nil, pickedColumn != nil { picks = []; return }
        switch (pick, picks.first) {
        case (.row, .some(.row)), (.column, .some(.column)): picks = [pick]   // same axis: move the choice
        default: picks.append(pick)
        }
    }

    private func background(_ r: Int?, _ c: Int?) -> Color {
        if let r, let c, pickedRow == r, pickedColumn == c { return (can(r, c) ? Color.green : Color.red).opacity(0.28) }
        if let hover, let r, let c, hover.row == r, hover.column == c { return Color.secondary.opacity(0.32) }
        let lineHovered = hover.map { (r != nil && $0.row == r) || (c != nil && $0.column == c) } ?? false
        let linePicked = (r != nil && pickedRow == r) || (c != nil && pickedColumn == c)
        if linePicked { return Color.accentColor.opacity(0.14) }
        if lineHovered { return Color.secondary.opacity(0.12) }
        return .clear
    }

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Image(systemName: "arrow.turn.up.right").foregroundStyle(.tertiary)
                    .frame(width: 92, height: 30)
                    .onTapGesture { picks = [] }
                ForEach(columns.indices, id: \.self) { c in
                    header(columns[c], r: nil, c: c).onTapGesture { tap(.column(c)) }
                }
            }
            ForEach(rows.indices, id: \.self) { r in
                Divider().gridCellColumns(columns.count + 1)
                GridRow {
                    header(FileHints.name(ofExtension: rows[r]), r: r, c: nil)
                        .frame(width: 92)
                        .onTapGesture { tap(.row(r)) }
                    ForEach(columns.indices, id: \.self) { c in
                        cell(r, c)
                    }
                }
            }
        }
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func header(_ title: String, r: Int?, c: Int?) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(Rectangle().fill(background(r, c)))
            .contentShape(Rectangle())
    }

    private func cell(_ r: Int, _ c: Int) -> some View {
        let same = FileHints.name(ofExtension: rows[r]) == columns[c]
        return Group {
            if same {
                Text("–").foregroundStyle(.quaternary)
            } else if can(r, c) {
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Text("–").foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(Rectangle().fill(background(r, c)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hover = (r, c) } else if hover?.row == r && hover?.column == c { hover = nil }
        }
        .onTapGesture {
            if pickedRow == r, pickedColumn == c { picks = [] } else { picks = [.row(r), .column(c)] }
        }
    }
}
