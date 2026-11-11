import Foundation

/// A Numbers file → its tables as `SheetOps.Sheet` (values only, as for Excel files: the text, numbers, dates and
/// durations that cells hold, formulas give their last result; styles, charts, merged cells and pictures are not read).
///
/// The sheets are in `Index/Document.iwa`; every table has a model (`TST.TableModelArchive`) whose tiles hold
/// the cells in a packed binary form (version 5 of Apple's `TSTCellStorage`) and whose string table holds the texts.
/// Layouts are those of Apple's own `TNArchives` and `TSTArchives`.
enum NumbersReader {
    typealias PB = PagesWriter.PB
    private typealias Objects = IWorkFile.Objects

    static func read(_ file: URL) throws -> [SheetOps.Sheet] {
        let app = "Numbers"
        let bad = IWorkFile.unreadable(app)
        let objects = try IWorkFile.objects(of: file, app: app) { _ in true }
        guard let document = objects.first(where: { $0.value.type == 1 }) else { throw bad }
        let sheetIDs = IWorkFile.refs(IWorkFile.fields(document.value.payload), 1)
        guard !sheetIDs.isEmpty else { throw bad }

        var result: [SheetOps.Sheet] = []
        var budget = SheetOps.maxCells
        for sheetID in sheetIDs {
            guard let sheet = objects[sheetID], sheet.type == 2 else { continue }
            let fields = IWorkFile.fields(sheet.payload)
            let sheetName = IWorkFile.string(fields, 1) ?? ""
            var tables: [(name: String, rows: [[String]])] = []
            for infoID in IWorkFile.refs(fields, 2) {
                try PDFOps.checkCancelled()
                guard let info = objects[infoID], info.type == 6000,
                      let modelID = IWorkFile.ref(IWorkFile.fields(info.payload), 2), let model = objects[modelID], model.type == 6001,
                      let table = try table(IWorkFile.fields(model.payload), objects, budget: &budget) else { continue }
                tables.append(table)
            }
            for entry in tables {
                let name = tables.count > 1 ? (sheetName.isEmpty ? entry.name : "\(sheetName) - \(entry.name)") : (sheetName.isEmpty ? entry.name : sheetName)
                result.append(SheetOps.Sheet(name: name, rows: entry.rows))
            }
        }
        guard !result.isEmpty else { throw bad }
        guard result.count <= SheetOps.maxSheets else { throw SheetOps.tooManySheets }
        return result
    }

    // MARK: A table

    private static func table(_ model: [PB.Field], _ objects: Objects, budget: inout Int) throws -> (name: String, rows: [[String]])? {
        let name = IWorkFile.string(model, 8) ?? "Table"
        let rowCount = Int(clamping: model.first { $0.num == 6 }?.value ?? 0), columnCount = Int(clamping: model.first { $0.num == 7 }?.value ?? 0)
        guard rowCount > 0, columnCount > 0, let store = IWorkFile.message(model, 4) else { return nil }
        let product = rowCount.multipliedReportingOverflow(by: columnCount)
        guard !product.overflow, product.partialValue <= budget else {
            throw OpError.unsupported(L("il foglio di calcolo ha troppe celle"))
        }

        // The texts: key → string.
        var strings: [UInt64: String] = [:]
        if let listID = IWorkFile.ref(store, 4), let list = objects[listID] {
            for entry in IWorkFile.fields(list.payload) where entry.num == 3 && entry.wire == 2 {
                let parts = IWorkFile.fields(entry.data)
                if let key = parts.first(where: { $0.num == 1 })?.value, let text = IWorkFile.string(parts, 3) { strings[key] = text }
            }
        }
        // Rich texts: key → the text of the storage.
        var rich: [UInt64: String] = [:]
        if let listID = IWorkFile.ref(store, 17), let list = objects[listID] {
            for entry in IWorkFile.fields(list.payload) where entry.num == 3 && entry.wire == 2 {
                let parts = IWorkFile.fields(entry.data)
                guard let key = parts.first(where: { $0.num == 1 })?.value, let payload = IWorkFile.ref(parts, 9),
                      let storage = objects[payload] else { continue }
                rich[key] = IWorkFile.fields(storage.payload).filter { $0.num == 3 && $0.wire == 2 }
                    .map { String(decoding: $0.data, as: UTF8.self) }.joined()
            }
        }

        let tileSize = Int(clamping: IWorkFile.message(store, 3)?.first { $0.num == 2 }?.value ?? 256)
        guard tileSize > 0, tileSize <= 65536 else { return nil }
        var grid: [Int: [Int: String]] = [:]
        var lastRow = -1, lastColumn = -1
        for tileEntry in IWorkFile.message(store, 3)?.filter({ $0.num == 1 && $0.wire == 2 }) ?? [] {
            let entry = IWorkFile.fields(tileEntry.data)
            guard let tileID = entry.first(where: { $0.num == 1 })?.value, let tileRef = IWorkFile.ref(entry, 2),
                  let tile = objects[tileRef], tile.type == 6002 else { continue }
            for rowField in IWorkFile.fields(tile.payload) where rowField.num == 5 && rowField.wire == 2 {
                let row = IWorkFile.fields(rowField.data)
                guard let indexInTile = row.first(where: { $0.num == 1 })?.value else { continue }
                guard tileID < 1_000_000, indexInTile < 1_000_000 else { continue }
                let rowIndex = Int(tileID) * tileSize + Int(indexInTile)
                guard rowIndex < rowCount else { continue }
                let buffer = row.first { $0.num == 6 }?.data ?? [], offsets = row.first { $0.num == 7 }?.data ?? []
                let wide = row.first { $0.num == 8 }?.value == 1
                guard !buffer.isEmpty, offsets.count >= 2 else { continue }
                for column in 0..<min(offsets.count / 2, columnCount) {
                    let raw = Int(offsets[2 * column]) | Int(offsets[2 * column + 1]) << 8
                    if raw == 0xFFFF { continue }
                    let offset = wide ? raw * 4 : raw
                    guard let value = cell(buffer, at: offset, strings: strings, rich: rich), !value.isEmpty else { continue }
                    grid[rowIndex, default: [:]][column] = value
                    lastRow = max(lastRow, rowIndex); lastColumn = max(lastColumn, column)
                }
            }
        }
        guard lastRow >= 0 else { return (name, []) }
        budget -= (lastRow + 1) * (lastColumn + 1)
        let rows = (0...lastRow).map { r in (0...lastColumn).map { c in grid[r]?[c] ?? "" } }
        return (name, rows)
    }

