# ROADMAP.md

This file is human-readable, but the runtime parses only the canonical `yaml` block under `## Runtime Graph`.

## Runtime Graph

```yaml
program_id: dropshot-scroll-capture-v0-1
milestones:
  - id: P1-M1
    title: App shell and permission gating
    spec_refs:
      - REQ-P1-M1
    depends_on: []
    units:
      - P1-M1-U1
      - P1-M1-U2
      - P1-M1-U3
    validation_commands:
      - xcodebuild -project DropShot.xcodeproj -scheme DropShot build
      - python3 bin/runtime ready-check --root . --milestone P1-M1
    requires_live_ops: false
  - id: P1-M2
    title: Capture entry and region selection
    spec_refs:
      - REQ-P1-M2
    depends_on:
      - P1-M1
    units:
      - P1-M2-U1
      - P1-M2-U2
      - P1-M2-U3
    validation_commands:
      - xcodebuild -project DropShot.xcodeproj -scheme DropShot build
      - python3 bin/runtime ready-check --root . --milestone P1-M2
    requires_live_ops: false
  - id: P1-M3
    title: Live scroll session shell
    spec_refs:
      - REQ-P1-M3
    depends_on:
      - P1-M2
    units:
      - P1-M3-U1
      - P1-M3-U2
      - P1-M3-U3
    validation_commands:
      - xcodebuild -project DropShot.xcodeproj -scheme DropShot build
      - python3 bin/runtime ready-check --root . --milestone P1-M3
    requires_live_ops: false
  - id: P1-M4
    title: Stitching correctness
    spec_refs:
      - REQ-P1-M4
    depends_on:
      - P1-M3
    units:
      - P1-M4-U1
      - P1-M4-U2
      - P1-M4-U3
    validation_commands:
      - xcodebuild -project DropShot.xcodeproj -scheme DropShot build
      - xcodebuild -project DropShot.xcodeproj -scheme DropShot -destination 'platform=macOS' test
      - python3 bin/runtime ready-check --root . --milestone P1-M4
    requires_live_ops: false
  - id: P1-M5
    title: Result delivery and session closure
    spec_refs:
      - REQ-P1-M5
    depends_on:
      - P1-M4
    units:
      - P1-M5-U1
      - P1-M5-U2
    validation_commands:
      - xcodebuild -project DropShot.xcodeproj -scheme DropShot build
      - xcodebuild -project DropShot.xcodeproj -scheme DropShot -destination 'platform=macOS' test
      - python3 bin/runtime ready-check --root . --milestone P1-M5
    requires_live_ops: false
```

## Notes

- `P1-M1` is the first execution target for the runner.
- `P1-M2` may only start after `P1-M1` is green.
- `P1-M3` may only start after `P1-M2` is green.
- `P1-M4` may only start after `P1-M3` is green.
- `P1-M5` may only start after `P1-M4` is green.
- Keep active execution state out of this file.
