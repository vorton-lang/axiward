"""Synthetic H3 user-channel probe. No decision tool is exposed to the worker."""
import argparse
import hashlib
import json
import os
import sys
import uuid
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=Path, required=True)
args = parser.parse_args()
root = args.root
pending = {}

def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def emit(item):
    print(json.dumps(item), flush=True)

def tool_result(request_id, text, error=False):
    emit({'jsonrpc': '2.0', 'id': request_id, 'result': {
        'isError': error, 'content': [{'type': 'text', 'text': text}]}})

def store_once(path, value):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())

for line in sys.stdin:
    request = json.loads(line)
    if 'method' not in request and request.get('id') in pending:
        item = pending.pop(request['id'])
        answer = request.get('result', {})
        qid = item['question']
        if answer.get('action') != 'accept':
            tool_result(item['toolRequest'], 'NO_USER_DECISION', True)
            continue
        decision = answer.get('content', {}).get('decision')
        if decision not in ('approve', 'reject'):
            tool_result(item['toolRequest'], 'INVALID_USER_DECISION', True)
            continue
        if (fingerprint(root / f'{qid}-artifact.txt') != item['artifactVersion'] or
                fingerprint(root / 'spec.txt') != item['specVersion']):
            store_once(root / f'{qid}-stale-answer.json', {'question': qid, 'decision': decision, 'applied': False})
            tool_result(item['toolRequest'], 'STALE_SCOPE: user answer was not applied', True)
            continue
        record = {**item, 'decision': decision, 'source': 'native-mcp-elicitation-test-client'}
        store_once(root / f'{qid}-decision.json', record)
        store_once(root / f'{qid}-notification-pending.json', {'question': qid, 'recorded': True})
        if qid == 'disconnect':
            # Controlled fault: the decision is durable before notification fails.
            os._exit(0)
        tool_result(item['toolRequest'], 'DECISION_RECORDED ' + json.dumps(record))
        continue
    if 'id' not in request:
        continue
    method = request.get('method')
    if method == 'initialize':
        emit({'jsonrpc': '2.0', 'id': request['id'], 'result': {
            'protocolVersion': request['params']['protocolVersion'],
            'capabilities': {'tools': {}}, 'serverInfo': {'name': 'axiward-h3-probe', 'version': '0'}}})
    elif method == 'tools/list':
        emit({'jsonrpc': '2.0', 'id': request['id'], 'result': {'tools': [{
            'name': 'ask', 'description': 'H3 synthetic request to the separate user channel.',
            'inputSchema': {'type': 'object', 'properties': {'question_id': {'type': 'string'}},
                            'required': ['question_id'], 'additionalProperties': False}}]}})
    elif method == 'tools/call':
        params = request.get('params', {})
        data = params.get('arguments', {})
        if params.get('name') != 'ask' or set(data) != {'question_id'}:
            tool_result(request['id'], 'WORKER_CANNOT_DECIDE_OR_SET_SOURCE', True)
            continue
        qid = data['question_id']
        if qid not in ('normal', 'stale', 'disconnect'):
            tool_result(request['id'], 'UNKNOWN_QUESTION', True)
            continue
        key = 'h3-' + uuid.uuid4().hex
        pending[key] = {'question': qid, 'toolRequest': request['id'], 'elicitationId': key,
                        'artifactVersion': fingerprint(root / f'{qid}-artifact.txt'),
                        'specVersion': fingerprint(root / 'spec.txt')}
        emit({'jsonrpc': '2.0', 'id': key, 'method': 'elicitation/create', 'params': {
            'mode': 'form', 'message': f'H3 QUESTION [{qid}] — synthetic artifact approval.',
            'requestedSchema': {'type': 'object', 'properties': {'decision': {
                'type': 'string', 'enum': ['approve', 'reject']}}, 'required': ['decision']}}})
    else:
        emit({'jsonrpc': '2.0', 'id': request['id'], 'error': {'code': -32601, 'message': 'Unsupported H3 method'}})
