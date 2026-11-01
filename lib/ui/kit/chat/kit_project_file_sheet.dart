// KitProjectFileSheet: the "+" tool "File from the project". A search field
// and the files it finds (name, then folder); a tap returns the file's
// project-relative path, and the composer writes it as an `@path` mention.
//
// Before anything is typed the sheet lists [initial] for the folder being
// browsed: the top level first, with its folders (paths ending in `/`); a
// tap on a folder lists that folder, and a Back row returns. Search results
// are files only. When there is nothing it says what to do. Searching shows no spinner row:
// the sheet's own loading bar runs while a search is out, and the last
// results stay until the new ones arrive.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../kit_sheet.dart';
import 'kit_project_file_list.dart';

/// Opens the sheet; completes with the chosen project-relative path, or null
/// when it was dismissed. [search] finds files by name; [initial] lists the
/// files shown before a query. Either may throw: the sheet then says so in
/// plain words and keeps the field.
Future<String?> showKitProjectFileSheet(
  BuildContext context, {
  Key? sheetKey,
  required Future<List<String>> Function(String query) search,
  Future<List<String>> Function(String folder)? initial,
}) async {
  final l10n = lookupAppLocalizations(Localizations.localeOf(context));
  final loading = ValueNotifier<bool>(false);
  try {
    return await showKitSheet<String>(
      context,
      title: l10n.mentionSheetTitle,
      sheetKey: sheetKey ?? const Key('project-file-sheet'),
      height: KitSheetHeight.full,
      loading: loading,
      body: (sheetContext) => KitProjectFileList(
        search: search,
        initial: initial,
        loading: loading,
        onPick: (path) => KitSheet.close<String>(sheetContext, path),
      ),
    );
  } finally {
    loading.dispose();
  }
}
