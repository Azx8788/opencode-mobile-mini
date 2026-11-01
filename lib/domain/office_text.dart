import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// Reading Office files as text, so they can be attached to a prompt.
///
/// A model accepts images, PDFs and text. A workbook or a Word document is
/// neither: it is a ZIP of XML. Rather than refuse the file, the app opens it
/// on the device and attaches what it says: every sheet as CSV, a document as
/// its paragraphs. Formatting, charts and formulas' definitions are left
/// behind; values and words are what an agent can use.
class OfficeText {
  const OfficeText({
    required this.text,
    required this.sections,
    required this.lines,
    required this.truncated,
  });

  final String text;

  /// Sheets in a workbook; 1 for a document.
  final int sections;

  /// Rows across all sheets, or paragraphs in a document.
  final int lines;

  /// True when the file held more than [maxOfficeTextLength] and was cut.
  final bool truncated;
}

/// Enough for a large sheet, small enough to fit a prompt.
const maxOfficeTextLength = 400000;

bool isOfficeDocument(String filename) {
  final name = filename.toLowerCase();
  return name.endsWith('.xlsx') ||
      name.endsWith('.xlsm') ||
      name.endsWith('.docx');
}

/// The text of [bytes], or a [FormatException] when the file is not a
/// readable workbook or document (encrypted, damaged, or the older binary
/// `.xls`/`.doc`, which only share the name).
OfficeText officeDocumentAsText(String filename, Uint8List bytes) {
  final files = _unzip(bytes);
  final name = filename.toLowerCase();
  return name.endsWith('.docx') ? _document(files) : _workbook(files);
}

// ---- ZIP -------------------------------------------------------------------

/// The entries of a ZIP archive, by path. Reads the central directory, so
/// entries written with data descriptors (as Excel writes them) are fine.
Map<String, Uint8List> _unzip(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  // End of central directory: signature, then a fixed 22 bytes and a comment.
  var end = -1;
  for (var i = bytes.length - 22; i >= 0 && i >= bytes.length - 66000; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      end = i;
      break;
    }
  }
  if (end < 0) throw const FormatException('Not a ZIP archive');
  final count = data.getUint16(end + 10, Endian.little);
  var at = data.getUint32(end + 16, Endian.little);
  final files = <String, Uint8List>{};
  for (var n = 0; n < count; n++) {
    if (at + 46 > bytes.length ||
        data.getUint32(at, Endian.little) != 0x02014b50) {
      throw const FormatException('Damaged ZIP directory');
    }
    final flags = data.getUint16(at + 8, Endian.little);
    final method = data.getUint16(at + 10, Endian.little);
    final packed = data.getUint32(at + 20, Endian.little);
    final nameLength = data.getUint16(at + 28, Endian.little);
    final extraLength = data.getUint16(at + 30, Endian.little);
    final commentLength = data.getUint16(at + 32, Endian.little);
    final local = data.getUint32(at + 42, Endian.little);
    final path = utf8.decode(
      bytes.sublist(at + 46, at + 46 + nameLength),
      allowMalformed: true,
    );
    at += 46 + nameLength + extraLength + commentLength;
    if (flags & 1 != 0) throw const FormatException('Password protected');
    // Only the parts that are read are worth inflating.
    if (!path.endsWith('.xml') && !path.endsWith('.rels')) continue;
    if (local + 30 > bytes.length) {
      throw const FormatException('Damaged ZIP entry');
    }
    final start =
        local +
        30 +
        data.getUint16(local + 26, Endian.little) +
        data.getUint16(local + 28, Endian.little);
    if (start + packed > bytes.length) {
      throw const FormatException('Damaged ZIP entry');
    }
    final raw = Uint8List.sublistView(bytes, start, start + packed);
    files[path] = switch (method) {
      0 => raw,
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(raw)),
      _ => throw const FormatException('Unsupported ZIP compression'),
    };
  }
  return files;
}

XmlDocument _xml(Uint8List bytes) =>
    XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));

// ---- XLSX ------------------------------------------------------------------

