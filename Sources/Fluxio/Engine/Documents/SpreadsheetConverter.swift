import Foundation

/// Una hoja de cálculo en memoria: nombre + filas de texto.
struct Sheet {
    var name: String
    var rows: [[String]]
}

enum SpreadsheetFormat: String, CaseIterable {
    case xlsx, csv, tsv, ods, json, html

    var title: String { rawValue.uppercased() }

    /// Formatos que se pueden abrir como tabla (HTML solo se crea).
    static let sources: [SpreadsheetFormat] = [.xlsx, .csv, .tsv, .ods, .json]

    var symbol: String {
        switch self {
        case .xlsx: return "tablecells"
        case .csv: return "list.bullet.rectangle"
        case .tsv: return "arrow.right.to.line"
        case .ods: return "tablecells.badge.ellipsis"
        case .json: return "curlybraces"
        case .html: return "chevron.left.forwardslash.chevron.right"
        }
    }

    static func detect(_ file: FileInfo) -> SpreadsheetFormat? {
        SpreadsheetFormat(rawValue: file.url.pathExtension.lowercased()).flatMap { sources.contains($0) ? $0 : nil }
    }
}

/// Convierte entre XLSX, CSV, TSV y ODS sin programas externos (solo zip/unzip de macOS).
struct SpreadsheetConverter: Converter {
    let id = "sheet.convert"
    let mode = WheelMode.convert

    func options(for file: FileInfo) -> [WheelOption] {
        guard let source = SpreadsheetFormat.detect(file) else { return [] }
        return SpreadsheetFormat.allCases.filter { $0 != source }.map { format in
            WheelOption(id: "\(id).\(format.rawValue)", providerID: id, title: format.title, symbol: format.symbol,
                        accessibilityLabel: "Convertir a \(format.title)")
        }
    }

    func run(_ option: WheelOption, on file: FileInfo, context: JobContext) throws -> [URL] {
        guard let target = SpreadsheetFormat(rawValue: String(option.id.dropFirst(id.count + 1))),
              let source = SpreadsheetFormat.detect(file) else { throw ConversionError.unsupported }

        let sheets: [Sheet]
        switch source {
        case .csv: sheets = [try DelimitedText.read(file.url, delimiter: nil)]
        case .tsv: sheets = [try DelimitedText.read(file.url, delimiter: "\t")]
        case .xlsx: sheets = try XLSX.read(file.url)
        case .ods: sheets = try ODS.read(file.url)
        case .json: sheets = [try JSONTable.read(file.url)]
        case .html: throw ConversionError.unsupported
        }
        guard !sheets.isEmpty else { throw ConversionError.unreadable(file.url.lastPathComponent) }
        context.report(0.5)
        try context.checkCancelled()

        switch target {
        case .csv, .tsv:
            // Una hoja por archivo: "datos.csv" o, si hay varias, "datos-Ventas.csv", "datos-Gastos.csv"…
            return try sheets.map { sheet in
                let temp = context.temporaryURL(ext: target.rawValue)
                defer { try? FileManager.default.removeItem(at: temp) }
                try DelimitedText.write(sheet, delimiter: target == .csv ? "," : "\t", bom: target == .csv, to: temp)
                let tag = sheets.count > 1 ? safeName(sheet.name) : nil
                return try context.finalize(temp: temp, for: file.url, ext: target.rawValue, tag: tag)
            }
        case .json:
            // Una lista de objetos por hoja: [{"Nombre": "Ana", "Importe": 12.5}, …]
            return try sheets.map { sheet in
                let temp = context.temporaryURL(ext: "json")
                defer { try? FileManager.default.removeItem(at: temp) }
                try JSONTable.write(sheet, to: temp)
                let tag = sheets.count > 1 ? safeName(sheet.name) : nil
                return try context.finalize(temp: temp, for: file.url, ext: "json", tag: tag)
            }
        case .html:
            let temp = context.temporaryURL(ext: "html")
            defer { try? FileManager.default.removeItem(at: temp) }
            try HTMLTable.write(sheets, title: file.url.deletingPathExtension().lastPathComponent, to: temp)
            return [try context.finalize(temp: temp, for: file.url, ext: "html")]
        case .xlsx, .ods:
            let temp = context.temporaryURL(ext: target.rawValue)
            defer { try? FileManager.default.removeItem(at: temp) }
            let fitted = Self.splitLongSheets(sheets)
            if target == .xlsx {
                try XLSX.write(fitted, to: temp, context: context)
            } else {
                try ODS.write(fitted, to: temp, context: context)
            }
            return [try context.finalize(temp: temp, for: file.url, ext: target.rawValue)]
        }
    }