    // MARK: A cell

    /// The text of the cell stored at `offset`: version 5, a type byte, 6 bytes, the flags (4 bytes), then the
    /// values the flags announce, in the order of their bits.
    private static func cell(_ buffer: [UInt8], at offset: Int, strings: [UInt64: String], rich: [UInt64: String]) -> String? {
        guard offset >= 0, offset + 12 <= buffer.count, buffer[offset] == 5 else { return nil }
        let type = buffer[offset + 1]
        let flags = UInt32(buffer[offset + 8]) | UInt32(buffer[offset + 9]) << 8 | UInt32(buffer[offset + 10]) << 16 | UInt32(buffer[offset + 11]) << 24
        var at = offset + 12
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard at + n <= buffer.count else { return nil }
            defer { at += n }
            return buffer[at..<(at + n)]
        }
        func u32(_ bytes: ArraySlice<UInt8>) -> UInt64 { bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) } }
        var decimal: ArraySlice<UInt8>?, double: Double?, key: UInt64?, richKey: UInt64?
        if flags & 0x1 != 0 { decimal = take(16) }
        if flags & 0x2 != 0 { guard let b = take(8) else { return nil }; double = Double(bitPattern: u32(b.prefix(4)) | u32(b.suffix(4)) << 32) }
        if flags & 0x4 != 0 { guard let b = take(8) else { return nil }; double = Double(bitPattern: u32(b.prefix(4)) | u32(b.suffix(4)) << 32) }
        if flags & 0x8 != 0 { guard let b = take(4) else { return nil }; key = u32(b) }
        if flags & 0x10 != 0 { guard let b = take(4) else { return nil }; richKey = u32(b) }

        switch type {
        case 0: return nil
        case 3: return key.flatMap { strings[$0] }
        case 9: return richKey.flatMap { rich[$0] } ?? key.flatMap { strings[$0] }
        case 2, 7:   // number, duration (seconds)
            if let decimal { return decimalText(decimal) }
            return double.map(numberText)
        case 5:      // date: seconds since 2001-01-01
            guard let seconds = double, seconds.isFinite, abs(seconds) < 1e12 else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = seconds.truncatingRemainder(dividingBy: 86_400) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
        case 6:      // boolean
            if let decimal { return decimalText(decimal) == "0" ? "FALSE" : "TRUE" }
            return double.map { $0 == 0 ? "FALSE" : "TRUE" }
        default: return nil
        }
    }

    private static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.15g", value)
    }

    /// IEEE 754 decimal128 (binary integer coefficient, little endian): 49 bits of coefficient in the high half.
    private static func decimalText(_ bytes: ArraySlice<UInt8>) -> String? {
        let b = Array(bytes)
        guard b.count == 16 else { return nil }
        var low: UInt64 = 0, high: UInt64 = 0
        for i in 0..<8 { low |= UInt64(b[i]) << UInt64(8 * i); high |= UInt64(b[8 + i]) << UInt64(8 * i) }
        let negative = high >> 63 == 1
        let exponent = Int((high >> 49) & 0x3FFF) - 6176
        let top = high & ((1 << 49) - 1)
        guard top == 0 else {   // more than 19 digits: through Double
            let value = (Double(low) + Double(top) * 18_446_744_073_709_551_616) * pow(10, Double(exponent))
            return numberText(negative ? -value : value)
        }
        var digits = String(low)
        if exponent >= 0 {
            if low != 0 { digits += String(repeating: "0", count: min(exponent, 400)) }
        } else {
            let places = -exponent
            if places > 400 { return numberText(Double(low) * pow(10, Double(exponent))) }
            if digits.count <= places { digits = String(repeating: "0", count: places - digits.count + 1) + digits }
            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -places))
            while digits.hasSuffix("0") { digits.removeLast() }
            if digits.hasSuffix(".") { digits.removeLast() }
        }
        return (negative && digits != "0" ? "-" : "") + digits
    }
}
