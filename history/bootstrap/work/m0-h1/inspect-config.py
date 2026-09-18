import json
import queue
import subprocess
import threading
from pathlib import Path

root = Path(__file__).parent
view = root / 'lab' / 'view'
prior = json.loads((root / 'evidence/harness-run-03/codex-arguments.json').read_text(encoding='utf-8-sig'))
overrides = []
for i, arg in enumerate(prior[:-1]):
    if arg == '-c':
        overrides.extend(['-c', prior[i+1]])
proc = subprocess.Popen(['codex', 'app-server', '--stdio', *overrides],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW)
messages = queue.Queue()
def read_lines():
    for line in proc.stdout:
        messages.put(json.loads(line))
threading.Thread(target=read_lines, daemon=True).start()
def send(item):
    proc.stdin.write(json.dumps(item) + '\n')
    proc.stdin.flush()
def wait_for(number):
    while True:
        item = messages.get(timeout=15)
        if item.get('id') == number:
            return item
try:
    send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'axiward-h1-config-inspector','version':'0'},'capabilities':{'experimentalApi':True}}})
    wait_for(1)
    send({'method':'initialized'})
    send({'id':2,'method':'config/read','params':{'cwd':str(view),'includeLayers':True}})
    result = wait_for(2)
    data = result.get('result', {})
    filtered = {
        'error': result.get('error'),
        'layers': [{k:v for k,v in layer.items() if k != 'config'} for layer in data.get('layers', [])],
        'selectedConfig': {k:v for k,v in data.get('config', {}).items()
                           if k in ('projects','default_permissions','sandbox_mode','permissions')},
    }
    output = json.dumps(filtered, ensure_ascii=False, indent=2)
    (root / 'evidence/config-layer-inspection.json').write_text(output, encoding='utf-8')
    print(output)
finally:
    proc.stdin.close()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.terminate()
        proc.wait(timeout=5)
