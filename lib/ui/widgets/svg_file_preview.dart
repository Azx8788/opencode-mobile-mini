import 'package:flutter/widgets.dart';

import '../../domain/static_svg.dart';
import '../kit/kit_viewer.dart';
import 'file_preview.dart';

/// What the kit viewer shows for an SVG file: the picture after
/// [StaticSvg] sanitised it (no network, no scripts), with [original] behind
/// Show source and Copy; or the XML itself when the picture is refused or
/// only part of the file arrived ([unsupported] says which).
({KitViewerContent content, bool unsupported}) svgViewerContent(
  String source, {
  String? original,
  bool truncated = false,
}) {
  final svg = truncated ? null : StaticSvg.parse(source);
  if (svg == null) {
    final text = capPreviewSource(source);
    return (
      content: KitViewerContent.code(
        text.text,
        language: 'xml',
        truncated: truncated || text.cut,
      ),
      unsupported: !truncated,
    );
  }
  return (
    content: KitViewerContent.svg(svg.source, original: original ?? source),
    unsupported: false,
  );
}

/// An SVG file in a host that has its own header: the picture with Image
/// and Source above it, or the source with the reason it is not drawn.
class SvgFilePreview extends StatelessWidget {
  const SvgFilePreview({
    super.key,
    required this.source,
    required this.original,
    this.truncated = false,
    this.name,
  });

  final String source;
  final String original;
  final bool truncated;

  /// The file's name; defaults to "image.svg".
  final String? name;

  @override
  Widget build(BuildContext context) => FilePreviewBody(
    data: FilePreviewData(
      name: name ?? 'image.svg',
      mimeType: 'image/svg+xml',
      text: source,
      originalText: original,
      truncated: truncated,
    ),
  );
}
