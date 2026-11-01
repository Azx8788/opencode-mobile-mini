"""Fixed app helper: JSON on stdin; safe JSON only on stdout, never secrets.

Uses only Python's standard library. The Android bridge supplies a hard process
lifetime and bounds output. Tests import this exact file (not a logic mirror).
"""
import base64
import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import re
import socket
import ssl
import stat
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

PACKAGE = '@opencode/ai/providers/openai-compatible'
CONFIG = '/root/.oc-opencode2/config/opencode/opencode.json'
MAX_BYTES = 1024 * 1024
MAX_MODELS = 5000
# OpenCode 2.1.1 /api/integration plus bundled provider aliases (offline guard).
RESERVED = {'opper', 'lynkr', 'requesty', 'crusoe', 'tokengo', 'qihang-ai', 'qvac', 'fastrouter', 'zeldoc', 'google-vertex-anthropic', 'bee', 'tokenrouter', 'deepseek', 'gitlab', 'vivgrid', 'zhipuai-coding-plan', 'infer', 'stackit', 'wandb', 'siliconflow', 'tensorx', 'perplexity-agent', 'amd', 'longcat', 'kosmik', 'qwen', 'daoxe', 'evroc', 'alibaba-token-plan', 'zhipuai', 'moonshotai', 'melious', 'venice', 'alibaba-coding-plan-cn', 'scaleway', 'modelscope', 'minimax-cn', 'inco', 'scx-ai', 'salad-cloud', 'frogbot', 'ollama', 'vispark', 'impossibl', 'routing-run', 'azure-cognitive-services', 'vercel', 'cerebras', 'helicone', 'cloudferro-sherlock', 'nano-gpt', 'trustedrouter', 'inference', 'parallel', 'sakana', 'zai', 'opencode-go', 'neon', 'iflowcn', 'digitalocean', 'scnet-token-plan', 'volcengine', 'agnes', 'kimi-code-plan-cn', 'cloudflare-workers-ai', 'watsonx', 'crossmodel', 'llmgateway-providers', 'pendra', 'privatemode-ai', 'auriko', 'synthetic', 'ofox', 'xiaomi-token-plan-ams', 'drun', '302ai', 'nova', 'openrouter', 'atomic-chat', 'inceptron', 'neosmith', 'standardcompute', 'tempr', 'kimi-for-coding', 'modelis', 'pioneer', 'sarvam', 'tencent-coding-plan', 'echo', 'runinfra', 'tavily', 'subconscious', 'meta', 'opencode', 'grok', 'hyper', 'llmtech', 'bailing', 'merge-gateway', 'agentrouter', 'jalapeno', 'amazon-bedrock', 'azure', 'huggingface', 'xiaomi', 'minimax-coding-plan', 'ainetcafe', 'above', 'boundless', 'abacus', 'the-grid-ai', 'aimlapi', 'umans-ai', 'lilac', 'inferx', 'regolo-ai', 'alibaba', 'model-oracle-ai', 'coralbricks', 'mistral', 'modal', 'submodel', 'hpc-ai', 'ovhcloud', 'xai', 'cloudflare-ai-gateway', 'baseten', 'kenari', 'nearai', 'alibaba-token-plan-cn', 'openreason', 'databricks', 'claudinio', 'edenai', 'friendli', 'neuralwatt', 'blueclaw', 'greenpt', 'ollama-cloud', 'reflection', 'togetherai', 'stepfun-step-plan', 'chutes', 'moark', 'lowrouter', 'wafer.ai', 'gmicloud', 'exa', 'cortecs', 'kuae-cloud-coding-plan', 'umans-ai-coding-plan', 'meganova', 'berget', 'klokintegration', 'fireworks-ai', 'oci', 'llmgateway', 'aki-io', 'ambient', 'cline-pass', 'stepfun', 'commandcode', 'novita-ai', 'empiriolabs', 'prime', 'nebius', 'siliconflow-cn', 'tinfoil', 'unorouter', 'vancine', 'xiaomi-token-plan-cn', 'kimi-code-plan-global', 'kilo', 'iteracompute', 'alibaba-coding-plan', 'thinkingmachines', 'qiniu-ai', 'ebcloud', 'morph', 'aixy', 'zenifra', 'ai-router', 'zai-coding-plan', 'hetzner', 'clarifai', 'infomaniak', 'llmtr', 'minimax', 'poe', 'upstage', 'google', 'stepfun-ai', 'dinference', 'tencent-token-plan', 'perplexity', 'zenmux', 'volcengine-coding-plan', 'xiaomi-token-plan-sgp', 'firecrawl', 'llama', 'ai21', 'stepfun-ai-step-plan', 'tinyfish', 'deepinfra', 'anyapi', 'openai', 'tencent-tokenhub', 'lucidquery', 'alibaba-cn', 'groq', 'arcee', 'io-net', 'freemodel', 'xpersona', 'sambanova', 'sap-ai-core', 'vultr', 'wallaby', 'moonshotai-cn', 'anthropic', 'nan', 'google-vertex', 'pareto', 'nvidia', 'github-copilot', 'bothub', 'poolside', 'engy', 'abliteration-ai', 'orcarouter', 'jiekou', 'lmstudio', 'mixlayer', 'aiand', 'inception', 'minimax-cn-coding-plan', 'cohere', 'snowflake-cortex', 'sensenova', 'aihubmix'}


