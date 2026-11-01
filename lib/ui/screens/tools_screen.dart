// Tools and capabilities (map pages `tools` and `tools-detail-sheet`): which
// tools the chosen model can call, in one list ordered callable first, and
// each tool's plain parameter summary with Copy parameter schema in its menu.
// Built from kit parts only (screen-library-3, kit-v2 §9).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/product_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../state/connection.dart';
import '../../state/server_presentation.dart';
import '../app_theme.dart';
import '../kit/kit.dart';
import '../widgets/pickers.dart';
import '../widgets/product_states.dart' show productErrorText;

AppLocalizations _copy(BuildContext context) =>
    lookupAppLocalizations(Localizations.localeOf(context));

/// From this many tools the list gets its search field (map: "search from
/// ~8 tools"); a shorter list is read at a glance.
const toolsSearchThreshold = 8;

class ToolsScreen extends StatefulWidget {
  final ConnectionController controller;
  final ModelRef? initialModel;

  /// Embedded mode renders the body only, for the Commands & tools tabs.
  final bool embedded;

  const ToolsScreen({
    super.key,
    required this.controller,
    this.initialModel,
    this.embedded = false,
  });

  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  final _search = TextEditingController();
  ModelRef? _model;
  List<CodingToolInfo>? _tools;
  List<String>? _registeredIDs;
  ExperimentalServerCapabilities? _capabilities;
  Object? _toolsError;
  Object? _registeredError;
  Object? _capabilitiesError;
  String _query = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _model = widget.initialModel ?? widget.controller.selectedModel;
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final model = _model;
    // Keep stale rows during refresh; the skeleton is for first load only.
    setState(() {
      _toolsError = null;
      _registeredError = null;
      _capabilitiesError = null;
    });
    if (model == null) return;

    final repository = await widget.controller.prepareActionRepository();
    if (!mounted || generation != _generation) return;
    if (repository == null) {
      setState(() {
        _toolsError = ProductException(
          _copy(context).e7LibraryOpenCodeIsReconnectingTryAgain,
        );
      });
      return;
    }

    final toolsFuture = _capture(
      repository.listCodingTools(
        providerID: model.providerID,
        modelID: model.modelID,
      ),
    );
    final registeredFuture = _capture(repository.listCodingToolIDs());
    final capabilitiesFuture = _capture(
      repository.loadExperimentalCapabilities(),
    );
    final toolsResult = await toolsFuture;
    final registeredResult = await registeredFuture;
    final capabilitiesResult = await capabilitiesFuture;
    if (!mounted || generation != _generation || _model != model) return;

