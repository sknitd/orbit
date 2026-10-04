#!/usr/bin/env python3
"""Snapshot named providers' public documentation; never call an account API."""
import hashlib
import json
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

LIMIT = 8_388_608
ALLOWED_HOSTS = {'aviationstack.com', 'docs.apilayer.com', 'www.api-football.com', 'raw.githubusercontent.com'}


class DocumentationRedirect(HTTPRedirectHandler):
    max_redirections = 4
    max_repeats = 2

    def redirect_request(self, request, file, code, message, headers, new_url):
        target = urlsplit(new_url)
        if (target.scheme != 'https' or target.hostname not in ALLOWED_HOSTS
                or target.username is not None or target.password is not None
                or target.port not in (None, 443)):
            return None
        return super().redirect_request(request, file, code, message, headers, new_url)

root = Path(__file__).resolve().parent.parent / 'build' / 'provider-docs'
root.mkdir(parents=True, exist_ok=True)
records = []
for name, url, markers in [
    ('aviationstack', 'https://aviationstack.com/documentation', ['flight_iata', 'flight_status', 'access_key', 'https://api.aviationstack.com/v1/flights']),
    ('aviationstack-api-documentation', 'https://docs.apilayer.com/aviationstack/docs/api-documentation',
     ['flight_iata', 'flight_status', 'access_key', 'api.aviationstack.com/v1/flights', 'scheduled', 'estimated', 'departure', 'arrival', 'gate', 'limit']),
    ('api-sports', 'https://www.api-football.com/documentation-v3', ['teams', 'search', 'x-apisports-key', 'v3.football.api-sports.io']),
    ('api-sports-sdk-teams', 'https://raw.githubusercontent.com/api-sports/api-sports/55887ecf0d5b2a494162561ead5a244dd7f64f56/src/API-Football.SDK/V3/Teams.cs',
     ['teams?', 'season=', 'league=', 'search']),
]:
    record = {'provider': name, 'url': url, 'account_api_called': False}
    if name == 'api-sports-sdk-teams':
        record.update(source_commit='55887ecf0d5b2a494162561ead5a244dd7f64f56',
                      evidence_scope='Official SDK documents season/league queries; this file does not establish support for teams?search.')
    suffix = '.cs' if name == 'api-sports-sdk-teams' else '.html'
    artifact = root / (name + suffix)
    artifact.unlink(missing_ok=True)
    (root / (name + '.error-response.txt')).unlink(missing_ok=True)
    try:
        with build_opener(DocumentationRedirect()).open(Request(url, headers={'User-Agent': 'NotchOrbitPlus-documentation-verification/0.3'}), timeout=25) as response:
            body = response.read(LIMIT + 1)
            if len(body) > LIMIT:
                raise ValueError('Documentation exceeds 8 MB snapshot bound.')
            text = body.decode('utf-8', errors='replace')
            record.update(status=response.status, bytes=len(body), sha256=hashlib.sha256(body).hexdigest(),
                          final_url=response.geturl(), response_file=artifact.name,
                          markers={marker: marker in text for marker in markers})
            artifact.write_bytes(body)
    except HTTPError as error:
        body = error.read(LIMIT + 1)[:LIMIT]
        error_artifact = root / (name + '.error-response.txt')
        error_artifact.write_bytes(body)
        record.update(status=error.code, error=str(error), bytes=len(body),
                      sha256=hashlib.sha256(body).hexdigest(), response_file=error_artifact.name)
    except Exception as error:
        record['error'] = str(error)
    records.append(record)
(root / 'documentation-probes.json').write_text(json.dumps(records, indent=2) + '\n')
print(json.dumps(records, indent=2))
