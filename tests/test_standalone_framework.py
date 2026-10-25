"""Guard the maintained offline framework support shipped with this owner."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_standalone_framework_uses_packaged_support():
    """Require a licensed framework package instead of a private bootstrap.

    Parameters: none.
    Returns: None.
    """
    print('parameters=none')
    source = (ROOT / 'install.sh').read_text()
    assert '.installer-support/bootstrap.sh' in source
    assert 'raw.githubusercontent.com/mikaeltorni/linux_installation_scripts_functions' not in source
    assert 'GIT_TERMINAL_PROMPT=0 git clone' not in source
    assert (ROOT / '.installer-support/component_menu.sh').is_file()
    assert 'Permission is hereby granted' in (ROOT / '.installer-support/LICENSE.md').read_text()
    print(None)