    /// Excel y LibreOffice abren como mucho 1 048 576 filas por hoja: lo que pase de ahí se perdería al abrirlo.
    /// Por eso sigue en hojas nuevas («Datos 2», «Datos 3»…), con la primera fila (los títulos) repetida arriba.
    static let maxRowsPerSheet = 1_048_576

    static func splitLongSheets(_ sheets: [Sheet], limit: Int = maxRowsPerSheet) -> [Sheet] {
        sheets.flatMap { sheet -> [Sheet] in
            guard sheet.rows.count > limit, let header = sheet.rows.first else { return [sheet] }
            var parts = [Sheet(name: sheet.name, rows: Array(sheet.rows[0..<limit]))]
            var start = limit
            while start < sheet.rows.count {
                let end = min(start + limit - 1, sheet.rows.count)   // una fila menos: la de títulos
                parts.append(Sheet(name: "\(sheet.name) \(parts.count + 1)", rows: [header] + sheet.rows[start..<end]))
                start = end
            }
            return parts
        }
    }

    private func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined(separator: "-")
        return cleaned.isEmpty ? "hoja" : cleaned
    }
}

// MARK: - CSV / TSV

enum DelimitedText {
    static func read(_ url: URL, delimiter: Character?) throws -> Sheet {
        guard let data = try? Data(contentsOf: url) else { throw ConversionError.unreadable(url.lastPathComponent) }
        // UTF-8 primero; si falla, la codificación típica de Excel en Windows.
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        // En Europa Excel usa ";" en vez de ",".
        let sep: Character = delimiter ?? {
            let firstLine = text.prefix { $0 != "\n" }
            return firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","
        }()

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        while let c = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return Sheet(name: url.deletingPathExtension().lastPathComponent, rows: rows)
    }

