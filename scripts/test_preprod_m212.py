"""M2.12 tests: the three limited corrections of build_preprod.py. Fake keys and files only; no Gradle, no build.

1. --maps-disabled passes an EMPTY key file, so an ambient azTestMapsKeyFile cannot reach the manifest.
2. state.json is written atomically (never an empty/partial state.json).
3. The temporary Maps key file lives under an ASCII-only path.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_preprod as bp  # noqa: E402
from test_build_preprod import PROD_KEY, PROD_MAPS, TEST_KEY, Base, good_defines  # noqa: E402
from test_gradle_maps_review import new_value  # noqa: E402

ACCENTED = 'témp é àç'


def props_from(command):
    """The -P properties Flutter would hand to Gradle, rebuilt from the generated command line."""
    props = {}
    for arg in command:
        if arg.startswith('--android-project-arg='):
            name, _, value = arg[len('--android-project-arg='):].partition('=')
            props[name] = value
    return props


class BuildHarness(Base):
    def build(self, defines=None, maps_disabled=False, exit_code=0, node_checks=False):
        _, gs = self.files(defines)
        seen = {'files': {}}

        def fake_call(command, **kwargs):
            seen['command'] = list(command)
            props = props_from(command)
            seen['props'] = props
            key_path = props.get('azTestMapsKeyFile')
            if key_path is not None:
                seen['key_path'] = Path(key_path)
                seen['files'][key_path] = Path(key_path).read_text(encoding='utf-8')
            define_arg = [a for a in command if a.startswith('--dart-define-from-file=')][0]
            seen['defines'] = json.loads(Path(define_arg.split('=', 1)[1]).read_text())
            apk = self.root / 'build/app/outputs/flutter-apk/app-debug.apk'
            apk.parent.mkdir(parents=True, exist_ok=True)
            apk.write_bytes(b'x')
            return exit_code

        out, error = io.StringIO(), None
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'), \
                mock.patch.object(bp.subprocess, 'call', side_effect=fake_call), mock.patch.object(bp, 'audit_apk'), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                bp.build(good_defines() if defines is None else defines, gs, 11, node_checks=node_checks,
                         maps_disabled=maps_disabled)
            except bp.PreprodError as exc:
                error = exc
        return seen, error, out.getvalue()


def disabled_defines():
    d = good_defines()
    del d['TEST_MAPS_API_KEY']
    return d


class AmbientNeutralisationTest(BuildHarness):
    """Correction 1."""

    def test_disabled_mode_passes_an_empty_key_file_and_an_empty_legacy_property(self):
        seen, error, log = self.build(disabled_defines(), maps_disabled=True)
        self.assertIsNone(error)
        self.assertEqual(seen['props']['azTestMapsKey'], '')
        self.assertEqual(list(seen['files'].values()), [''])  # the key file exists and is EMPTY
        self.assertNotIn('TEST_MAPS_API_KEY', seen['defines'])

    def test_an_ambient_key_file_cannot_reach_the_manifest_in_disabled_mode(self):
        seen, _, _ = self.build(disabled_defines(), maps_disabled=True)
        ambient = {'azTestMapsKeyFile': 'AMBIENT', 'azTestMapsKey': 'AMBIENT-LEGACY'}
        files = {'AMBIENT': 'OLD-AMBIENT-KEY', seen['props']['azTestMapsKeyFile']: ''}
        # -P (command line) wins over gradle.properties / environment: merge with the command line last.
        effective = {**ambient, **seen['props']}
        self.assertEqual(new_value(effective, {}, files), '')

    def test_the_previous_behaviour_would_have_leaked_the_ambient_value(self):
        """Control: without the empty key file (M2.11 behaviour) the ambient value is read."""
        seen, _, _ = self.build(disabled_defines(), maps_disabled=True)
        old_props = {k: v for k, v in seen['props'].items() if k != 'azTestMapsKeyFile'}
        effective = {**{'azTestMapsKeyFile': 'AMBIENT'}, **old_props}
        self.assertEqual(new_value(effective, {}, {'AMBIENT': 'OLD-AMBIENT-KEY'}), 'OLD-AMBIENT-KEY')

    def test_disabled_mode_carries_no_maps_key_anywhere(self):
        seen, error, log = self.build(disabled_defines(), maps_disabled=True)
        everything = ' '.join(seen['command']) + json.dumps(seen['defines']) + ''.join(seen['files'].values()) + log
        self.assertNotIn('AIza', everything)
        self.assertNotIn(PROD_KEY, everything); self.assertNotIn(TEST_KEY, everything)

    def test_key_mode_is_unchanged(self):
        seen, error, log = self.build(good_defines())
        self.assertIsNone(error)
        self.assertEqual(list(seen['files'].values()), [TEST_KEY])
        self.assertEqual(new_value({**{'azTestMapsKeyFile': 'AMBIENT'}, **seen['props']}, {}, {
            'AMBIENT': 'OLD', seen['props']['azTestMapsKeyFile']: TEST_KEY}), TEST_KEY)
        self.assertNotIn(TEST_KEY, ' '.join(seen['command']))
        self.assertEqual(seen['defines']['TEST_MAPS_API_KEY'], TEST_KEY)

    def test_empty_key_file_is_removed_after_success_and_after_failure(self):
        for kwargs in ({}, {'exit_code': 1}):
            seen, _, _ = self.build(disabled_defines(), maps_disabled=True, **kwargs)
            self.assertFalse(seen['key_path'].exists())
            self.assertFalse(seen['key_path'].parent.exists())  # whole scratch folder gone
            self.assertFalse(self.native.exists())
            self.assertFalse(self.recovery.exists())
            self.assertEqual(self.maps.read_text(), PROD_MAPS)

    def test_disabled_mode_still_refuses_a_configured_key(self):
        config, gs = self.files(good_defines())
        code, _, err = self.check(config, gs, '--maps-disabled')
        self.assertEqual(code, 2); self.assertIn('conflicts', err)


class AtomicStateTest(BuildHarness):
    """Correction 2."""

    def setUp(self):
        super().setUp()
        self.folder = self.root / 'build/az-preprod-recovery'
        self.folder.mkdir(parents=True)
        self.state = self.folder / 'state.json'
        self.partial = self.folder / 'state.json.az-partial'

    def test_success_writes_a_complete_state_and_leaves_no_partial(self):
        bp.write_state_atomically(self.state, {'version': 1, 'original_sha256': 'a' * 64})
        self.assertEqual(json.loads(self.state.read_text()), {'version': 1, 'original_sha256': 'a' * 64})
        self.assertFalse(self.partial.exists())

    def test_failure_while_writing_leaves_neither_state_nor_partial(self):
        with mock.patch.object(bp.json, 'dump', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                bp.write_state_atomically(self.state, {'x': 1})
        self.assertFalse(self.state.exists()); self.assertFalse(self.partial.exists())

    def test_failure_at_the_final_rename_leaves_neither_state_nor_partial(self):
        with mock.patch.object(bp.os, 'replace', side_effect=OSError('rename')):
            with self.assertRaises(OSError):
                bp.write_state_atomically(self.state, {'x': 1})
        self.assertFalse(self.state.exists()); self.assertFalse(self.partial.exists())

    def test_interrupt_keeps_an_existing_state_intact(self):
        self.state.write_text('{"keep": true}')
        with mock.patch.object(bp.json, 'dump', side_effect=KeyboardInterrupt()):
            with self.assertRaises(KeyboardInterrupt):
                bp.write_state_atomically(self.state, {'x': 1})
        self.assertEqual(self.state.read_text(), '{"keep": true}')
        self.assertFalse(self.partial.exists())

    def test_a_leftover_partial_state_is_reported_and_blocks_the_next_run(self):
        (self.folder / 'maps_key.dart.original').write_text(PROD_MAPS)
        self.partial.write_text('{"half"')
        self.assertIn('incomplete', bp.recovery_state(self.maps))
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'):
            with self.assertRaisesRegex(bp.PreprodError, 'Recovery required'):
                bp.preflight()
        self.assertEqual(self.partial.read_text(), '{"half"')  # nothing deleted

    def test_partial_alone_is_a_recovery_state(self):
        self.partial.write_text('')
        self.assertIsNotNone(bp.recovery_state(self.maps))

    def test_build_never_produces_an_empty_state_json(self):
        """A failure while the state is written (second json.dump) leaves no state.json at all."""
        real = bp.json.dump
        calls = []

        def dump(obj, stream, *a, **k):
            calls.append(1)
            if len(calls) == 2:
                raise OSError('state')
            return real(obj, stream, *a, **k)

        self.folder.rmdir()
        with mock.patch.object(bp.json, 'dump', dump), self.assertRaises(OSError):
            self.build()
        self.assertFalse((self.root / 'build/az-preprod-recovery/state.json').exists())
        self.assertEqual(self.maps.read_text(), PROD_MAPS)

    def test_a_real_kill_between_the_partial_write_and_the_rename(self):
        """Hard kill at the first os.replace (the state rename): no state.json, an identifiable partial, original intact."""
        self.folder.rmdir()
        _, gs = self.files()
        script = textwrap.dedent(f'''
            import os, sys
            from pathlib import Path
            from unittest import mock
            sys.dont_write_bytecode = True
            sys.path.insert(0, {str(Path(bp.__file__).parent)!r})
            import build_preprod as bp
            bp.ROOT = Path({str(self.root)!r})
            with mock.patch.object(bp, 'check_tools', return_value='x'), \\
                    mock.patch.object(bp, 'git_porcelain', return_value=''), \\
                    mock.patch.object(bp.shutil, 'which', return_value='flutter'), \\
                    mock.patch.object(bp.os, 'replace', side_effect=lambda a, b: os._exit(9)):
                bp.build({good_defines()!r}, Path({str(gs)!r}), 11, node_checks=False)
        ''')
        result = subprocess.run([sys.executable, '-c', script], capture_output=True, text=True, timeout=60,
                                env=self.killed_child_env())
        self.assertEqual(result.returncode, 9, result.stderr)
        folder = self.root / 'build/az-preprod-recovery'
        self.assertFalse((folder / 'state.json').exists())  # never an empty, "exploitable" state.json
        self.assertTrue((folder / 'state.json.az-partial').exists())
        self.assertEqual(json.loads((folder / 'state.json.az-partial').read_text())['version'], 1)
        self.assertEqual(self.maps.read_text(), PROD_MAPS)  # swap never started
        self.assertIn('incomplete', bp.recovery_state(self.maps))
        with mock.patch.object(bp.shutil, 'which', return_value='flutter'):
            with self.assertRaisesRegex(bp.PreprodError, 'Recovery required'):
                bp.preflight()
        self.assertTrue((folder / 'maps_key.dart.original').exists())  # nothing deleted by the refusal


class AsciiKeyFileLocationTest(BuildHarness):
    """Correction 3."""

    def accented_tempdir(self):
        folder = Path(self.tmp.name) / ACCENTED
        folder.mkdir()
        previous = tempfile.tempdir
        tempfile.tempdir = str(folder)
        self.addCleanup(setattr, tempfile, 'tempdir', previous)
        return folder

    def test_ascii_system_temp_is_used_as_before(self):
        with mock.patch.object(bp.tempfile, 'gettempdir', return_value=str(Path(self.tmp.name))):
            self.assertIsNone(bp.ascii_scratch_parent())
        seen, error, _ = self.build()
        self.assertIsNone(error)
        self.assertTrue(str(seen['key_path']).isascii())

    def test_non_ascii_system_temp_moves_the_scratch_folder_under_the_repository_build_folder(self):
        folder = self.accented_tempdir()
        self.assertTrue(str(self.root).isascii())
        self.assertEqual(bp.ascii_scratch_parent(), self.root / 'build')
        seen, error, log = self.build()
        self.assertIsNone(error, log)
        self.assertTrue(str(seen['key_path']).isascii())
        self.assertEqual(seen['key_path'].parent.parent, self.root / 'build')
        self.assertEqual(seen['files'][str(seen['key_path'])], TEST_KEY)
        self.assertFalse(seen['key_path'].exists())  # removed
        self.assertFalse(seen['key_path'].parent.exists())
        self.assertFalse(any(folder.iterdir()))  # nothing written under the accented temp folder
        self.assertEqual(self.maps.read_text(), PROD_MAPS)

    def test_disabled_mode_uses_the_same_ascii_location(self):
        self.accented_tempdir()
        seen, error, _ = self.build(disabled_defines(), maps_disabled=True)
        self.assertIsNone(error)
        self.assertTrue(str(seen['key_path']).isascii())
        self.assertEqual(seen['files'][str(seen['key_path'])], '')

    def test_failure_cleans_the_fallback_location_too(self):
        self.accented_tempdir()
        seen, error, _ = self.build(exit_code=1)
        self.assertIsNotNone(error)
        self.assertFalse(seen['key_path'].exists())
        self.assertFalse(seen['key_path'].parent.exists())
        self.assertEqual(self.maps.read_text(), PROD_MAPS)
        self.assertNotIn(TEST_KEY, str(error))

    def test_refused_when_no_ascii_location_exists_and_nothing_is_touched(self):
        self.accented_tempdir()
        with mock.patch.object(bp, 'ROOT', Path(self.tmp.name) / ACCENTED / 'repo'):
            with self.assertRaisesRegex(bp.PreprodError, 'ASCII-only'):
                bp.ascii_scratch_parent()
        # Through build(): refusal comes before the backup/swap.
        with mock.patch.object(bp, 'ascii_scratch_parent', side_effect=bp.PreprodError('Refused: ASCII-only')):
            seen, error, _ = self.build()
        self.assertIsNotNone(error)
        self.assertFalse(self.recovery.exists()); self.assertFalse(self.native.exists())
        self.assertEqual(self.maps.read_text(), PROD_MAPS)

    def test_accented_repository_with_ascii_temp_is_fine(self):
        accented_root = Path(self.tmp.name) / ACCENTED / 'repo'
        with mock.patch.object(bp.tempfile, 'gettempdir', return_value=str(Path(self.tmp.name))):
            self.assertIsNone(bp.ascii_scratch_parent())  # only the temp path matters when it is ASCII
        self.assertFalse(str(accented_root).isascii())

    def test_secrets_never_in_the_refusal_messages(self):
        self.accented_tempdir()
        with mock.patch.object(bp, 'ROOT', Path(self.tmp.name) / ACCENTED / 'repo'):
            with self.assertRaises(bp.PreprodError) as context:
                bp.ascii_scratch_parent()
        self.assertNotIn(TEST_KEY, str(context.exception)); self.assertNotIn(PROD_KEY, str(context.exception))


class ScopeGuardTest(unittest.TestCase):
    """The corrections stay inside the authorised files."""

    def test_forbidden_files_untouched_by_content_markers(self):
        repo = Path(__file__).resolve().parents[1]
        blob = subprocess.run(['git', 'hash-object', 'android/app/build.gradle.kts'], cwd=repo,
                              capture_output=True, text=True, timeout=30).stdout.strip()
        self.assertTrue(blob.startswith('29bd8394'), blob)  # build.gradle.kts as left by M2.9, not touched by M2.12

    def test_no_real_key_shape_in_the_engine(self):
        import re
        text = Path(bp.__file__).read_text(encoding='utf-8')
        self.assertIsNone(re.search(r'AIza[0-9A-Za-z_-]{20,}', text))


if __name__ == '__main__':
    unittest.main()
