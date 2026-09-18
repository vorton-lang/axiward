"""H1-only stdio adapter: two fixed commands against a synthetic repository."""
import argparse
import json
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--exe', required=True)
args = parser.parse_args()

for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request:
        continue
    method = request['method']
    error = None
    if method == 'initialize':
        result = {'protocolVersion': request['params']['protocolVersion'],
                  'capabilities': {'tools': {}},
                  'serverInfo': {'name': 'axiward-h1-probe', 'version': '0'}}
    elif method == 'tools/list':
        result = {'tools': [
            {'name': name, 'description': 'H1 synthetic fixed-path ' + name + ' probe.',
             'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}}
            for name in ('status', 'submit')]}
    elif method == 'tools/call':
        params = request.get('params', {})
        name = params.get('name')
        if name not in ('status', 'submit') or params.get('arguments', {}) != {}:
            result = {'isError': True, 'content': [{'type': 'text', 'text': 'H1 rejected command or arguments'}]}
        else:
            process = subprocess.run([args.exe, name], capture_output=True, text=True,
                                     encoding='utf-8', timeout=10,
                                     creationflags=subprocess.CREATE_NO_WINDOW)
            result = {'isError': process.returncode != 0, 'content': [{'type': 'text', 'text':
                json.dumps({'exitCode': process.returncode, 'stdout': process.stdout, 'stderr': process.stderr})}]}
    elif method == 'ping':
        result = {}
    else:
        error = {'code': -32601, 'message': 'H1 exposes only status and submit'}
    response = {'jsonrpc': '2.0', 'id': request['id']}
    response['error' if error else 'result'] = error if error else result
    print(json.dumps(response), flush=True)
