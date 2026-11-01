import '../widgets/session_menu.dart' show SessionMenuAction;

class ChatRouteArguments {
  const ChatRouteArguments({
    this.discardIfUntouched = false,
    this.focusComposer = false,
    this.landOnRequestID,
    this.landOnFailure = false,
    this.menuAction,
  });

  const ChatRouteArguments.newlyCreated()
    : discardIfUntouched = true,
      focusComposer = false,
      landOnRequestID = null,
      landOnFailure = false,
      menuAction = null;

  /// The conversation first run lands in: new, and with the keyboard already
  /// up, because typing the first message is the only thing left to do.
  const ChatRouteArguments.firstRun()
    : discardIfUntouched = true,
      focusComposer = true,
      landOnRequestID = null,
      landOnFailure = false,
      menuAction = null;

  final bool discardIfUntouched;
  final bool focusComposer;

  /// P4.2a: the waiting request (permission, question or form) the chat
  /// opens on: its card leads and is marked once.
  final String? landOnRequestID;

  /// P4.2a: the chat opens on its newest failed turn.
  final bool landOnFailure;

  /// P10.2: a Work row's conversation-menu pick the chat runs once open.
  final SessionMenuAction? menuAction;
}

/// The [KitArrival] id of a request card in a chat (P4.2a), so a door that
/// opens the chat for one request lands on exactly that card.
String chatRequestArrivalId(String requestID) => 'chat-request-$requestID';
