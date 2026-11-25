#!/usr/bin/env python3
"""Compile the same policy used by Rust into Swift; no runtime trust overrides."""
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit
policy=json.loads(Path(sys.argv[1]).read_text())
assert policy['serverCertificatePolicy']=='windows-compatible'
url=urlsplit(policy['defaultGateway'])
assert url.scheme=='https' and url.hostname and not url.username and not url.password
assert isinstance(policy.get('defaultPortalGateway'),str) and policy['defaultPortalGateway'].strip()
assert policy['defaultDomain']
output=Path(sys.argv[2]);output.parent.mkdir(parents=True,exist_ok=True)
output.write_text('enum GatewayPolicy {\n'+''.join(
    '    static let '+key+' = '+json.dumps(policy[key])+'\n'
    for key in ['defaultGateway','defaultPortalGateway','defaultDomain','serverCertificatePolicy'])+'}\n')
