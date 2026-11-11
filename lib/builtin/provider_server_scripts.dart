/// The server's own model-list request, run inside the server's environment.
///
/// Reading a provider's model list from the phone was the last thing this app
/// did with the person's key: it opened its own HTTPS connection, with its own
/// `User-Agent`, from an app the gateway has never heard of. Several gateways
/// answer that with a 200 and a sentence saying only their own clients may
/// use them — a "successful" read that lists nothing, or worse, a test that
/// passes against a refusal.
///
/// So the request is made by the server instead: this script reads the entry
/// the person just saved — address, key, custom headers — and asks with the
/// identity OpenCode itself uses (`opencode/<version>`). The key never travels
/// back to Dart, and the app never opens a socket to a provider.
///
/// The script is deliberately dumb. It fetches one URL with one auth scheme
/// and returns the status and the body; which spellings of `/models` to try,
/// which auth scheme to use first, and what a status means stay in Dart
/// (`ProviderModelSource`), where they are already tested and translated.
library;

import 'dart:convert';

abstract final class ProviderServerScripts {
  /// What the script prints before its base64 answer. One marker keeps a
  /// stray warning on stdout from being parsed as the result.
  static const marker = 'RESULT:';

  /// The identity OpenCode sends its own provider requests with.
  ///
  /// The version matters: gateways match on `opencode/` and some pin the
  /// shape of the rest. The app knows the version of the server it is
  /// talking to, so it uses that one rather than a number typed here.
  static String userAgent(String? version) {
    final clean = (version ?? '').trim();
    final usable = RegExp(r'^[0-9][0-9A-Za-z.+-]{0,31}$').hasMatch(clean);
    return 'opencode/${usable ? clean : fallbackVersion}';
  }

  /// Used only when the running server has not reported a version yet. It is
  /// the release this build ships with, not a claim about the server.
  static const fallbackVersion = '2.1.1';

  /// Reads the saved entry: its address, and whether a key is there at all.
  static String describe({
    required String configPath,
    required String providerID,
    required String userAgent,
  }) => _wrap({
    'action': 'describe',
    'config': configPath,
    'provider': providerID,
    'userAgent': userAgent,
  });

  /// Fetches one URL with the key the config holds, in the given auth scheme.
  static String get({
    required String configPath,
    required String providerID,
    required String userAgent,
    required Uri url,
    required String auth,
    required Duration timeout,
  }) => _wrap({
    'action': 'get',
    'config': configPath,
    'provider': providerID,
    'userAgent': userAgent,
    'url': url.toString(),
    'auth': auth,
    'timeout': timeout.inSeconds,
  });

  static String _wrap(Map<String, Object?> payload) {
    final data = base64.encode(utf8.encode(jsonEncode(payload)));
    return '''
set -eu
umask 077
[ -x /usr/bin/python3 ] || exit 20
/usr/bin/python3 - '$data' <<'OC_PROVIDER_MODELS' 2>/dev/null
$_program
OC_PROVIDER_MODELS
''';
  }

