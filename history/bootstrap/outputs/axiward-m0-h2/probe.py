"""H2: native command/exec provenance and complete-output probe; no LLM calls."""
import base64
import copy
import hashlib
import json
import os
import queue
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

package = Path(__file__).parent
work = package.parent.parent / 'work/m0-h2'
work.mkdir(parents=True, exist_ok=True)
run = work / ('run-' + uuid.uuid4().hex[:10])
snapshot = run / 'snapshot'
snapshot.mkdir(parents=True)
task_id = os.environ.get('CODEX_THREAD_ID')
if not task_id:
    raise RuntimeError('Native parent task identity is unavailable')
(snapshot / 'input.txt').write_text('H2 fixed input version 1', encoding='utf-8')
program = '''import sys
from pathlib import Path
value = Path("input.txt").read_text(encoding="utf-8")
sys.stdout.buffer.write(("{\\"claim\\":\\"PASS\\",\\"claimedExitCode\\":0}\\n" + value + "\\n").encode() + b"X" * 200000)
sys.stdout.buffer.flush()
sys.stderr.buffer.write(b"E" * 70000)
sys.stderr.buffer.flush()
sys.exit(7)
'''
(snapshot / 'observation.py').write_text(program, encoding='utf-8')
def digest(data):
    return hashlib.sha256(data).hexdigest()
def input_version():
    values = {p.name: digest(p.read_bytes()) for p in sorted(snapshot.iterdir())}
    return digest(json.dumps(values, sort_keys=True).encode())
version = input_version()
context = {'taskId': task_id, 'workPackage': 'M0-H2', 'inputVersion': version}
events = (run / 'native-events.jsonl').open('w', encoding='utf-8')
errors = (run / 'native-stderr.log').open('w', encoding='utf-8')
server = subprocess.Popen(['codex', 'app-server', '--stdio'], cwd=snapshot,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                          text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW)
messages = queue.Queue()
def reader():
    for line in server.stdout:
        messages.put(json.loads(line))
threading.Thread(target=reader, daemon=True).start()
def send(item):
    server.stdin.write(json.dumps(item) + '\n')
    server.stdin.flush()
def receive():
    item = messages.get(timeout=30)
    events.write(json.dumps(item, ensure_ascii=False) + '\n')
    events.flush()
    return item
def wait_response(number):
    while True:
        item = receive()
        if item.get('id') == number:
            if 'error' in item:
                raise RuntimeError(json.dumps(item['error']))
            return item['result']

# Only the trusted collector registers observations. Consumers use IDs, not
# arbitrary JSON supplied by the worker, to request evidence from this store.
store = {}
def collect(number, cap):
    process_id = 'h2-' + uuid.uuid4().hex
    params = {'command': [sys.executable, str(snapshot / 'observation.py')],
              'cwd': str(snapshot), 'processId': process_id,
              'streamStdoutStderr': True, 'timeoutMs': 10000,
              'sandboxPolicy': {'type': 'dangerFullAccess'}}
    if cap is None:
        params['disableOutputCap'] = True
    else:
        params['outputBytesCap'] = cap
    send({'id': number, 'method': 'command/exec', 'params': params})
    streams = {'stdout': bytearray(), 'stderr': bytearray()}
    capped = False
    while True:
        item = receive()
        if item.get('method') == 'command/exec/outputDelta':
            delta = item['params']
            if delta['processId'] != process_id:
                raise RuntimeError('Unexpected process identity on native stream')
            streams[delta['stream']].extend(base64.b64decode(delta['deltaBase64'], validate=True))
            capped |= delta['capReached']
        elif item.get('id') == number:
            if 'error' in item:
                raise RuntimeError(json.dumps(item['error']))
            result = item['result']
            break
    reference = uuid.uuid4().hex
    stream_files = {}
    for stream, data in streams.items():
        path = run / f'{reference}-{stream}.bin'
        path.write_bytes(data)
        stream_files[stream] = {'path': str(path), 'bytes': len(data), 'sha256': digest(data)}
    record = {**context, 'reference': reference, 'processId': process_id,
              'requestId': number, 'command': params['command'], 'cwd': params['cwd'],
              'pythonSha256': digest(Path(sys.executable).read_bytes()),
              'exitCode': result['exitCode'], 'capReached': capped,
              'completionReceived': True, 'inputUnchanged': input_version() == version,
              'streams': stream_files}
    store[reference] = record
    (run / f'{reference}.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    return reference

def admit(reference, expected_context):
    if not isinstance(reference, str) or reference not in store:
        return False, 'unknown-source-reference'
    record = store[reference]
    if any(record[key] != value for key, value in expected_context.items()):
        return False, 'context-or-version-mismatch'
    if not record['completionReceived'] or record['capReached'] or not record['inputUnchanged']:
        return False, 'incomplete-observation'
    for stream in record['streams'].values():
        data = Path(stream['path']).read_bytes()
        if len(data) != stream['bytes'] or digest(data) != stream['sha256']:
            return False, 'stored-output-changed'
    return True, 'complete-native-observation'

try:
    send({'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'axiward-h2-probe', 'version': '0'}, 'capabilities': {'experimentalApi': True}}})
    wait_response(1)
    send({'method': 'initialized'})
    complete = collect(10, None)
    truncated = collect(11, 128)
    results = {}
    results['complete'] = admit(complete, context)
    results['forged-json'] = admit({'source': 'harness', 'exitCode': 0}, context)
    results['wrong-task'] = admit(complete, {**context, 'taskId': 'another-task'})
    results['wrong-version'] = admit(complete, {**context, 'inputVersion': '0' * 64})
    results['native-output-cap'] = admit(truncated, context)
    pending = copy.deepcopy(store[complete])
    pending['completionReceived'] = False
    store['pending-test'] = pending
    results['missing-completion'] = admit('pending-test', context)
    changed = copy.deepcopy(store[complete])
    altered_path = run / 'altered-output.bin'
    altered_path.write_bytes(Path(changed['streams']['stdout']['path']).read_bytes()[:-1])
    changed['streams']['stdout']['path'] = str(altered_path)
    store['changed-output-test'] = changed
    results['changed-output'] = admit('changed-output-test', context)
    stdout = Path(store[complete]['streams']['stdout']['path']).read_bytes()
    expected_stdout = b'{"claim":"PASS","claimedExitCode":0}\nH2 fixed input version 1\n' + b'X' * 200000
    assert stdout == expected_stdout
    assert store[complete]['streams']['stderr']['bytes'] == 70000
    assert store[complete]['exitCode'] == 7
    assert results['complete'][0]
    assert all(not value[0] for name, value in results.items() if name != 'complete')
    summary = {'status': 'passed', 'context': context, 'checks': results,
               'completeReference': complete, 'truncatedReference': truncated,
               'observedExitCode': 7, 'stdoutBytes': len(stdout), 'stderrBytes': 70000,
               'note': 'A complete observation of failure is valid evidence; stdout PASS is not a success proof.'}
    (run / 'result.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps(summary, indent=2))
    print('Evidence:', run)
finally:
    server.stdin.close()
    try:
        server.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server.terminate()
        server.wait(timeout=5)
    events.close()
    errors.close()
