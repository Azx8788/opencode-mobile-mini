part of '../library_screen.dart';

/// Settings › Tools › Commands (map `commands`, slice-P10.1): the same
/// command sheet the conversation's "/" opens ([CommandSheet]), inside its
/// tab. The server's commands in plain words, searchable, grouped; a pick
/// asks which conversation it runs in (the most recent one first) and
/// opens it there. A server that does not share its commands says so and
/// names what is missing, as the sheet does in a conversation.
///
/// States: loading (the list is on its way), empty (where commands come
/// from), error (a failed read says so with Retry; a later failure keeps
/// the last list), no match.
class CommandsScreen extends StatefulWidget {
  final ConnectionController controller;

  /// Embedded mode renders the body only, for the Commands & tools tabs.
  final bool embedded;
  const CommandsScreen({
    super.key,
    required this.controller,
    this.embedded = false,
  });

  @override
  State<CommandsScreen> createState() => _CommandsScreenState();
}

class _CommandsScreenState extends State<CommandsScreen> {
  List<CommandInfo>? _commands;
  Object? _error;
  bool _loading = false;
  bool _openingCommand = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// A newer read wins: an older one that lands later changes nothing.
  Future<void> _load() async {
    if (!widget.controller.capabilities.slashCommands) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = await widget.controller.prepareActionRepository();
      if (!mounted || generation != _loadGeneration) return;
      if (repository == null) {
        throw ProductException(
          _libraryCopy(context).e7LibraryOpenCodeIsReconnecting,
        );
      }
      final commands = await repository.listCommands();
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _commands = commands);
    } catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _loadGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  List<CommandSheetEntry> _entries() => serverCommandEntries(
    _libraryCopy(context),
    _commands ?? const <CommandInfo>[],
    serverName: widget.controller.profile?.name,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = _libraryCopy(context);
    final sheet = KitRefresh(
      onRefresh: _load,
      child: CommandSheet(
        controller: widget.controller,
        embedded: true,
        searchElsewhere: false,
        // This page reads the list itself when it opens.
        refreshOnOpen: false,
        subtitle: widget.controller.capabilities.slashCommands
            ? l10n.commandSheetLibrarySubtitle
            : null,
        commands: _entries,
        loading: () => _loading && _commands == null,
        loaded: () => _commands != null,
        error: () => _error,
        onRefresh: _load,
        onSelected: (entry) {
          if (entry.serverCommand case final command?) {
            unawaited(_run(command));
          }
        },
      ),
    );
    return KitScreen(
      width: KitScreenWidth.list,
      topBar: widget.embedded
          ? null
          : KitTopBar(title: l10n.e7LibraryServerCommands),
      body: sheet,
    );
  }

  Future<void> _run(CommandInfo command) async {
    if (_openingCommand) return;
    _openingCommand = true;
    try {
      final sessionID = await showRunCommandDialog(
        context,
        controller: widget.controller,
        command: command,
      );
      if (mounted && sessionID != null) {
        Navigator.of(context).pushNamed('/chat/$sessionID');
      }
    } finally {
      _openingCommand = false;
    }
  }
}
