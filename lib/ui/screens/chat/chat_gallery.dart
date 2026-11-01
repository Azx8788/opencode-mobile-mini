part of '../chat_screen.dart';

// Pictures of the conversation as one gallery: a tapped picture opens a
// swipeable view of every picture in the transcript, in the order they were
// shown, with Edit and Send (docs/ux-system/kit-api/KitImageGallery.md).
// Send puts the picture in the message field as a photo attachment; it never
// sends the prompt.

/// A file name Flutter can draw as a picture.
final _drawablePictureName = RegExp(
  r'\.(png|jpe?g|gif|webp|bmp)$',
  caseSensitive: false,
);

/// One picture of the transcript, before it is shown.
class _ChatPicture {
  const _ChatPicture({
    required this.key,
    required this.name,
    required this.load,
  });

  /// `part:<message>:<index>`, `path:<path>` or `tool:<identity>`.
  final String key;
  final String name;
  final Future<Uint8List?> Function() load;
}

/// The key a sent photo (or any file part) has in the gallery.
String _pictureKeyOfPart(String messageId, int index) =>
    'part:$messageId:$index';

extension _ChatGallery on _ChatScreenState {
  _ChatPicture _pathPicture(String path) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    return _ChatPicture(
      key: 'path:$path',
      name: name,
      load: () async {
        // The thumbnail's reader first (capped, shared with the transcript);
        // a larger picture is read whole.
        final small = await _loadPathImage(path);
        if (small != null) return small;
        final data = await _loadToolOutputFile(
          ToolOutputFile(path: path, filename: name),
        );
        return data.error == null ? data.bytes : null;
      },
    );
  }

  /// Every picture in the transcript, in order, without waiting on the host.
  /// A Markdown picture the host already said it cannot find is left out;
  /// any other that proves unreadable shows the gallery's own error page.
  List<_ChatPicture> _conversationPictures() {
    final strings = _chatL10n(context);
    final found = <_ChatPicture>[];
    final seen = <String>{};
    void add(_ChatPicture picture) {
      if (seen.add(picture.key)) found.add(picture);
    }

    for (final message in _messages) {
      for (var i = 0; i < message.parts.length; i++) {
        final part = message.parts[i];
        if (part.type == 'file') {
          if (part.mime == PromptAttachment.directoryReferenceMime ||
              !_isDrawablePicture(part.mime)) {
            continue;
          }
          final name = part.filename?.trim().isNotEmpty == true
              ? part.filename!.trim()
              : strings.chatUiAttachment;
          final bytes = _sentPhotoDataBytes(part);
          final path = bytes == null ? _sentPhotoServerPath(part) : null;
          if (bytes == null && path == null) continue;
          add(
            _ChatPicture(
              key: _pictureKeyOfPart(message.info.id, i),
              name: name,
              load: bytes != null
                  ? () async => bytes
                  : () async {
                      final data = await _loadToolOutputFile(
                        ToolOutputFile(
                          path: path,
                          mimeType: part.mime,
                          filename: name,
                        ),
                      );
                      return data.error == null ? data.bytes : null;
                    },
            ),
          );
        } else if (part.type == 'text' && !part.synthetic) {
          var fenced = false;
          for (final line in part.text.split('\n')) {
            if (line.trimLeft().startsWith('```')) {
              fenced = !fenced;
              continue;
            }
            if (fenced) continue;
            for (final piece in KitMarkdownImage.scan(line)) {
              final image = piece.image;
              final path = image?.path;
              if (image == null ||
                  path == null ||
                  image.kind != KitMarkdownImageKind.file ||
                  !image.drawable) {
                continue;
              }
              if (_pathLinkMissAt.containsKey(path)) continue;
              add(_pathPicture(path));
            }
          }
        } else if (part.type == 'tool') {
          for (final file in part.toolState.outputFiles) {
            if (!file.isImage) continue;
            final url = file.url;
            add(
              _ChatPicture(
                key: 'tool:${file.identity}',
                name: file.displayName,
                load: () async {
                  final data = url?.isNotEmpty == true
                      ? FilePreviewData.fromDataUrl(
                          name: file.displayName,
                          mimeType: file.mimeType,
                          url: url,
                        )
                      : await _loadToolOutputFile(file);
                  return data.error == null ? data.bytes : null;
                },
              ),
            );
          }
        }
      }
    }
    return found;
  }

  /// Opens the gallery on the picture with [key]. [fallbackPath] is shown
  /// (after the others) when the transcript does not hold it.
  Future<void> _openPictureGallery(String key, {String? fallbackPath}) async {
    if (_conn.isIsolated) return;
    var pictures = _conversationPictures();
    var index = pictures.indexWhere((picture) => picture.key == key);
    if (index < 0 && fallbackPath != null) {
      pictures = [...pictures, _pathPicture(fallbackPath)];
      index = pictures.length - 1;
    }
    if (index < 0 || pictures.isEmpty) return;
    String? sentName;
    await showKitImageGallery(
      context,
      pictures: [
        for (final picture in pictures)
          KitGalleryPicture(
            id: picture.key,
            name: picture.name,
            load: picture.load,
          ),
      ],
      initialIndex: index,
      onSend: _supportsPromptAttachments
          ? (bytes, name, {required edited}) async {
              try {
                final mime = edited ? 'image/png' : null;
                await _addPreviewAttachment(
                  filename: name,
                  mimeType: mime,
                  data: FilePreviewData(
                    name: name,
                    mimeType: mime,
                    bytes: bytes,
                  ),
                );
                sentName = name;
                return true;
              } catch (error) {
                if (mounted) showProductError(context, error);
                return false;
              }
            }
          : null,
    );
    final attached = sentName;
    if (!mounted || attached == null) return;
    _focus.requestFocus();
    _showComposerNote(_chatL10n(context).chatUiFileAttached(attached));
  }
}
