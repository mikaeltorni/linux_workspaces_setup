"""Verify framework support ships with an isolated owner checkout."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
support = root / '.installer-support'
assert (support / 'bootstrap.sh').is_file(), 'Missing bundled framework bootstrap'
manifest = json.loads((support / 'manifest.json').read_text())
assert manifest['license'] == 'MIT'
assert 'if cm_single_submenu "$repo"; then rc=0; else rc=$?; fi' in (support / 'component_runtime.sh').read_text(), 'Missing strict-Bash menu cancellation handling'
assert 'Permission is hereby granted' in (support / 'LICENSE.md').read_text()
import hashlib
for name, expected in manifest['files'].items():
    assert hashlib.sha256((support / name).read_bytes()).hexdigest() == expected, name
assert {'component_runtime.sh', 'component_menu.sh', 'installation_config.py', 'hotkey_capture.py'} <= set(manifest['files'])
installer_sources = [root / 'install.sh', root / 'scripts/install_standalone.sh']
assert any('.installer-support/bootstrap.sh' in path.read_text() for path in installer_sources if path.is_file()), 'Installer does not use the packaged framework'
# LUKS owner policy permits static checks only outside a disposable VM.
if root.name.startswith('linux_luks_configuration') or (root / 'lib/luks_configuration.sh').is_file():
    assert '_isc_validate_ids()' in (support / 'component_runtime.sh').read_text(), 'Missing shared pre-effect lifecycle validation'
    print('PASS: LUKS static support closure and bootstrap; installer was not invoked')
else:
    with tempfile.TemporaryDirectory(prefix='standalone-owner-') as directory:
        temporary = Path(directory)
        checkout = temporary / 'owner'
        checkout.mkdir()
        tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files'], text=True).splitlines()
        for relative in tracked:
            source = root / relative
            if not source.is_file() or source.is_symlink():
                continue
            target = checkout / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        shutil.copytree(support, checkout / '.installer-support', dirs_exist_ok=True)
        tools = temporary / 'tools'
        tools.mkdir()
        marker = temporary / 'forbidden-call'
        for name in ('curl', 'wget', 'git', 'sudo', 'gsettings', 'dconf', 'systemctl', 'gnome-extensions', 'apt', 'apt-get'):
            file = tools / name
            file.write_text('#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "$FORBIDDEN_MARKER"\nexit 97\n')
            file.chmod(0o755)
        getent = tools / 'getent'
        getent.write_text('#!/bin/sh\nprintf "%s:x:%s:%s::%s:/bin/bash\\n" "$USER" "$(id -u)" "$(id -g)" "$HOME"\n')
        getent.chmod(0o755)
        home = temporary / 'home'
        home.mkdir()
        env = dict(HOME=str(home), USER=os.environ.get('USER', 'mk'), LOGNAME=os.environ.get('USER', 'mk'), PATH=str(tools)+':/usr/bin:/bin', XDG_CONFIG_HOME=str(temporary/'config'), XDG_CACHE_HOME=str(temporary/'cache'), XDG_STATE_HOME=str(temporary/'state'), FORBIDDEN_MARKER=str(marker), TERM='xterm', LANG='C.UTF-8')
        for arguments in (['--help'], ['--list-components'], ['--help', 'unexpected'], ['--list-components', 'unexpected']):
            # Task Workspaces is atomic; its component protocol is a later cycle.
            if arguments == ['--list-components'] and (root / 'src/chrome.rs').is_file():
                continue
            result = subprocess.run(['bash', str(checkout/'install.sh'), *arguments], cwd=checkout, env=env, capture_output=True, text=True, timeout=30)
            expected_status = 2 if 'unexpected' in arguments else 0
            assert result.returncode == expected_status, (arguments, result.returncode, result.stdout, result.stderr)
            assert not marker.exists(), marker.read_text() if marker.exists() else ''
        assert not (home / 'projects').exists(), 'Discovery created sibling checkouts'
    print('PASS: packaged licensed framework; isolated help/discovery uses no network, credentials or desktop mutations')
