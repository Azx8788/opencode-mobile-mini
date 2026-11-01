import 'package:flutter/widgets.dart';

import '../../domain/delimited_text.dart';
import '../../l10n/app_localizations.dart';
import '../kit/kit_viewer.dart';
import 'file_preview.dart';

/// Why a CSV or TSV file shows its source instead of a table.
enum DelimitedNotice { malformed, tooLarge, tooWide, fieldTooLong }

/// What the kit viewer shows for a CSV or TSV file: an inert table with its
/// [original] text behind Show source and Copy, or the source itself (with
/// the reason) when the table cannot be trusted. A partial file never
/// becomes a table: a cut-off row would read as data.
({KitViewerContent content, DelimitedNotice? notice}) delimitedViewerContent(
  String text, {
  required String original,
  required String separator,
  bool truncated = false,
}) {
  if (truncated) {
    return (
      content: KitViewerContent.text(
        capPreviewSource(text).text,
        truncated: true,
      ),
      notice: null,
    );
  }
  final table = DelimitedText.parse(text, separator);
  final failure = table.failure;
  if (failure != null) {
    final source = capPreviewSource(text);
    return (
      content: KitViewerContent.text(source.text, truncated: source.cut),
      notice: switch (failure) {
        DelimitedFailure.malformed => DelimitedNotice.malformed,
        DelimitedFailure.tooLarge => DelimitedNotice.tooLarge,
        DelimitedFailure.tooWide => DelimitedNotice.tooWide,
        DelimitedFailure.fieldTooLong => DelimitedNotice.fieldTooLong,
      },
    );
  }
  return (
    content: KitViewerContent.delimited(
      table.rows,
      original: original,
      truncated: table.hasMore,
    ),
    notice: null,
  );
}

/// The person's words for a [DelimitedNotice].
String delimitedNoticeText(AppLocalizations l10n, DelimitedNotice notice) =>
    switch (notice) {
      DelimitedNotice.malformed => l10n.fileTableMalformed,
      DelimitedNotice.tooLarge => l10n.fileTableTooLarge,
      DelimitedNotice.tooWide => l10n.fileTableTooWide,
      DelimitedNotice.fieldTooLong => l10n.fileTableFieldTooLong,
    };

/// A CSV or TSV file in a host that has its own header: the table (or its
/// source, with the reason) with Table and Source above it.
class DelimitedFilePreview extends StatelessWidget {
  const DelimitedFilePreview({
    super.key,
    required this.text,
    required this.original,
    required this.separator,
    this.truncated = false,
    this.name,
  });

  final String text;
  final String original;
  final String separator;
  final bool truncated;

  /// The file's name; defaults to one that carries [separator]'s type.
  final String? name;

  @override
  Widget build(BuildContext context) => FilePreviewBody(
    data: FilePreviewData(
      name: name ?? (separator == '\t' ? 'table.tsv' : 'table.csv'),
      text: text,
      originalText: original,
      truncated: truncated,
    ),
  );
}
