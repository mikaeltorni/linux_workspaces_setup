# linux_workspaces_setup AGENTS

This repository owns Ubuntu/GNOME workspace behavior and hotkeys split from the orchestration chain:

- Albert launcher keybindings and workspace-related extension behavior;
- monitor/window tiling GNOME Shell extension deployment plus conflict cleanup for Super+Up/Down tile bindings;
- workspace-side configuration consumed by the window-tiling extension;
- the xmousepasteblock primary-clipboard-lock user service (middle-click paste block);
- numbered-workspace popup GNOME Shell extension;
- app-rules workspace/sticky rules extension owned from the old configuration setup repository; and
- auto-move-windows placement where it is available, with app-rules as fallback.

Screenshot shortcuts and numbered workspace switch/move accelerators are owned
by `linux_hotkey_setup`, where each accelerator is configured individually.
The pointer-driven window-placement tiler is also owned solely by
`linux_hotkey_setup`; this repository must not install a second input grabber.
Do not move the remaining behaviors into `linux_hotkey_setup`,
`linux_configuration_setup`, or `ubuntu_2404_taskbar_system_status_monitor`
unless ownership moves again. When changing installed desktop behavior, test
the affected repo and deploy this repo's installer when a GNOME session is
available; follow the `linux-configuration` skill for extension activation
(X11 in-place reload, or manual logout/login on Wayland).
