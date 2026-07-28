# linux_workspaces_setup AGENTS

This repository owns Ubuntu/GNOME workspace behavior and hotkeys split from the orchestration chain:

- Albert launcher keybindings and workspace-related extension behavior;
- monitor/window tiling GNOME Shell extension deployment plus conflict cleanup for Super+Up/Down tile bindings;
- Ctrl+Back window-tiling service wiring;
- the xmousepasteblock primary-clipboard-lock user service (middle-click paste block);
- numbered-workspace popup GNOME Shell extension;
- app-rules workspace/sticky rules extension owned from the old configuration setup repository; and
- auto-move-windows placement where it is available, with app-rules as fallback.

Screenshot shortcuts and numbered workspace switch/move accelerators are owned
by `linux_hotkey_setup`, where each accelerator is configured individually.
Do not move the remaining behaviors into `linux_hotkey_setup`,
`linux_configuration_setup`, or `ubuntu_2404_taskbar_system_status_monitor`
unless ownership moves again. When changing installed desktop behavior, test
the affected repo and deploy this repo's installer when a GNOME session is
available; log out/in for shell-extension changes.


## Mandatory programming guidelines prompt

Every agent task in this repository must load the shared
`general-programming-guidelines` skill before the first file edit, using the
harness-native invocation for the runtime in use:

- Codex-family (`ca`, `qa`, `oa`, `na`, …): `$general-programming-guidelines`
- Claude Code, Cline, Grok: `/general-programming-guidelines`
- OpenCode: load `general-programming-guidelines` with the skill tool

Agent Command Center prepends this bare invocation to every dispatched prompt, so the
harness activates the skill before reading the task. When you start a task by hand, invoke it
yourself first. Then follow its Work Loop — dedicated worktree branch before
the first edit, tests, logging, documentation — and do not report the task done
until its Definition of Done checklist passes.