class Failure(Exception):
    def __init__(self, code, status=None):
        self.code, self.status = code, status


def fail(code):
    raise Failure(code)


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            fail('invalid_config')
        result[key] = value
    return result


def decode(raw):
    try:
        return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=pairs,
                          parse_constant=lambda _: fail('invalid_config'))
    except Failure:
        raise
    except Exception:
        fail('invalid_config')


def normalized_url(value):
    if not isinstance(value, str):
        fail('invalid_url')
    value = value.strip().rstrip('/')
    if value.endswith('/chat/completions'):
        value = value[:-len('/chat/completions')].rstrip('/')
    try:
        u = urllib.parse.urlsplit(value)
        if (u.scheme not in ('http', 'https') or not u.hostname or
                u.username is not None or u.password is not None or u.query or
                u.fragment or re.search(r'[\s\x00-\x1f\x7f\\]', value) or
                len(value) > 2048 or (u.port is not None and not 1 <= u.port <= 65535)):
            fail('invalid_url')
    except (ValueError, TypeError):
        fail('invalid_url')
    return urllib.parse.urlunsplit((u.scheme, u.netloc.lower(), u.path, '', ''))


def validate_id(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', value):
        fail('invalid_id')
    if value in RESERVED:
        fail('reserved_id')


def model_ids(value):
    if not isinstance(value, list) or len(value) > MAX_MODELS:
        fail('too_large')
    result = set()
    for item in value:
        if not isinstance(item, str):
            fail('invalid_models')
        item = item.strip()
        if not item:
            continue
        if len(item) > 512 or re.search(r'[\x00-\x1f\x7f#]', item):
            fail('invalid_models')
        result.add(item)
    return sorted(result)


def parse_models(value):
    rows = value if isinstance(value, list) else (
        value.get('data', value.get('models')) if isinstance(value, dict) else None)
    if not isinstance(rows, list):
        fail('invalid_response')
    result = []
    for row in rows:
        if isinstance(row, str):
            result.append(row)
        elif isinstance(row, dict):
            identity = row.get('id', row.get('name'))
            if isinstance(identity, str):
                result.append(identity)
    return model_ids(result)


def safe(path, create=False, directory=False):
    path = pathlib.Path(path)
    for part in [*reversed(path.parents), path]:
        try:
            info = os.lstat(part)
        except FileNotFoundError:
            if create and (part != path or directory):
                os.mkdir(part, 0o700)
                info = os.lstat(part)
            else:
                return False
        if stat.S_ISLNK(info.st_mode):
            fail('unsafe_path')
        if part != path or directory:
            if not stat.S_ISDIR(info.st_mode):
                fail('unsafe_path')
        elif not stat.S_ISREG(info.st_mode):
            fail('unsafe_path')
    return True


def read_raw(path):
    if not safe(path):
        return None
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        fail('too_large')
    return raw


def load(path):
    if os.path.lexists(path + 'c'):
        fail('jsonc')
    raw = read_raw(path)
    config = {} if raw is None else decode(raw)
    if not isinstance(config, dict) or not isinstance(config.get('providers', {}), dict):
        fail('invalid_config')
    return config, raw


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def summary(identity, entry):
    settings = entry.get('settings', {})
    models = entry.get('models', {})
    if not isinstance(settings, dict) or not isinstance(models, dict):
        fail('invalid_config')
    try:
        url = normalized_url(settings.get('baseURL', ''))
    except Failure:
        url = ''  # Never expose credentials embedded in an invalid URL.
    return {'id': identity, 'name': entry.get('name', identity), 'baseURL': url,
            'models': model_ids(list(models)), 'hasKey': bool(settings.get('apiKey')),
            'revision': digest(entry)}


def referenced(value, identity, removed=None):
    if isinstance(value, dict):
        return value.get('providerID') == identity and (
            removed is None or value.get('model') in removed)
    if isinstance(value, str) and value.startswith(identity + '/'):
        return removed is None or value[len(identity) + 1:].split('#', 1)[0] in removed
    return False


def clean_references(config, identity, removed=None):
    for key in ('model', 'small_model'):
        if referenced(config.get(key), identity, removed):
            config.pop(key)
    for key in ('agents', 'agent'):
        agents = config.get(key, {})
        if not isinstance(agents, dict):
            fail('invalid_config')
        for agent in agents.values():
            if isinstance(agent, dict) and referenced(agent.get('model'), identity, removed):
                agent.pop('model')


@contextlib.contextmanager
def config_lock(path):
    safe(str(pathlib.Path(path).parent), create=True, directory=True)
    lock_path = str(pathlib.Path(path).parent / '.mini-config.lock')
    safe(lock_path)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(fd, 0o600)
        deadline = time.monotonic() + 8
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    fail('busy')
                time.sleep(.05)
        yield
    finally:
        os.close(fd)


def atomic(path, raw, before=None, check_source=False):
    safe(path)
    fd, temporary = tempfile.mkstemp(prefix='.mini-config-', dir=str(pathlib.Path(path).parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        if check_source and (os.path.lexists(path + 'c') or read_raw(path) != before):
            fail('conflict')
        os.replace(temporary, path)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def mutate(request, path=CONFIG):
    identity = request.get('id')
    validate_id(identity)
    with config_lock(path):
        config, before = load(path)
        providers = config.get('providers', {})
        existing = providers.get(identity)
        create = request.get('create') is True
        if create and identity in providers:
            fail('duplicate_id')
        if not create:
            if not isinstance(existing, dict) or existing.get('package') != PACKAGE:
                fail('not_found')
            if request.get('revision') != digest(existing):
                fail('conflict')
        if request['op'] == 'remove':
            providers.pop(identity)
            clean_references(config, identity)
        else:
            name = request.get('name', '').strip()
            if not name or len(name) > 128 or re.search(r'[\x00-\x1f\x7f]', name):
                fail('invalid_name')
            url = normalized_url(request.get('baseURL'))
            selected = model_ids(request.get('models'))
            entry = dict(existing or {})
            settings = dict(entry.get('settings', {}))
            mode = request.get('keyMode', 'keep')
            if mode == 'clear':
                settings.pop('apiKey', None)
            elif mode == 'replace':
                key = request.get('apiKey')
                if not isinstance(key, str) or not key or len(key) > 8192 or re.search(r'[\x00-\x1f\x7f]', key):
                    fail('invalid_key')
                settings['apiKey'] = key
            elif mode != 'keep':
                fail('invalid_key')
            if (existing and settings.get('apiKey') and mode == 'keep' and
                    url != normalized_url(existing.get('settings', {}).get('baseURL')) and
                    request.get('reuseKey') is not True):
                fail('key_origin')
            previous = entry.get('models', {})
            if not isinstance(previous, dict):
                fail('invalid_config')
            removed = set(previous) - set(selected)
            settings['baseURL'] = url
            entry.update(name=name, package=PACKAGE, settings=settings,
                         models={m: previous.get(m, {'name': m}) for m in selected})
            providers[identity] = entry
            clean_references(config, identity, removed)
        config['providers'] = providers
        raw = (json.dumps(config, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode()
        if len(raw) > MAX_BYTES:
            fail('too_large')
        if before is not None:
            atomic(path + '.mini-bak', before)
        atomic(path, raw, before, check_source=True)
        return {'ok': True}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Failure('redirect')


def fetch(request, path=CONFIG):
    base = normalized_url(request.get('baseURL'))
    key = request.get('apiKey', '')
    if request.get('keyMode') == 'clear':
        key = ''
    elif not key and request.get('id'):
        config, _ = load(path)
        old = config.get('providers', {}).get(request['id'], {})
        if not isinstance(old, dict) or old.get('package') != PACKAGE:
            fail('not_found')
        settings = old.get('settings', {})
        key = settings.get('apiKey', '')
        if key and base != normalized_url(settings.get('baseURL')) and request.get('reuseKey') is not True:
            fail('key_origin')
    if not isinstance(key, str) or re.search(r'[\x00-\x1f\x7f]', key):
        fail('invalid_key')
    if key.startswith(('{env:', '{file:')):
        fail('key_reference')
    if urllib.parse.urlsplit(base).scheme == 'http' and request.get('allowHttp') is not True:
        fail('http_consent')
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    deadline = time.monotonic() + 15
    candidates = [base]
    if not urllib.parse.urlsplit(base).path.endswith('/v1'):
        candidates.append(base + '/v1')
    for candidate in candidates:
        headers = {'Accept': 'application/json'}
        if key:
            headers['Authorization'] = 'Bearer ' + key
        req = urllib.request.Request(candidate + '/models', headers=headers)
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail('timeout')
            with opener.open(req, timeout=remaining) as response:
                raw = response.read(MAX_BYTES + 1)
                if len(raw) > MAX_BYTES:
                    fail('too_large')
            try:
                value = json.loads(raw)
            except Exception:
                fail('not_json')
            return {'ok': True, 'baseURL': candidate, 'models': parse_models(value)}
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            if status == 404 and candidate != candidates[-1]:
                continue
            raise Failure('auth' if status in (401, 403) else 'not_found_endpoint' if status == 404 else 'http_error', status)
        except (TimeoutError, socket.timeout):
            fail('timeout')
        except ssl.SSLError:
            fail('tls')
        except urllib.error.URLError as error:
            if isinstance(error.reason, ssl.SSLError):
                fail('tls')
            if isinstance(error.reason, (TimeoutError, socket.timeout)):
                fail('timeout')
            fail('network')
    fail('not_found_endpoint')


def execute(request, path=CONFIG):
    op = request.get('op')
    if op == 'list':
        config, _ = load(path)
        entries = config.get('providers', {})
        return {'ok': True, 'ids': list(entries), 'providers': [
            summary(k, v) for k, v in entries.items() if isinstance(v, dict) and
            v.get('package') == PACKAGE and k not in RESERVED]}
    if op in ('upsert', 'remove'):
        return mutate(request, path)
    if op == 'fetch':
        return fetch(request, path)
    fail('invalid_request')


def main():
    import sys
    os.umask(0o077)
    try:
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            fail('too_large')
        request = decode(raw)
        if not isinstance(request, dict):
            fail('invalid_request')
        result = execute(request)
    except Failure as error:
        result = {'ok': False, 'code': error.code}
        if error.status is not None:
            result['status'] = error.status
    except Exception:
        result = {'ok': False, 'code': 'storage'}
    # No exception strings, request echoes, response bodies or tracebacks.
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