    setState(() {
      _tools = toolsResult.value;
      _toolsError = toolsResult.error;
      _registeredIDs = registeredResult.value;
      _registeredError = registeredResult.error;
      _capabilities = capabilitiesResult.value;
      _capabilitiesError = capabilitiesResult.error;
    });
  }

  Future<void> _chooseModel() async {
    await showModelPicker(context);
    if (!mounted) return;
    final selected = widget.controller.selectedModel;
    if (selected == null || selected == _model) return;
    // A different model's inventory would be misleading while the new one
    // loads, so clear the data (unlike a same-model refresh, which keeps it).
    setState(() {
      _model = selected;
      _tools = null;
      _registeredIDs = null;
      _capabilities = null;
    });
    await _load();
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _copy(context);
    final tools = _tools;
    final showSearch =
        _model != null &&
        tools != null &&
        (tools.length >= toolsSearchThreshold || _query.isNotEmpty);
    return KitScreen(
      topBar: widget.embedded
          ? null
          : KitTopBar(
              title: l10n.e7LibraryToolsAndCapabilities,
              actions: [
                KitAction(
                  key: const ValueKey('tools-refresh'),
                  label: l10n.e7LibraryRefreshTools,
                  icon: AppIconography.retry,
                  onPressed: _model == null ? null : _load,
                ),
              ],
            ),
      width: KitScreenWidth.list,
      search: showSearch
          ? KitSearchField(
              label: l10n.e7LibrarySearchTools2(tools.length.toString()),
              controller: _search,
              fieldKey: const ValueKey('tools-search'),
              onChanged: (value) => setState(() => _query = value),
            )
          : null,
      body: _model == null ? _noModel(l10n) : _toolList(l10n),
    );
  }

  Widget _noModel(AppLocalizations l10n) => KitStateView(
    icon: AppIconography.tools,
    title: l10n.modelChooseTitle,
    body: l10n.e7LibraryOpenCodeToolsDependOnTheProviderAnd,
    primary: KitAction(
      key: const ValueKey('tools-choose-model'),
      label: l10n.e7LibraryChooseModel,
      onPressed: _chooseModel,
    ),
  );

  /// The model the list is for: "Claude Sonnet 4" over "Anthropic", and
  /// "· no background subagents" when the server says so. The whole row
  /// opens the model picker (one way to change it, marked by the chevron).
  Widget _modelHeader(AppLocalizations l10n, ModelRef model) {
    final capabilities = _capabilities;
    return KitRowGroup(
      margin: EdgeInsets.zero,
      children: [
        KitRow(
          key: const Key('tools-model-summary'),
          leading: KitRow.icon(context, AppIconography.model),
          title: _modelName(model),
          titleMaxLines: 2,
          supporting: TextSpan(
            text: [
              widget.controller.providerName(model.providerID),
              if (capabilities != null && !capabilities.backgroundSubagents)
                l10n.toolsScreenNoBackgroundSubagents,
            ].join(' · '),
          ),
          supportingMaxLines: 2,
          trailing: const KitChevron(),
          onTap: _chooseModel,
        ),
      ],
    );
  }

  /// What the server could not report, in the failure tone, under the
  /// model; nothing when everything loaded (no counts line).
  Widget _gaps(AppLocalizations l10n) {
    final tokens = KitTokens.of(context);
    final errors = [
      if (_registeredError != null)
        l10n.e7LibraryRegisteredInventoryUnavailable,
      if (_capabilitiesError != null) l10n.e7LibraryServerCapabilityUnavailable,
    ];
    if (errors.isEmpty) return SizedBox(height: tokens.space3);
    return Padding(
      padding: EdgeInsetsDirectional.symmetric(vertical: tokens.space3),
      child: Wrap(
        spacing: tokens.space3,
        runSpacing: tokens.space1,
        children: [
          for (final error in errors)
            KitText(
              error,
              role: KitTextRole.secondary,
              tone: KitTextTone.primary,
            ),
        ],
      ),
    );
  }

  Widget _toolList(AppLocalizations l10n) {
    final model = _model!;
    final tools = _tools;
    final padding = KitScreen.padding(context);
    Widget page(List<Widget> children) => KitRefresh(
      onRefresh: _load,
      child: ListView(
        key: const Key('coding-tools-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding,
        children: [_modelHeader(l10n, model), _gaps(l10n), ...children],
      ),
    );
    if (tools == null && _toolsError == null) {
      return page(const [KitSkeletonRows(count: 7)]);
    }
    if (_toolsError != null && tools == null) {
      return page([
        KitStateView.error(
          size: KitStateSize.inline,
          title: l10n.toolsScreenLoadFailed,
          body: productErrorText(_toolsError!, l10n: l10n),
          error: _toolsError,
          retry: KitAction(label: l10n.commonRetry, onPressed: _load),
        ),
      ]);
    }
    final query = _query.trim().toLowerCase();
    final callable = tools!.where((tool) {
      return query.isEmpty ||
          tool.id.toLowerCase().contains(query) ||
          tool.description.toLowerCase().contains(query);
    }).toList();
    final callableIDs = {for (final tool in tools) tool.id};
    final registeredOnly = [
      for (final id in _registeredIDs ?? const <String>[])
        if (!callableIDs.contains(id) &&
            (query.isEmpty || id.toLowerCase().contains(query)))
          id,
    ];
    if (callable.isEmpty && registeredOnly.isEmpty) {
      return page([
        if (query.isNotEmpty)
          KitSearchNoMatch(
            query: _query.trim(),
            what: l10n.toolsScreenSearchWhat,
            onClear: _clearSearch,
          )
        else
          KitStateView(
            size: KitStateSize.inline,
            icon: AppIconography.tools,
            title: l10n.e7LibraryNoToolsForThisModel,
            body: l10n.emptyTeachToolsMessage,
          ),
      ]);
    }
    // One list (owner, 2026-09-27: no state sections): what this model can
    // call first, then what is registered but not offered to it; each row
    // says which it is.
    return page([
      KitRowGroup(
        margin: EdgeInsets.zero,
        leadingIcons: false,
        children: [
          for (final tool in callable) _callableToolRow(l10n, tool),
          for (final id in registeredOnly) _registeredToolRow(l10n, id),
        ],
      ),
    ]);
  }

  /// The tool by its name, and the server's description cut to its first
  /// sentence (emulator QA B11: the whole prompt text the server wrote for
  /// the model read as the row's title). The full description is on the
  /// tool's sheet the row opens.
  Widget _callableToolRow(AppLocalizations l10n, CodingToolInfo tool) {
    final summary = toolSummary(tool.description);
    return KitRow(
      key: Key('coding-tool-${tool.id}'),
      title: tool.id,
      supporting: TextSpan(
        text: summary.isNotEmpty
            ? summary
            : l10n.e7LibraryNoDescriptionReturnedByOpenCode,
      ),
      supportingMaxLines: 2,
      trailing: const KitChevron(),
      onTap: () => _showTool(tool),
    );
  }

  Widget _registeredToolRow(AppLocalizations l10n, String id) => KitRow(
    key: Key('registered-tool-$id'),
    title: id,
    supporting: TextSpan(text: l10n.toolsScreenRegisteredOnly),
    supportingMaxLines: 2,
  );

  void _showTool(CodingToolInfo tool) {
    final l10n = _copy(context);
    final schema = _prettyJson(tool.parameters);
    final parameters = toolParameters(tool.parameters);
    unawaited(
      showKitSheet<void>(
        context,
        title: tool.id,
        icon: AppIconography.tools,
        height: KitSheetHeight.full,
        sheetKey: const Key('tool-detail-scroll'),
        body: (sheetContext) {
          final tokens = KitTokens.of(sheetContext);
          final schemaMenu = KitRowMenu(
            key: const ValueKey('tool-menu'),
            tooltip: l10n.toolsDetailMenu(tool.id),
            menuLabel: l10n.toolsDetailMenu(tool.id),
            items: [
              KitMenuItem.copy(
                key: const ValueKey('tool-copy-schema'),
                label: l10n.e7LibraryCopyParameterSchema,
                text: () => schema,
              ),
            ],
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (tool.description.trim().isNotEmpty) ...[
                KitText.selectable(tool.description.trim()),
                SizedBox(height: tokens.space4),
              ],
              // What it takes, in words; the raw schema is one Copy away in
              // the menu beside them (never a JSON block on the sheet).
              if (parameters.isEmpty)
                Row(
                  children: [
                    Expanded(
                      child: KitText(
                        l10n.toolsDetailTakesNothing,
                        role: KitTextRole.secondary,
                        tone: KitTextTone.secondary,
                      ),
                    ),
                    schemaMenu,
                  ],
                )
              else
                KitRowGroup(
                  key: const ValueKey('tool-parameters'),
                  label: l10n.toolsDetailTakes,
                  labelTrailing: schemaMenu,
                  margin: EdgeInsets.zero,
                  leadingIcons: false,
                  children: [
                    for (final parameter in parameters)
                      KitRow(
                        key: ValueKey('tool-parameter-${parameter.name}'),
                        title: parameter.name,
                        supporting: TextSpan(
                          text: [
                            _typeWord(l10n, parameter.type),
                            parameter.required
                                ? l10n.toolsDetailRequired
                                : l10n.toolsDetailOptional,
                            ?parameter.description,
                          ].join(' · '),
                        ),
                        supportingMaxLines: 3,
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }

  String _modelName(ModelRef model) {
    final catalog = widget.controller.catalog;
    for (final candidate in catalog?.models ?? const <CatalogModel>[]) {
      if (candidate.providerID == model.providerID &&
          candidate.id == model.modelID) {
        return candidate.name;
      }
    }
    return model.modelID;
  }
}

/// A tool parameter as the person reads it.
/// The first sentence of a tool's description, as one plain line: the
/// first paragraph or list item, its list marker dropped, stopped at the
/// first sentence end. Empty when the server sent no description.
String toolSummary(String description) {
  final marker = RegExp(r'^([-*•]|\d+[.)])\s+');
  final lines = description.trim().split('\n').map((line) => line.trim());
  final first = <String>[];
  for (final line in lines) {
    // A blank line or the next list item ends the first thought.
    if (line.isEmpty || (first.isNotEmpty && marker.hasMatch(line))) break;
    first.add(line.replaceFirst(marker, ''));
  }
  final text = first.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final end = RegExp(r'[.!?](?=\s|$)').firstMatch(text);
  return end == null ? text : text.substring(0, end.end);
}

typedef ToolParameter = ({
  String name,
  ToolParameterType type,
  bool required,
  String? description,
});

/// What kind of value a parameter takes, in words.
enum ToolParameterType { text, number, yesNo, list, group, any }

/// The parameters a JSON Schema object declares, required first, in the
/// schema's own order otherwise. Anything that is not an object schema
/// with `properties` takes nothing the app can describe.
List<ToolParameter> toolParameters(Object? schema) {
  if (schema is! Map) return const [];
  final properties = schema['properties'];
  if (properties is! Map) return const [];
  final required = {
    for (final value
        in schema['required'] is List ? schema['required'] as List : const [])
      if (value is String) value,
  };
  final result = <ToolParameter>[
    for (final entry in properties.entries)
      if (entry.key is String)
        (
          name: entry.key as String,
          type: _typeOf(entry.value),
          required: required.contains(entry.key),
          description: switch (entry.value) {
            {'description': final String text} when text.trim().isNotEmpty =>
              text.trim(),
            _ => null,
          },
        ),
  ];
  final ordered = [
    ...result.where((parameter) => parameter.required),
    ...result.where((parameter) => !parameter.required),
  ];
  return ordered;
}

ToolParameterType _typeOf(Object? property) {
  final type = property is Map ? property['type'] : null;
  final name = type is List
      ? type.whereType<String>().where((t) => t != 'null').firstOrNull
      : type;
  return switch (name) {
    'string' => ToolParameterType.text,
    'number' || 'integer' => ToolParameterType.number,
    'boolean' => ToolParameterType.yesNo,
    'array' => ToolParameterType.list,
    'object' => ToolParameterType.group,
    _ => ToolParameterType.any,
  };
}

String _typeWord(AppLocalizations l10n, ToolParameterType type) =>
    switch (type) {
      ToolParameterType.text => l10n.toolsDetailTypeText,
      ToolParameterType.number => l10n.toolsDetailTypeNumber,
      ToolParameterType.yesNo => l10n.toolsDetailTypeYesNo,
      ToolParameterType.list => l10n.toolsDetailTypeList,
      ToolParameterType.group => l10n.toolsDetailTypeGroup,
      ToolParameterType.any => l10n.toolsDetailTypeAny,
    };

class _Captured<T> {
  final T? value;
  final Object? error;

  const _Captured.value(this.value) : error = null;
  const _Captured.error(this.error) : value = null;
}

Future<_Captured<T>> _capture<T>(Future<T> future) async {
  try {
    return _Captured.value(await future);
  } catch (error) {
    return _Captured.error(error);
  }
}

String _prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value?.toString() ?? 'null';
  }
}
