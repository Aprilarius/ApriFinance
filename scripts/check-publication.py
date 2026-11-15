"""Fail closed on private files or credential material; never print matches."""
import argparse
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile

PRIVATE_SUFFIXES = {'.sqlite', '.sqlite-wal', '.sqlite-shm', '.sqlite3', '.db', '.mfin',
                    '.pdf', '.jpg', '.jpeg', '.csv', '.tsv', '.jks', '.keystore',
                    '.pfx', '.p12', '.pem', '.private', '.key', '.enc'}
PRIVATE_NAMES = {'cloud.json', 'insights.json', 'reminders.json', 'key.properties',
                 'local.properties', '.env', 'AGENTS.md', '.flutter-plugins-dependencies'}
FAKE_SECRET_KEYS = {b'sb_secret_fictional_key', b'sb_secret_not_for_apps'}
JWT = re.compile(rb'eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}')
SECRET = re.compile(rb'sb_secret_[A-Za-z0-9_-]{10,}')
PRIVATE_PEM = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----\s+[A-Za-z0-9+/=\r\n]{64,}-----END (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----')


def check(name, content):
    path = PurePosixPath(name.replace('\\', '/'))
    if path.is_absolute() or '..' in path.parts or re.match(r'^[A-Za-z]:', name):
        raise SystemExit(f'Publication rejected: unsafe path {name}')
    if path.suffix.lower() in PRIVATE_SUFFIXES or path.name in PRIVATE_NAMES or path.name.startswith(('.env', 'aprifinance.cloud.credentials.')):
        raise SystemExit(f'Publication rejected: private file {name}')
    if JWT.search(content) or PRIVATE_PEM.search(content):
        raise SystemExit(f'Publication rejected: credential material in {name}')
    if any(match.group() not in FAKE_SECRET_KEYS for match in SECRET.finditer(content)):
        raise SystemExit(f'Publication rejected: administrative key in {name}')
    if path.suffix.lower() == '.json':
        try:
            data = json.loads(content)
        except (ValueError, UnicodeDecodeError):
            data = None
        def contains_secret(value):
            if isinstance(value, dict):
                if any(str(k).lower().replace('_', '') in {
                    'accesstoken', 'refreshtoken', 'copypassword', 'password',
                } and isinstance(v, str) and v for k, v in value.items()):
                    return True
                return any(contains_secret(v) for v in value.values())
            return isinstance(value, list) and any(contains_secret(v) for v in value)
        if contains_secret(data):
            raise SystemExit(f'Publication rejected: saved credentials in {name}')


def scan_payload(root):
    root = Path(root).resolve()
    checked = set()
    for path in root.rglob('*'):
        resolved = path.resolve()
        if not resolved.is_relative_to(root):
            raise SystemExit('Publication rejected: payload symlink escapes root')
        if not path.is_file() or resolved in checked:
            continue
        checked.add(resolved)
        check(path.relative_to(root).as_posix(), path.read_bytes())
    if not checked:
        raise SystemExit('Publication rejected: empty payload')
    return len(checked)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--payload')
    parser.add_argument('--archive')
    args = parser.parse_args()
    if args.payload:
        count = scan_payload(args.payload)
    elif args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            if archive.testzip() is not None:
                raise SystemExit('Publication rejected: corrupt archive')
            count = 0
            for entry in archive.infolist():
                if not entry.is_dir():
                    if entry.file_size > 256 * 1024 * 1024:
                        raise SystemExit('Publication rejected: oversized member')
                    check(entry.filename, archive.read(entry))
                    count += 1
    else:
        names = subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0')
        count = 0
        for name in filter(None, names):
            check(name, Path(name).read_bytes())
            count += 1
    print(f'Publication scan passed: {count} files; no private records or credential material detected')


if __name__ == '__main__':
    main()
