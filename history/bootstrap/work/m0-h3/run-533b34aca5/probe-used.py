"""H3 protocol test: simulate the user-side client; keep worker/user APIs separate."""
import json
import queue
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
from pathlib import Path

package = Path(__file__).parent
workspace = package.parent.parent
run = workspace / 'work/m0-h3' / ('run-' + uuid.uuid4().hex[:10])
run.mkdir(parents=True)
shutil.copyfile(Path(__file__), run / 'probe-used.py')
shutil.copyfile(package / 'mcp-decision-probe.py', run / 'mcp-decision-probe-used.py')
for qid in ('normal', 'stale', 'disconnect'):
    (run / f'{qid}-artifact.txt').write_text(f'H3 synthetic {qid} v1', encoding='utf-8')
(run / 'spec.txt').write_text('H3 synthetic decision scope v1', encoding='utf-8')
cases = [
    {'tool': 'ask', 'namespace': 'mcp__axiward_h3', 'arguments': {'question_id': 'normal', 'decision': 'approve', 'source': 'user'}},
    *[{'tool': 'ask', 'namespace': 'mcp__axiward_h3', 'arguments': {'question_id': qid}}
      for qid in ('normal', 'stale', 'disconnect')]]
(run / 'cases.json').write_text(json.dumps(cases), encoding='utf-8')
fixed = workspace / 'outputs/axiward-m0-h1/fixed-responses.py'
shutil.copyfile(fixed, run / 'fixed-responses-used.py')
fixture = subprocess.Popen([sys.executable, str(fixed), '--cases', str(run / 'cases.json'), '--evidence', str(run)],
                           stdout=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
server = None
port = None
event_file = (run / 'events.jsonl').open('w', encoding='utf-8')
error_file = (run / 'native-stderr.log').open('w', encoding='utf-8')
summary = {'status': 'running', 'userReplies': 'simulated by trusted test client', 'questionContexts': []}
try:
    deadline = time.monotonic() + 10
    while not (run / 'endpoint.json').exists():
        if fixture.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Fixture failed to start')
        time.sleep(0.1)
    port = json.loads((run / 'endpoint.json').read_text())['port']
    provider = f'model_providers.axiward_fixture = {{ name="H3 fixed fixture", base_url="http://127.0.0.1:{port}/v1", wire_api="responses", requires_openai_auth=false }}'
    mcp = ('mcp_servers.axiward_h3 = { command=' + json.dumps(sys.executable)
           + ', args=' + json.dumps([str(package / 'mcp-decision-probe.py'), '--root', str(run)]) + ', enabled=true }')
    command = ['codex', 'app-server', '--stdio', '-c', provider, '-c', mcp,
               '-c', 'mcp_servers.node_repl.enabled=false', '-c', 'mcp_servers.openaiDeveloperDocs.enabled=false',
               '--disable', 'apps', '--disable', 'plugins', '--disable', 'hooks', '--disable', 'multi_agent',
               '--disable', 'code_mode', '--disable', 'enable_request_compression', '--enable', 'skip_host_skill_discovery']
    server = subprocess.Popen(command, cwd=run, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=error_file,
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
        event_file.write(json.dumps(item, ensure_ascii=False) + '\n')
        event_file.flush()
        if item.get('method') == 'mcpServer/elicitation/request' and 'id' in item:
            params = item['params']
            if params['serverName'] != 'axiward_h3':
                send({'id': item['id'], 'result': {'action': 'decline'}})
            elif (params.get('_meta') or {}).get('codex_approval_kind') == 'mcp_tool_call':
                # Authorize only this synthetic server for the scoped integration test.
                send({'id': item['id'], 'result': {'action': 'accept', 'content': {}}})
            else:
                qid = params['message'].split('[', 1)[1].split(']', 1)[0]
                summary['questionContexts'].append({'question': qid, 'threadId': params['threadId'],
                                                    'turnId': params['turnId'], 'nativeRequestId': item['id']})
                if qid == 'stale':
                    (run / 'stale-artifact.txt').write_text('H3 changed after question was issued', encoding='utf-8')
                send({'id': item['id'], 'result': {'action': 'accept', 'content': {'decision': 'approve'}}})
        elif 'id' in item and 'method' in item:
            send({'id': item['id'], 'error': {'code': -32601, 'message': 'Not permitted by H3 fixture'}})
        return item
    def response(number):
        while True:
            item = receive()
            if item.get('id') == number and 'method' not in item:
                if 'error' in item:
                    raise RuntimeError(json.dumps(item['error']))
                return item['result']
    send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'axiward-h3-test','version':'0'},'capabilities':{'experimentalApi':True}}})
    response(1)
    send({'method':'initialized'})
    send({'id':2,'method':'thread/start','params':{'model':'axiward-h1-fixture','modelProvider':'axiward_fixture',
          'cwd':str(run),'sandbox':'danger-full-access','approvalPolicy':'on-request','ephemeral':True}})
    thread_id = response(2)['thread']['id']
    summary['targetThread'] = thread_id
    send({'id':3,'method':'turn/start','params':{'threadId':thread_id,
          'input':[{'type':'text','text':'Run the four predefined H3 protocol cases only.','text_elements':[]}]}})
    response(3)
    while True:
        item = receive()
        if item.get('method') == 'turn/completed':
            summary['completedThread'] = item['params']['threadId']
            break
    last = json.loads((run / 'request-04.json').read_text(encoding='utf-8'))
    outputs = [json.dumps(item['output'], ensure_ascii=False) for item in last['toolOutputs']]
    assert len(outputs) == 4, outputs
    assert 'WORKER_CANNOT_DECIDE_OR_SET_SOURCE' in outputs[0]
    assert 'DECISION_RECORDED' in outputs[1]
    assert 'STALE_SCOPE' in outputs[2]
    assert 'error' in outputs[3].lower() or 'closed' in outputs[3].lower()
    assert (run / 'normal-decision.json').exists()
    assert not (run / 'stale-decision.json').exists()
    assert (run / 'stale-stale-answer.json').exists()
    assert (run / 'disconnect-decision.json').exists()
    assert (run / 'disconnect-notification-pending.json').exists()
    assert len(summary['questionContexts']) == 3
    assert all(item['threadId'] == thread_id for item in summary['questionContexts'])
    assert summary['completedThread'] == thread_id
    summary.update(status='passed', checks={
        'worker-cannot-claim-user-source': True,
        'decision-bound-to-artifact-and-spec': True,
        'stale-answer-not-applied': True,
        'native-callback-resumes-original-task': True,
        'decision-survives-notification-failure': True})
except Exception as error:
    summary['status'] = 'failed'
    summary['error'] = str(error)
    raise
finally:
    (run / 'result.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
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
    event_file.close()
    error_file.close()
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print('Evidence:', run)
