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
    ('llama.cpp', 'ggml-org/llama.cpp', 'a9d27ac693ff0a1d3cba449c912c2b891904a4c7',
     '8ea0196592a372457ab88c0f23497e9030b4942524100956261d35f18fcd2f64'),
    ('godot-cpp', 'godotengine/godot-cpp', 'e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77',
     'd4c03daf46c8bef4544614182b0762c3e32789151c7f8f44e8eb2053d5cddeba'),
)

def extract_source(archive, base):
    """Extract regular source files safely, including on Python 3.9."""
    base = base.resolve()
    members = archive.getmembers()
    for item in members:
        resolved = (base / item.name).resolve()
        if not resolved.is_relative_to(base) or not (item.isfile() or item.isdir()):
            raise SystemExit('Unsafe dependency archive entry')
    for item in members:
        destination = base / item.name
        if item.isdir():
            destination.mkdir(parents=True, exist_ok=True)
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(item) as source, destination.open('wb') as output:
                shutil.copyfileobj(source, output)
            destination.chmod(item.mode & 0o777)


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
        url = f'https://codeload.github.com/{repo}/tar.gz/{revision}'
        print(f'Fetching {repo}@{revision}')
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit(f'{name}: source archive checksum mismatch')
        with tempfile.TemporaryDirectory(dir=vendor) as staging:
            base = Path(staging)
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
                extract_source(archive, base)
            folders = list(base.iterdir())
            if len(folders) != 1 or not folders[0].is_dir():
                raise SystemExit('Unexpected source archive layout')
            shutil.move(str(folders[0]), target)
        marker.write_text(revision + '\n')
    print('Dependencies ready. GGUF must be provided manually.')

if __name__ == '__main__':
    main()