OfficeText _workbook(Map<String, Uint8List> files) {
  final workbook = files['xl/workbook.xml'];
  if (workbook == null) throw const FormatException('Not a workbook');

  final shared = <String>[];
  if (files['xl/sharedStrings.xml'] case final bytes?) {
    for (final item in _xml(bytes).findAllElements('si')) {
      // Rich text is several runs; phonetic guides (rPh) are not the text.
      shared.add(
        item.descendants
            .whereType<XmlElement>()
            .where(
              (e) =>
                  e.name.local == 't' &&
                  !e.ancestors.whereType<XmlElement>().any(
                    (a) => a.name.local == 'rPh',
                  ),
            )
            .map((e) => e.innerText)
            .join(),
      );
    }
  }

  // Sheet names live in the workbook; their files are found through rels.
  final targets = <String, String>{};
  if (files['xl/_rels/workbook.xml.rels'] case final bytes?) {
    for (final rel in _xml(bytes).findAllElements('Relationship')) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id != null && target != null) {
        targets[id] = target.startsWith('/')
            ? target.substring(1)
            : 'xl/$target';
      }
    }
  }

  final out = StringBuffer();
  var sheets = 0;
  var rows = 0;
  var truncated = false;
  for (final sheet in _xml(workbook).findAllElements('sheet')) {
    final name = sheet.getAttribute('name') ?? 'Sheet ${sheets + 1}';
    final rel = sheet.attributes
        .where((a) => a.name.local == 'id' && a.name.prefix != null)
        .map((a) => a.value)
        .firstOrNull;
    final bytes =
        files[targets[rel]] ?? files['xl/worksheets/sheet${sheets + 1}.xml'];
    sheets++;
    if (bytes == null) continue;
    if (out.isNotEmpty) out.writeln();
    out.writeln('# Sheet: $name');
    for (final row in _xml(bytes).findAllElements('row')) {
      final cells = <int, String>{};
      var next = 0;
      for (final cell in row.findElements('c')) {
        final column = _column(cell.getAttribute('r')) ?? next;
        next = column + 1;
        final value = _cell(cell, shared);
        if (value.isNotEmpty) cells[column] = value;
      }
      if (cells.isEmpty) continue;
      final width = cells.keys.reduce((a, b) => a > b ? a : b) + 1;
      out.writeln(
        [for (var i = 0; i < width; i++) _csv(cells[i] ?? '')].join(','),
      );
      rows++;
      if (out.length > maxOfficeTextLength) {
        truncated = true;
        break;
      }
    }
    if (truncated) break;
  }
  if (sheets == 0) throw const FormatException('The workbook has no sheets');
  return OfficeText(
    text: out.toString().trimRight(),
    sections: sheets,
    lines: rows,
    truncated: truncated,
  );
}

/// "BC12" -> 54 (zero-based column).
int? _column(String? reference) {
  if (reference == null) return null;
  var column = 0;
  var letters = 0;
  for (final unit in reference.codeUnits) {
    final upper = unit >= 97 && unit <= 122 ? unit - 32 : unit;
    if (upper < 65 || upper > 90) break;
    column = column * 26 + (upper - 64);
    letters++;
  }
  return letters == 0 ? null : column - 1;
}

String _cell(XmlElement cell, List<String> shared) {
  final type = cell.getAttribute('t');
  if (type == 'inlineStr') {
    return cell.findAllElements('t').map((e) => e.innerText).join();
  }
  final value = cell.getElement('v')?.innerText ?? '';
  return switch (type) {
    's' => shared.elementAtOrNull(int.tryParse(value) ?? -1) ?? '',
    'b' => value == '1' ? 'TRUE' : 'FALSE',
    _ => value,
  };
}

String _csv(String value) => value.contains(RegExp(r'[",\n\r]'))
    ? '"${value.replaceAll('"', '""')}"'
    : value;

// ---- DOCX ------------------------------------------------------------------

OfficeText _document(Map<String, Uint8List> files) {
  final body = files['word/document.xml'];
  if (body == null) throw const FormatException('Not a document');
  final out = StringBuffer();
  var paragraphs = 0;
  var truncated = false;
  for (final paragraph in _xml(body).findAllElements('w:p')) {
    final line = StringBuffer();
    for (final node in paragraph.descendants.whereType<XmlElement>()) {
      switch (node.name.qualified) {
        case 'w:t':
          line.write(node.innerText);
        case 'w:tab':
          line.write('\t');
        case 'w:br':
          line.write('\n');
      }
    }
    final text = line.toString().trimRight();
    if (text.isEmpty) continue;
    out.writeln(text);
    out.writeln();
    paragraphs++;
    if (out.length > maxOfficeTextLength) {
      truncated = true;
      break;
    }
  }
  return OfficeText(
    text: out.toString().trimRight(),
    sections: 1,
    lines: paragraphs,
    truncated: truncated,
  );
}
