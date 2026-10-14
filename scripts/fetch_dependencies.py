"""Fetch pinned source dependencies only. Never downloads model files."""
from pathlib import Path
import hashlib
import io
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEPENDENCIES = (
    ('llama.cpp', 'ggml-org/llama.cpp', 'd81235049384534c167caea52b85a694f6103d14',
     '6b58785f0a82898f4c3442417ff962e2d4b231b1bee5d033902ad90b27901e14'),
    ('godot-cpp', 'godotengine/godot-cpp', 'e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77',
     'd4c03daf46c8bef4544614182b0762c3e32789151c7f8f44e8eb2053d5cddeba'),
)

def main():
    vendor = ROOT / 'vendor'
    vendor.mkdir(exist_ok=True)
    (vendor / '.gdignore').touch()
    for name, repo, revision, digest in DEPENDENCIES:
        target = vendor / name
        marker = target / '.demo_revision'
        if marker.exists() and marker.read_text().strip() == revision:
            print(f'{name}: already prepared')
            continue
        if target.exists():
            raise SystemExit(f'{target} exists without the expected revision marker. Move it aside before rebuilding.')
        url = f'https://github.com/{repo}/archive/{revision}.tar.gz'
        print(f'Fetching {repo}@{revision}')
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit(f'{name}: source archive checksum mismatch')
        with tempfile.TemporaryDirectory(dir=vendor) as staging:
            base = Path(staging)
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
                for item in archive.getmembers():
                    resolved = (base / item.name).resolve()
                    if not resolved.is_relative_to(base.resolve()) or item.issym() or item.islnk():
                        raise SystemExit('Unsafe dependency archive entry')
                archive.extractall(base, filter='data')
            folders = list(base.iterdir())
            if len(folders) != 1 or not folders[0].is_dir():
                raise SystemExit('Unexpected source archive layout')
            shutil.move(str(folders[0]), target)
        marker.write_text(revision + '\n')
    print('Dependencies ready. GGUF must be provided manually.')

if __name__ == '__main__':
    main()