  /// Runs inside the server's rootfs. Prints one line: `RESULT:<base64>`.
  ///
  /// Exit codes: 20 no python, 21 the config cannot be read, 22 no such
  /// provider, 23 a malformed payload. Anything the provider itself did is a
  /// printed answer, not an exit code.
  static const _program = r'''
import base64, json, os, ssl, stat, sys, urllib.error, urllib.request

CONFIG_LIMIT = 4 * 1024 * 1024
BODY_LIMIT = 2 * 1024 * 1024

class Refused(Exception):
    def __init__(self, code):
        self.code = code

def fail(code):
    raise Refused(code)

def emit(payload):
    text = json.dumps(payload, ensure_ascii=False)
    sys.stdout.write('RESULT:' + base64.b64encode(text.encode('utf-8')).decode('ascii') + '\n')

def read_config(path):
    try:
        info = os.lstat(path)
    except OSError:
        fail(21)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        fail(21)
    if info.st_size > CONFIG_LIMIT:
        fail(21)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        raw = stream.read(CONFIG_LIMIT + 1)
    try:
        return json.loads(raw.decode('utf-8'))
    except Exception:
        fail(21)

def entry_of(document, provider):
    # v2 keeps providers under `providers`, v1 under `provider`.
    for root in ('providers', 'provider'):
        providers = document.get(root)
        if isinstance(providers, dict):
            entry = providers.get(provider)
            if isinstance(entry, dict):
                return entry
    fail(22)

def settings_of(entry):
    # v2 names the block `settings`, v1 `options`.
    for name in ('settings', 'options'):
        block = entry.get(name)
        if isinstance(block, dict):
            return block
    return {}

def read_key(settings):
    raw = settings.get('apiKey')
    if not isinstance(raw, str):
        return None, 'none'
    text = raw.strip()
    if not text:
        return None, 'none'
    if text.startswith('{file:') and text.endswith('}'):
        path = text[6:-1].strip()
        try:
            info = os.lstat(path)
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                return None, 'file'
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as stream:
                value = stream.read(8193).decode('utf-8', 'replace').strip()
            return (value or None), 'file'
        except OSError:
            return None, 'file'
    if text.startswith('{env:') and text.endswith('}'):
        # The server's own environment is not this script's to read.
        return None, 'env'
    return text, 'config'

def base_of(settings):
    for name in ('baseURL', 'baseUrl', 'base_url'):
        value = settings.get(name)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ''

def headers_of(settings, user_agent):
    # The identity OpenCode sends, then whatever the entry asks for on top of
    # it: a gateway that wants its own User-Agent, or an origin, gets it.
    headers = {'Accept': 'application/json', 'User-Agent': user_agent}
    extra = settings.get('headers')
    if isinstance(extra, dict):
        for name, value in extra.items():
            if not isinstance(name, str) or not name.strip():
                continue
            if isinstance(value, (str, int, float)) and str(value).strip():
                headers[name.strip()] = str(value)
    return headers

def fetch(url, headers, timeout):
    request = urllib.request.Request(url, headers=headers, method='GET')
    context = ssl.create_default_context()
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            return response.status, response.read(BODY_LIMIT + 1)
    except urllib.error.HTTPError as error:
        try:
            body = error.read(BODY_LIMIT + 1)
        except Exception:
            body = b''
        return error.code, body

def main():
    try:
        payload = json.loads(base64.b64decode(sys.argv[1]).decode('utf-8'))
    except Exception:
        fail(23)
    document = read_config(payload.get('config') or '')
    entry = entry_of(document, payload.get('provider') or '')
    settings = settings_of(entry)
    user_agent = payload.get('userAgent') or 'opencode'
    if payload.get('action') == 'describe':
        key, source = read_key(settings)
        emit({'ok': True, 'baseUrl': base_of(settings), 'hasKey': key is not None, 'keySource': source})
        return
    key, source = read_key(settings)
    headers = headers_of(settings, user_agent)
    auth = payload.get('auth') or 'none'
    if key:
        if auth == 'x-api-key':
            headers['x-api-key'] = key
            headers['anthropic-version'] = '2023-06-01'
        elif auth == 'x-goog-api-key':
            headers['x-goog-api-key'] = key
        elif auth == 'bearer':
            headers['Authorization'] = 'Bearer ' + key
    timeout = payload.get('timeout')
    if not isinstance(timeout, (int, float)) or timeout <= 0 or timeout > 120:
        timeout = 20
    try:
        status, raw = fetch(payload.get('url') or '', headers, timeout)
    except ssl.SSLError:
        emit({'ok': False, 'error': 'tls'})
        return
    except urllib.error.URLError as error:
        reason = getattr(error, 'reason', None)
        if isinstance(reason, ssl.SSLError):
            emit({'ok': False, 'error': 'tls'})
        elif isinstance(reason, TimeoutError) or 'timed out' in str(reason):
            emit({'ok': False, 'error': 'timeout'})
        else:
            emit({'ok': False, 'error': 'network', 'message': str(reason)[:200]})
        return
    except TimeoutError:
        emit({'ok': False, 'error': 'timeout'})
        return
    except Exception as error:
        emit({'ok': False, 'error': 'network', 'message': str(error)[:200]})
        return
    body = raw[:BODY_LIMIT].decode('utf-8', 'replace')
    emit({'ok': True, 'status': status, 'body': body})

try:
    main()
except Refused as refused:
    sys.exit(refused.code)
except Exception:
    sys.exit(24)
''';
}
