"""Offline checks; no dependency, model, or tool downloads."""
import ast
import fnmatch
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('fetch_dependencies', ROOT / 'scripts/fetch_dependencies.py')
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)
build_spec = importlib.util.spec_from_file_location('build_demo', ROOT / 'scripts/build.py')
build_demo = importlib.util.module_from_spec(build_spec)
build_spec.loader.exec_module(build_demo)


class BuildConfigurationTests(unittest.TestCase):
    def test_python39_syntax(self):
        for name in ('build.py', 'fetch_dependencies.py'):
            ast.parse((ROOT / 'scripts' / name).read_text(), feature_version=(3, 9))

    def test_icon(self):
        icon = ET.parse(ROOT / 'icon.svg').getroot()
        self.assertEqual(icon.tag, '{http://www.w3.org/2000/svg}svg')
        self.assertEqual(icon.attrib['viewBox'], '0 0 256 256')
        self.assertIn('config/icon="res://icon.svg"', (ROOT / 'project.godot').read_text())

    def test_ios_export(self):
        preset = (ROOT / 'export_presets.cfg').read_text()
        self.assertIn('export_path="build/ios/QwenDemo.xcodeproj"', preset)
        self.assertIn('application/min_ios_version="16.4"', preset)
        line = next(line for line in preset.splitlines() if line.startswith('include_filter='))
        patterns = line.split('=', 1)[1].strip('"').split(',')
        for name in ('Qwen3.5-0.8B-Q4_0.gguf', 'Qwen3.5-0.8B-Q4_0_un.gguf',
                     'Ternary-Bonsai-2-2B-Q2_0.gguf'):
            self.assertTrue(any(fnmatch.fnmatch('models/' + name, pattern) for pattern in patterns))

    def test_pin(self):
        self.assertEqual(fetch.DEPENDENCIES[0][2], 'a9d27ac693ff0a1d3cba449c912c2b891904a4c7')
        for _, _, revision, digest in fetch.DEPENDENCIES:
            self.assertEqual(len(revision), 40)
            self.assertEqual(len(digest), 64)

    def extract(self, name, kind=tarfile.REGTYPE):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            item = tarfile.TarInfo(name)
            item.type = kind
            item.size = 3 if kind == tarfile.REGTYPE else 0
            archive.addfile(item, io.BytesIO(b'abc') if item.size else None)
        data.seek(0)
        with tempfile.TemporaryDirectory() as directory:
            with tarfile.open(fileobj=data) as archive:
                fetch.extract_source(archive, Path(directory))
            if kind == tarfile.REGTYPE:
                self.assertEqual((Path(directory) / name).read_bytes(), b'abc')

    def test_apple_entrypoint_check(self):
        with mock.patch.object(build_demo, 'run') as run, mock.patch.object(build_demo.subprocess, 'run') as nm:
            nm.return_value.stdout = '00000000 T _qwen_library_init\n'
            build_demo.verify_apple_archive(Path('/tmp/libdemo.a'), 'arm64')
            run.assert_called_once_with('/usr/bin/lipo', '-verify_arch', 'arm64', Path('/tmp/libdemo.a'))
            self.assertIn('-gU', nm.call_args[0][0])
            nm.return_value.stdout = '00000000 T _other_symbol\n'
            with self.assertRaises(SystemExit):
                build_demo.verify_apple_archive(Path('/tmp/libdemo.a'), 'arm64')

    def test_regular_archive(self):
        self.extract('source/src/test.cpp')

    def test_traversal_rejected(self):
        for name in ('../escape.cpp', '/tmp/escape.cpp', 'source/../../escape.cpp'):
            with self.subTest(name=name), self.assertRaises(SystemExit):
                self.extract(name)

    def test_special_entries_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE, tarfile.BLKTYPE):
            with self.subTest(kind=kind), self.assertRaises(SystemExit):
                self.extract('source/unsafe', kind)


if __name__ == '__main__':
    unittest.main()
