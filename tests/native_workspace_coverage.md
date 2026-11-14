# Native workspace helpers

| Rule | Saved public assertion |
| --- | --- |
| Both dimensions, group identity/order, layout and exact JSON serialization | `merge_dimensions_and_original_serialization`, including independent expected values and original Unicode JSON fixture. |
| Unmanaged values/geometry survive and explicit monitor clear stays authoritative | `independent_dimension_edits_and_explicit_clearing`, immediate sticky/monitor reads after edits. |
| Missing/malformed read input, legacy overlay and existing assignments win | `legacy_defaults_and_invalid_read_documents`. |
| Missing assignment operand, nonnumeric/zero/negative monitors, malformed layout | `assignment_and_layout_validation_matches_original`; originals intentionally skip bad rows rather than reject the command. |
| CLI missing/extra/unknown operands and write resource failure | `rejected_shapes_and_failed_write_preserve_state`; immediate seeded public observations of both dimensions and unchanged bytes after each rejection. |
| Lifecycle native substring filter and operand shape | `lifecycle_filter_cli.rs`: original ordered unrelated entries, malformed/empty input and missing/extra operands, unchanged environment observation. |
| Real shell writer/readers/lifecycle are native and repeatable | `test_native_workspace.sh`; Python trap, target-home install, real builder and exact read/filter results. |

Retain Python reference serializer tests and existing workspace/GSettings/framework
checks. Only fixtures or mocked desktop commands are exercised; no live app-rule
file write, extension deployment, service restart or Shell reload.
