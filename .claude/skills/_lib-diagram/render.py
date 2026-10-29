"""Build an offline HTML view from a validated, normalised diagram model."""

import base64
import hashlib
import json
from pathlib import Path
import re

from layout import layout
from model import model_hash

TEMPLATE = Path(__file__).with_name('view.html')
SLOTS = re.compile(r'\{\{(CSP|DATA)\}\}')


def digest(body):
    return base64.b64encode(hashlib.sha256(body.encode('ascii')).digest()).decode('ascii')


def render(model, template=None):
    """Return ASCII HTML. The caller must validate before calling this function."""
    if template is None:
        template = TEMPLATE.read_text(encoding='ascii')
    for name in ('CSP', 'DATA'):
        if template.count('{{' + name + '}}') != 1:
            raise ValueError('Each template slot must occur exactly once.')
    script = re.findall(r'<script>(.*?)</script>', template, re.S)
    style = re.findall(r'<style>(.*?)</style>', template, re.S)
    if len(script) != 1 or len(style) != 1:
        raise ValueError('Expected one executable script and one style block.')
    csp = ("default-src 'none'; base-uri 'none'; form-action 'none'; "
           "script-src 'sha256-" + digest(script[0]) + "'; "
           "style-src 'sha256-" + digest(style[0]) + "'")
    payload = dict(model, positions=layout(model), model_sha256=model_hash(model))
    data = json.dumps(payload, sort_keys=True, ensure_ascii=True, separators=(',', ':'))
    for char, escaped in (('<', '\\u003c'), ('>', '\\u003e'), ('&', '\\u0026')):
        data = data.replace(char, escaped)
    values = {'CSP': csp, 'DATA': data}
    return SLOTS.sub(lambda match: values[match.group(1)], template)
