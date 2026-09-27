"""Install an approved, hash-pinned public teaching bundle. No database access."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import stat
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('archive', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--render-commit', required=True)
    parser.add_argument('--render-run', required=True)
    args = parser.parse_args()
    assert re.fullmatch('[0-9a-f]{64}', args.sha256), 'Missing approved ZIP hash'
    assert hashlib.sha256(args.archive.read_bytes()).hexdigest() == args.sha256, 'ZIP content changed'
    with zipfile.ZipFile(args.archive) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        assert len(names) == len(set(names)) and len(names) < 40, 'Unexpected entry count'
        assert sum(entry.file_size for entry in entries) < 210_000_000, 'Oversized teaching bundle'
        for entry in entries:
            assert re.fullmatch('[A-Za-z0-9_.-]+', entry.filename) and not entry.is_dir(), 'Unexpected directory or path'
            assert not stat.S_ISLNK(entry.external_attr >> 16), 'Symlink rejected'
        data = json.loads(archive.read('tutorials.json'))
        checks = json.loads(archive.read('player-checks.json'))
        assert data['version'] == '3.1.3' and data['language'] == 'es' and len(data['videos']) == 2
        assert data['build_commit'] == args.render_commit and str(data['render_run']) == args.render_run, 'Wrong approved render'
        assert checks['failed'] == 0 and checks['passed'] >= 20, 'Player acceptance missing'
        assert set(names) == set(data['files']) | {'tutorials.json'}, 'Unmanifested files'
        for name, digest in data['files'].items():
            assert hashlib.sha256(archive.read(name)).hexdigest() == digest, 'Hash mismatch: ' + name
        assert sum(len(video['chapters']) for video in data['videos']) == 32
        for video in data['videos']:
            assert video['checks']['h264_aac'] and video['checks']['full_decode'] and video['checks']['embedded_chapters']
            assert hashlib.sha256(archive.read(video['file'])).hexdigest() == video['sha256']
            assert len(archive.read(video['file'])) == video['bytes'] and 10 < video['duration_seconds'] < 1200
            text = archive.read(video['transcript']).decode('utf-8')
            assert not re.search('[\u3400-\u9fff]|Super Admin|jaimehuang168@gmail', text)
        args.destination.mkdir(parents=True, exist_ok=True)
        assert not any(args.destination.iterdir()), 'Destination must be empty; do not overwrite unrelated files'
        for entry in entries:
            (args.destination / entry.filename).write_bytes(archive.read(entry))
        report = {
            'installed': 'tutoriales',
            'version': data['version'],
            'render_run': data['render_run'],
            'zip_sha256': args.sha256,
            'videos': [
                {'id': video['id'], 'seconds': video['duration_seconds'], 'bytes': video['bytes']}
                for video in data['videos']
            ],
        }
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
