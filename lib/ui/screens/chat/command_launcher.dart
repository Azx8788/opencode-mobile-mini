part of '../chat_screen.dart';

enum _ChatCommandAction {
  newSession,
  sessions,
  workspaces,
  move,
  warp,
  files,
  projectHealth,
  promptEditor,
  terminal,
  model,
  integrations,
  mcpServers,
  organization,
  skills,
  tools,
  references,
  status,
  diagnostics,
  appearance,
  diff,
  context,
  share,
  unshare,
  rename,
  timeline,
  fork,
  compact,
  thinking,
  timestamps,
  undo,
  redo,
  copy,
  export,
  help,
  shell,
  retry,
  note,
  approvals,
  reload,
  plan,
}

/// The chat's commands are the shared command sheet's entries
/// (lib/ui/widgets/command_sheet.dart, slice-P10.1): the app's actions carry
/// a [_ChatCommandAction], the server's commands their [CommandInfo].
typedef _ChatCommand = CommandSheetEntry;
