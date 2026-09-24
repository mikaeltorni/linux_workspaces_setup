"""Guard the private shared-framework fallback used by standalone installs."""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def test_standalone_framework_bootstrap_uses_git_clone():
    """The private framework cannot be fetched through anonymous raw URLs."""
    source = (ROOT / "install.sh").read_text(encoding="utf-8")
    assert "GIT_TERMINAL_PROMPT=0 git clone" in source
    assert 'ISC_FUNCTIONS_DIR="${__isc_framework_loader%/*}"' in source
    assert "framework-${__isc_framework_key}" in source
    assert "raw.githubusercontent.com/mikaeltorni/linux_installation_scripts_functions" not in source
