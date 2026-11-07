/// App-authored scripts that write Claude Code's own endpoint.
///
/// Claude Code takes `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` from the
/// `env` block of `$CLAUDE_CONFIG_DIR/settings.json`. The app writes that
/// block for a person who has a gateway rather than a Claude account; the
/// key goes into the file and nowhere else.
///
/// Only writing needs the phone's Linux user: the file must belong to the
/// account the agent runs as. Reading that file is plain file access from the
/// app (see `BuiltinPhoneAgents.readAgentEndpoint`), because the sandbox is
/// the app's own storage.
///
/// The payload travels as base64, so no key character can end an argument or
/// the heredoc, a symlinked path is refused, and a write lands through a
/// sibling file and a rename. The script prints nothing: the private check
/// channel only carries receipts, and the key must not travel back.
library;

import 'dart:convert';

import '../../domain/agent_endpoint.dart';

abstract final class AgentEndpointScripts {
  static String claude({
    required String profileId,
    required String action,
    AgentEndpoint? endpoint,
  }) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(profileId)) {
      throw ArgumentError('Invalid profile identity');
    }
    if (action != 'write' && action != 'clear') {
      throw ArgumentError('Unknown endpoint action');
    }
    if (action == 'write' && endpoint == null) {
      throw ArgumentError('Writing an endpoint needs one');
    }
    final payload = <String, Object?>{
      'home': '/home/oc/.oc-profiles/$profileId',
      'action': action,
      if (endpoint != null) ...{
        'baseUrl': endpoint.baseUrl,
        if (endpoint.apiKey != null) 'apiKey': endpoint.apiKey,
        if (endpoint.model != null) 'model': endpoint.model,
      },
    };
    final data = base64.encode(utf8.encode(jsonEncode(payload)));
    return '''
set -eu
umask 077
[ -x /usr/bin/python3 ] || exit 20
/usr/bin/python3 - '$data' <<'OC_AGENT_ENDPOINT' 2>/dev/null
$_program
OC_AGENT_ENDPOINT
''';
  }

  static const _program = r'''
import base64, json, os, pathlib, re, stat, sys, tempfile
class Refused(Exception):
    def __init__(self, code): self.code = code
def fail(code): raise Refused(code)
def safe(path, directory=False):
    path = pathlib.Path(path)
    for part in [*reversed(path.parents), path]:
        try: info = os.lstat(part)
        except FileNotFoundError:
            if directory: fail(22)
            return False
        if stat.S_ISLNK(info.st_mode): fail(22)
        if part != path or directory:
            if not stat.S_ISDIR(info.st_mode): fail(22)
        elif not stat.S_ISREG(info.st_mode): fail(22)
    return True
def read_json(path):
    if not safe(path): return {}
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        raw = stream.read(1048577)
    if len(raw) > 1048576: fail(21)
    if not raw.strip(): return {}
    try: value = json.loads(raw)
    except Exception: fail(21)
    if not isinstance(value, dict): fail(21)
    return value
def atomic(path, value):
    parent = str(pathlib.Path(path).parent)
    fd, temporary = tempfile.mkstemp(prefix='.oc-endpoint-', dir=parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(value); stream.flush(); os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try: os.unlink(temporary)
        except OSError: pass
        raise
def text(value, maximum):
    if not isinstance(value, str) or not value or len(value) > maximum: fail(23)
    if any(ord(c) < 32 or ord(c) == 127 for c in value): fail(23)
    return value
try:
    payload = json.loads(base64.b64decode(sys.argv[1]).decode('utf-8'))
    if not isinstance(payload, dict): fail(23)
    home = payload.get('home'); action = payload.get('action')
    if not isinstance(home, str) or not re.fullmatch(r'/home/oc/\.oc-profiles/[A-Za-z0-9_-]{1,80}', home): fail(23)
    config = home + '/claude'
    settings = config + '/settings.json'
    if action == 'write':
        base = text(payload.get('baseUrl'), 2048)
        supplied = payload.get('apiKey')
        model = payload.get('model')
        if model is not None: model = text(model, 200)
        if not os.path.isdir(config):
            if os.path.lexists(config): fail(22)
            os.mkdir(config, 0o700)
        safe(config, directory=True)
        data = read_json(settings)
        env = data.get('env')
        if env is None: env = {}
        elif not isinstance(env, dict): fail(21)
        if supplied is None:
            saved = env.get('ANTHROPIC_AUTH_TOKEN') or env.get('ANTHROPIC_API_KEY')
            if not isinstance(saved, str) or not saved.strip(): fail(24)
        else:
            env['ANTHROPIC_AUTH_TOKEN'] = text(supplied, 4096)
            env.pop('ANTHROPIC_API_KEY', None)
        env['ANTHROPIC_BASE_URL'] = base
        if model is None: env.pop('ANTHROPIC_MODEL', None)
        else: env['ANTHROPIC_MODEL'] = model
        data['env'] = env
        atomic(settings, json.dumps(data, ensure_ascii=False, indent=2).encode('utf-8'))
    else:
        data = read_json(settings)
        env = data.get('env') if isinstance(data.get('env'), dict) else {}
        for name in ('ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_MODEL'):
            env.pop(name, None)
        if env: data['env'] = env
        else: data.pop('env', None)
        if data:
            atomic(settings, json.dumps(data, ensure_ascii=False, indent=2).encode('utf-8'))
        elif safe(settings):
            os.unlink(settings)
except Refused as error:
    sys.exit(error.code)
except (ValueError, TypeError, KeyError):
    sys.exit(21)
except OSError:
    sys.exit(22)
''';
}
