"""Preserve earlier caller output when exporting an isolated owner selection."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='owner-export-stream-') as directory:
    temporary = Path(directory)
    checkout = temporary/'owner'
    checkout.mkdir()
    for relative in subprocess.check_output(['git','-C',str(ROOT),'ls-files'],text=True).splitlines():
        if relative in ('notes.json','notes.txt','used_notes.txt'):
            continue
        source = ROOT/relative
        if source.is_file() and not source.is_symlink():
            destination = checkout/relative
            destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(source,destination)
    shutil.copytree(ROOT/'.installer-support',checkout/'.installer-support',dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('__pycache__','.log'))
    home = temporary/'home'
    home.mkdir()
    tools = temporary/'tools'
    tools.mkdir()
    effects = temporary/'effects'
    getent = tools/'getent'
    getent.write_text('#!/bin/bash\nprintf "%s:x:%s:%s::%s:/bin/bash\\n" "$USER" "$(id -u)" "$(id -g)" "$HOME"\n')
    getent.chmod(0o755)
    guard = '''#!/bin/bash
name="${0##*/}"
if [[ "$name" == gsettings ]]; then
 if [[ "${1:-}" == --schemadir ]]; then shift 2; fi
 case "${1:-}" in get|list-*|range|writable) exit 1 ;; esac
fi
if [[ "$name" == systemctl ]]; then
 while [[ "${1:-}" == --* ]]; do shift; done
 case "${1:-}" in is-active|is-enabled|status|show|list-unit-files|list-units) exit 1 ;; esac
fi
if [[ "$name" == gnome-extensions ]]; then
 case "${1:-}" in info|list) exit 1 ;; esac
fi
if [[ "$name" == tmux ]]; then
 case "${1:-}" in has-session|list-sessions|list-windows|list-panes|show-environment) exit 1 ;; esac
fi
printf '%s %s\\n' "$name" "$*" >> "$EFFECTS"
exit 97
'''
    for name in ('git','curl','wget','sudo','cargo','apt','apt-get','gsettings','dconf','systemctl','gnome-extensions','tmux','safe-system-action','xdotool','pkill','killall'):
        command = tools/name
        command.write_text(guard)
        command.chmod(0o755)
    # The real guarded power helper must never execute during a verification run.
    (checkout/'.installer-support/safe_system_action.sh').write_text('#!/bin/bash\nprintf "forbidden power helper\\n" >> "$EFFECTS"\nexit 97\n')
    environment = dict(PATH=str(tools)+':/usr/bin:/bin',HOME=str(home),USER=os.environ.get('USER','mk'),
                       XDG_CONFIG_HOME=str(home/'config'),XDG_STATE_HOME=str(home/'state'),
                       XDG_CACHE_HOME=str(home/'cache'),XDG_SESSION_TYPE='unknown',EFFECTS=str(effects),TERM='xterm')
    combined = temporary/'combined-output'
    prefix = b'previous setup output\n'
    with combined.open('wb') as stream:
        stream.write(prefix)
        stream.flush()
        result = subprocess.run(['bash',str(checkout/'install.sh'),'--export-selection'],cwd=checkout,env=environment,
                                stdout=stream,stderr=subprocess.PIPE,timeout=40)
    assert result.returncode == 0,(result.returncode,result.stderr.decode(errors='replace'))
    data = combined.read_bytes()
    assert data.startswith(prefix),('export truncated previous setup output',data[:100])
    assert b'\0' not in data,'export introduced holes in caller output'
    document = json.loads(data[len(prefix):])
    assert document['scope'] == 'standalone' and isinstance(document['components'],dict),document
    assert not effects.exists(),effects.read_text() if effects.exists() else ''
print('PASS: public export preserves caller output, valid JSON and isolated application state')
