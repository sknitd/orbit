#!/usr/bin/env python3
"""Snapshot named providers' public documentation; never call an account API."""
import hashlib
import json
from pathlib import Path
from urllib.request import Request, urlopen

root = Path(__file__).resolve().parent.parent / 'build' / 'provider-docs'
root.mkdir(parents=True, exist_ok=True)
records = []
for name, url, markers in [
    ('aviationstack', 'https://aviationstack.com/documentation', ['flight_iata', 'flight_status', 'access_key', 'https://api.aviationstack.com/v1/flights']),
    ('api-sports', 'https://www.api-football.com/documentation-v3', ['teams', 'search', 'x-apisports-key', 'v3.football.api-sports.io']),
]:
    record = {'provider': name, 'url': url, 'account_api_called': False}
    try:
        with urlopen(Request(url, headers={'User-Agent': 'NotchOrbitPlus-documentation-verification/0.3'}), timeout=25) as response:
            body = response.read(8_388_609)
            if len(body) > 8_388_608:
                raise ValueError('Documentation exceeds 8 MB snapshot bound.')
            text = body.decode('utf-8', errors='replace')
            record.update(status=response.status, bytes=len(body), sha256=hashlib.sha256(body).hexdigest(),
                          markers={marker: marker in text for marker in markers})
            (root / (name + '.html')).write_bytes(body)
    except Exception as error:
        record['error'] = str(error)
    records.append(record)
(root / 'documentation-probes.json').write_text(json.dumps(records, indent=2) + '\n')
print(json.dumps(records, indent=2))