    static func write(_ sheet: Sheet, delimiter: String, bom: Bool, to url: URL) throws {
        var out = bom ? "\u{FEFF}" : ""
        for row in sheet.rows {
            out += row.map { field in
                if delimiter == "\t" {
                    return field.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                }
                let needsQuotes = field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r")
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: delimiter)
            out += "\r\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Ayudantes XML

enum XMLText {
    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }   // quita caracteres de control no válidos en XML
            }
        }
        return out
    }

    /// "123", "-4.5" → número. "007" o "1e5" se quedan como texto para no perder ceros ni formato.
    static func isNumber(_ s: String) -> Bool {
        s.range(of: #"^-?(0|[1-9][0-9]{0,14})(\.[0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// Lee un archivo de dentro de un ZIP (xlsx/ods/docx son ZIP por dentro).
    static func entry(_ path: String, in zip: URL) -> Data? {
        let data = try? ExternalTool.captureData(ExternalTool.system.unzip, arguments: ["-p", zip.path, path])
        return (data?.isEmpty ?? true) ? nil : data
    }

    /// Crea un ZIP a partir de los archivos de una carpeta. `storedFirst` va primero y sin comprimir (lo exige ODS).
    static func zipFolder(_ folder: URL, to output: URL, storedFirst: String? = nil, context: JobContext) throws {
        let zip = ExternalTool.system.zip
        if let storedFirst {
            try ExternalTool.run(zip, arguments: ["-X", "-0", "-q", output.path, storedFirst], context: context,
                                 currentDirectory: folder)
        }
        let items = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != storedFirst }
        try ExternalTool.run(zip, arguments: ["-X", "-r", "-q", output.path] + items, context: context,
                             currentDirectory: folder)
    }

    static func write(_ files: [String: String], into folder: URL) throws {
        for (path, content) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Lector XML genérico basado en eventos (para no repetir el boilerplate de XMLParser).
final class XMLEvents: NSObject, XMLParserDelegate {
    var onStart: (String, [String: String]) -> Void = { _, _ in }
    var onEnd: (String) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }

    func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) { onStart(name, attributes) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { onEnd(name) }
    func parser(_ parser: XMLParser, foundCharacters string: String) { onText(string) }
}

// MARK: - XLSX

enum XLSX {
    static func read(_ url: URL) throws -> [Sheet] {
        guard let workbook = XMLText.entry("xl/workbook.xml", in: url) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }

        // Nombres de las hojas y a qué archivo apunta cada una.
        var sheetRefs: [(name: String, rid: String)] = []
        let wb = XMLEvents()
        wb.onStart = { name, attrs in
            if name == "sheet", let n = attrs["name"], let rid = attrs["r:id"] { sheetRefs.append((n, rid)) }
        }
        wb.parse(workbook)

        var targets: [String: String] = [:]
        if let rels = XMLText.entry("xl/_rels/workbook.xml.rels", in: url) {
            let r = XMLEvents()
            r.onStart = { name, attrs in
                if name == "Relationship", let id = attrs["Id"], let target = attrs["Target"] { targets[id] = target }
            }
            r.parse(rels)
        }

        // Textos compartidos.
        var shared: [String] = []
        if let sst = XMLText.entry("xl/sharedStrings.xml", in: url) {
            let p = XMLEvents()
            var current = "", inT = false, inPhonetic = false
            p.onStart = { name, _ in
                if name == "si" { current = "" }
                if name == "t" { inT = true }
                if name == "rPh" { inPhonetic = true }
            }
            p.onText = { if inT && !inPhonetic { current += $0 } }
            p.onEnd = { name in
                if name == "t" { inT = false }
                if name == "rPh" { inPhonetic = false }
                if name == "si" { shared.append(current) }
            }
            p.parse(sst)
        }

        return sheetRefs.enumerated().compactMap { index, ref in
            var path = targets[ref.rid] ?? "worksheets/sheet\(index + 1).xml"
            if path.hasPrefix("/") { path.removeFirst() } else { path = "xl/" + path }
            guard let data = XMLText.entry(path, in: url) else { return nil }
            return Sheet(name: ref.name, rows: readSheet(data, shared: shared))
        }
    }

    private static func readSheet(_ data: Data, shared: [String]) -> [[String]] {
        var rows: [Int: [Int: String]] = [:]
        var rowIndex = 0, col = 0, nextCol = 0
        var type = "", value = "", inValue = false
        let p = XMLEvents()
        p.onStart = { name, attrs in
            switch name {
            case "row":
                rowIndex = (Int(attrs["r"] ?? "") ?? (rowIndex + 1))
                nextCol = 0
            case "c":
                col = attrs["r"].map(columnIndex) ?? nextCol
                nextCol = col + 1
                type = attrs["t"] ?? "n"
                value = ""
            case "v", "t":
                inValue = true
            default: break
            }
        }
        p.onText = { if inValue { value += $0 } }
        p.onEnd = { name in
            switch name {
            case "v", "t": inValue = false
            case "c":
                var text = value
                if type == "s", let i = Int(value), shared.indices.contains(i) { text = shared[i] }
                if type == "b" { text = value == "1" ? "VERDADERO" : "FALSO" }
                if !text.isEmpty { rows[rowIndex, default: [:]][col] = text }
            default: break
            }
        }
        p.parse(data)

        guard let maxRow = rows.keys.max() else { return [] }
        let maxCol = rows.values.flatMap(\.keys).max() ?? 0
        return (1...maxRow).map { r in (0...maxCol).map { rows[r]?[$0] ?? "" } }
    }

    /// "B12" → 1 (columna B, contando desde 0).
    private static func columnIndex(_ ref: String) -> Int {
        var n = 0
        for c in ref.uppercased() {
            guard let a = c.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
        }
        return max(0, n - 1)
    }

    private static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    static func write(_ sheets: [Sheet], to url: URL, context: JobContext) throws {
        let folder = context.temporaryURL(ext: "xlsxdir")
        defer { try? FileManager.default.removeItem(at: folder) }

        var files: [String: String] = [:]
        var overrides = "", sheetEntries = "", rels = ""
        var usedNames = Set<String>()
        for (i, sheet) in sheets.enumerated() {
            let n = i + 1
            // Excel limita los nombres a 31 caracteres, sin : \ / ? * [ ] y sin repetir.
            var name = String(sheet.name.components(separatedBy: CharacterSet(charactersIn: ":\\/?*[]")).joined().prefix(31))
            if name.isEmpty || usedNames.contains(name) { name = "Hoja\(n)" }
            usedNames.insert(name)

            overrides += #"<Override PartName="/xl/worksheets/sheet\#(n).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            sheetEntries += #"<sheet name="\#(XMLText.escape(name))" sheetId="\#(n)" r:id="rId\#(n)"/>"#
            rels += #"<Relationship Id="rId\#(n)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(n).xml"/>"#

            var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
            for (r, row) in sheet.rows.enumerated() {
                xml += #"<row r="\#(r + 1)">"#
                for (c, cell) in row.enumerated() where !cell.isEmpty {
                    let ref = columnName(c) + String(r + 1)
                    if XMLText.isNumber(cell) {
                        xml += #"<c r="\#(ref)"><v>\#(cell)</v></c>"#
                    } else {
                        xml += #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(XMLText.escape(cell))</t></is></c>"#
                    }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            files["xl/worksheets/sheet\(n).xml"] = xml
        }

        files["[Content_Types].xml"] = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\#(overrides)</Types>"#
        files["_rels/.rels"] = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
        files["xl/workbook.xml"] = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\#(sheetEntries)</sheets></workbook>"#
        files["xl/_rels/workbook.xml.rels"] = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(rels)</Relationships>"#

        try XMLText.write(files, into: folder)
        try XMLText.zipFolder(folder, to: url, context: context)
    }
}

// MARK: - ODS (LibreOffice / OpenOffice)

enum ODS {
    static func read(_ url: URL) throws -> [Sheet] {
        guard let content = XMLText.entry("content.xml", in: url) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        var sheets: [Sheet] = []
        var rows: [[String]] = []
        var row: [String] = []
        var cellText = "", paragraphs: [String] = []
        var cellValue: String?
        var repeatCols = 1, repeatRows = 1
        var inParagraph = false, inCell = false

        let p = XMLEvents()
        p.onStart = { name, attrs in
            switch name {
            case "table:table":
                rows = []
                sheets.append(Sheet(name: attrs["table:name"] ?? "Hoja\(sheets.count + 1)", rows: []))
            case "table:table-row":
                row = []
                repeatRows = min(Int(attrs["table:number-rows-repeated"] ?? "1") ?? 1, 10_000)
            case "table:table-cell", "table:covered-table-cell":
                inCell = true
                paragraphs = []
                cellValue = attrs["office:value-type"] == "float" ? attrs["office:value"] : nil
                repeatCols = min(Int(attrs["table:number-columns-repeated"] ?? "1") ?? 1, 10_000)
            case "text:p":
                inParagraph = true; cellText = ""
            case "text:s":
                if inParagraph { cellText += String(repeating: " ", count: Int(attrs["text:c"] ?? "1") ?? 1) }
            case "text:tab":
                if inParagraph { cellText += "\t" }
            case "text:line-break":
                if inParagraph { cellText += "\n" }
            default: break
            }
        }
        p.onText = { if inParagraph && inCell { cellText += $0 } }
        p.onEnd = { name in
            switch name {
            case "text:p":
                inParagraph = false; paragraphs.append(cellText)
            case "table:table-cell", "table:covered-table-cell":
                inCell = false
                let text = cellValue ?? paragraphs.joined(separator: "\n")
                row += Array(repeating: text, count: repeatCols)
            case "table:table-row":
                // LibreOffice "rellena" con miles de celdas vacías: las quitamos.
                while row.last == "" { row.removeLast() }
                rows += Array(repeating: row, count: row.isEmpty ? min(repeatRows, 1) : repeatRows)
            case "table:table":
                while rows.last?.isEmpty == true { rows.removeLast() }
                sheets[sheets.count - 1].rows = rows
            default: break
            }
        }
        p.parse(content)
        return sheets
    }

    static func write(_ sheets: [Sheet], to url: URL, context: JobContext) throws {
        let folder = context.temporaryURL(ext: "odsdir")
        defer { try? FileManager.default.removeItem(at: folder) }

        var body = ""
        for sheet in sheets {
            body += #"<table:table table:name="\#(XMLText.escape(sheet.name))">"#
            for row in sheet.rows {
                body += "<table:table-row>"
                for cell in row {
                    if cell.isEmpty {
                        body += "<table:table-cell/>"
                    } else if XMLText.isNumber(cell) {
                        body += #"<table:table-cell office:value-type="float" office:value="\#(cell)"><text:p>\#(cell)</text:p></table:table-cell>"#
                    } else {
                        let paragraphs = cell.components(separatedBy: "\n").map { "<text:p>\(XMLText.escape($0))</text:p>" }.joined()
                        body += #"<table:table-cell office:value-type="string">\#(paragraphs)</table:table-cell>"#
                    }
                }
                body += "</table:table-row>"
            }
            body += "</table:table>"
        }

        let files: [String: String] = [
            "mimetype": "application/vnd.oasis.opendocument.spreadsheet",
            "META-INF/manifest.xml": #"<?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>"#,
            "content.xml": #"<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet>\#(body)</office:spreadsheet></office:body></office:document-content>"#,
        ]
        try XMLText.write(files, into: folder)
        // "mimetype" sin salto de línea final: String.write no añade ninguno.
        try XMLText.zipFolder(folder, to: url, storedFirst: "mimetype", context: context)
    }
}

// MARK: - JSON y HTML

/// JSON ↔ tabla. La primera fila de la tabla son los nombres de las columnas.
enum JSONTable {
    static func read(_ url: URL) throws -> Sheet {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ConversionError.unreadable(url.lastPathComponent)
        }
        let name = url.deletingPathExtension().lastPathComponent
        // Lista de objetos → columnas = todas las claves, en el orden en que aparecen.
        if let objects = json as? [[String: Any]], !objects.isEmpty {
            var headers: [String] = []
            for object in objects {
                for key in orderedKeys(object, data: data) where !headers.contains(key) { headers.append(key) }
            }
            let rows = objects.map { object in headers.map { text(object[$0]) } }
            return Sheet(name: name, rows: [headers] + rows)
        }
        // Lista de listas → filas tal cual.
        if let arrays = json as? [[Any]] {
            return Sheet(name: name, rows: arrays.map { $0.map { text($0) } })
        }
        throw ConversionError.message("Este JSON no es una tabla (debe ser una lista de objetos o de listas). "
                                      + "Prueba a convertirlo a Plist.")
    }

    /// JSONSerialization no conserva el orden de las claves: lo recuperamos del texto original.
    private static func orderedKeys(_ object: [String: Any], data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        return object.keys.sorted { a, b in
            let ra = text.range(of: "\"\(a)\"")?.lowerBound ?? text.endIndex
            let rb = text.range(of: "\"\(b)\"")?.lowerBound ?? text.endIndex
            return ra < rb
        }
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let other?:
            // Objetos o listas dentro de una celda: se guardan como JSON.
            if let data = try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(other)"
        }
    }

    static func write(_ sheet: Sheet, to url: URL) throws {
        guard let headers = sheet.rows.first else { throw ConversionError.message("La hoja está vacía.") }
        let names = headers.enumerated().map { i, h in h.isEmpty ? "columna\(i + 1)" : h }
        var objects: [[String: Any]] = []
        for row in sheet.rows.dropFirst() where row.contains(where: { !$0.isEmpty }) {
            var object: [String: Any] = [:]
            for (i, name) in names.enumerated() {
                let value = i < row.count ? row[i] : ""
                object[name] = XMLText.isNumber(value) ? (Double(value) ?? 0) as Any : value
            }
            objects.append(object)
        }
        // Escribimos a mano para respetar el orden de las columnas.
        var out = "[\n"
        for (n, object) in objects.enumerated() {
            let fields = names.map { name -> String in
                let key = jsonString(name)
                if let number = object[name] as? Double {
                    return "    \(key): \(number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number))"
                }
                return "    \(key): \(jsonString(object[name] as? String ?? ""))"
            }
            out += "  {\n" + fields.joined(separator: ",\n") + "\n  }" + (n < objects.count - 1 ? "," : "") + "\n"
        }
        out += "]\n"
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

/// Tabla en una página web sencilla (todas las hojas en el mismo archivo).
enum HTMLTable {
    static func write(_ sheets: [Sheet], title: String, to url: URL) throws {
        func esc(_ s: String) -> String { PDFText.escape(s).replacingOccurrences(of: "\n", with: "<br>") }
        var body = ""
        for sheet in sheets {
            if sheets.count > 1 { body += "<h2>\(esc(sheet.name))</h2>\n" }
            body += "<table>\n"
            for (i, row) in sheet.rows.enumerated() {
                let tag = i == 0 ? "th" : "td"
                body += "<tr>" + row.map { "<\(tag)>\(esc($0))</\(tag)>" }.joined() + "</tr>\n"
            }
            body += "</table>\n"
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title><style>
        body { font-family: -apple-system, sans-serif; margin: 24px; }
        table { border-collapse: collapse; margin-bottom: 24px; }
        th, td { border: 1px solid #ccc; padding: 4px 10px; text-align: left; }
        th { background: #f2f2f2; }
        </style></head><body>
        \(body)</body></html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
    }
}
