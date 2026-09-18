"""Run fixed H1 calls through the desktop-style app-server API.

All interactive approval requests are declined. This is an ephemeral, local,
deterministic harness test, not an additional LLM agent.
"""
import argparse
import json
import queue
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--cases', type=Path, required=True)
parser.add_argument('--label', required=True)
args = parser.parse_args()
package = Path(__file__).parent
work = package.parent.parent / 'work/m0-h1'
view = work / 'lab/view'
run = work / 'evidence' / args.label
run.mkdir()
for source, name in [(Path(__file__), 'run-app-server-used.py'),
                     (package / 'fixed-responses.py', 'fixed-responses-used.py'),
                     (args.cases, 'cases.json'),
                     (view / '.codex/rules/axiward-probe.rules', 'rules-used.rules')]:
    shutil.copyfile(source, run / name)
fixture = subprocess.Popen([sys.executable, str(run / 'fixed-responses-used.py'),
                            '--cases', str(args.cases.resolve()), '--evidence', str(run)],
                           stdout=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
server = None
port = None
approvals = []
summary = {'status': 'running', 'interactiveApprovals': approvals}
events_file = (run / 'events.jsonl').open('w', encoding='utf-8')
stderr_file = (run / 'app-server-stderr.log').open('w', encoding='utf-8')
try:
    deadline = time.monotonic() + 10
    while not (run / 'endpoint.json').exists():
        if fixture.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Fixture startup failed')
        time.sleep(0.1)
    port = json.loads((run / 'endpoint.json').read_text())['port']
    old = json.loads((work / 'evidence/harness-run-12/codex-arguments.json').read_text(encoding='utf-8-sig'))
    overrides = []
    for i, value in enumerate(old[:-1]):
        if value in ('-c', '--disable', '--enable'):
            setting = old[i+1]
            if setting.startswith('model_providers.axiward_fixture'):
                start = setting.index('http://127.0.0.1:')
                end = setting.index('/v1', start)
                setting = setting[:start] + f'http://127.0.0.1:{port}' + setting[end:]
            overrides.extend([value, setting])
    command = ['codex', 'app-server', '--stdio', *overrides]
    (run / 'server-arguments.json').write_text(json.dumps(command, indent=2), encoding='utf-8')
    server = subprocess.Popen(command, cwd=view, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=stderr_file, text=True, encoding='utf-8',
                              creationflags=subprocess.CREATE_NO_WINDOW)
    messages = queue.Queue()
    def reader():
        for line in server.stdout:
            try:
                messages.put(json.loads(line))
            except json.JSONDecodeError:
                messages.put({'nonJson': line})
    threading.Thread(target=reader, daemon=True).start()
    def send(value):
        server.stdin.write(json.dumps(value) + '\n')
        server.stdin.flush()
    def receive():
        item = messages.get(timeout=30)
        events_file.write(json.dumps(item, ensure_ascii=False) + '\n')
        events_file.flush()
        if 'id' in item and 'method' in item:
            approvals.append(item['method'])
            if item['method'] == 'item/commandExecution/requestApproval':
                send({'id': item['id'], 'result': {'decision': 'decline'}})
            else:
                send({'id': item['id'], 'error': {'code': -32601, 'message': 'Not allowed by fixed H1 fixture'}})
        return item
    def response(number):
        while True:
            item = receive()
            if item.get('id') == number and 'method' not in item:
                if 'error' in item:
                    raise RuntimeError(json.dumps(item['error']))
                return item['result']
    send({'id':1, 'method':'initialize', 'params':{'clientInfo':{'name':'axiward-h1-test','version':'0'}, 'capabilities':{'experimentalApi':True}}})
    response(1)
    send({'method':'initialized'})
    send({'id':2, 'method':'thread/start', 'params':{
        'model':'axiward-h1-fixture', 'modelProvider':'axiward_fixture',
        'cwd':str(view), 'permissions':'axiward_h1', 'approvalPolicy':'on-request',
        'ephemeral':True}})
    started = response(2)
    thread_id = started['thread']['id']
    summary['effectiveApprovalPolicy'] = started.get('approvalPolicy')
    summary['threadId'] = thread_id
    send({'id':3, 'method':'turn/start', 'params':{
        'threadId':thread_id, 'permissions':'axiward_h1', 'approvalPolicy':'on-request',
        'input':[{'type':'text','text':'Run the predefined synthetic H1 cases. No other actions.','text_elements':[]}]}})
    response(3)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        item = receive()
        if item.get('method') == 'turn/completed':
            summary['turn'] = item['params']['turn']
            summary['status'] = 'completed'
            break
    else:
        raise TimeoutError('Fixed H1 sequence did not finish')
except Exception as error:
    summary['status'] = 'failed'
    summary['error'] = str(error)
    raise
finally:
    (run / 'driver-result.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    if server:
        server.stdin.close()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.terminate()
            server.wait(timeout=5)
    if port:
        try:
            urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}/stop', data=b''), timeout=3).close()
        except OSError:
            pass
    try:
        fixture.wait(timeout=5)
    except subprocess.TimeoutExpired:
        fixture.terminate()
        fixture.wait(timeout=5)
    events_file.close()
    stderr_file.close()
    print(json.dumps(summary, ensure_ascii=False, indent=2))
