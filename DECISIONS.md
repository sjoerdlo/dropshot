# Decisions

## Decision Log

```yaml
decisions:
  - id: D-001
    title: DropShot stays a native menu bar-first macOS utility
    scope:
      - P1-M1
      - P1-M2
      - P1-M3
      - P1-M4
      - P1-M5
    status: decided
    blocking: true
    summary: The product stays a lightweight native macOS status-item utility built inside the existing Xcode project, not a document app or cross-platform shell.
  - id: D-002
    title: V0.1 result delivery remains local and minimal
    scope:
      - P1-M5
    status: decided
    blocking: true
    summary: Completed captures are delivered through thumbnail, preview, copy, save, and drag-and-drop only; history, uploads, and annotation remain out of scope.
```

## Notes

- Disable the native macOS screenshot shortcuts during manual testing so DropShot owns its own capture gestures.
- Screen Recording permission remains an external environment prerequisite, not a unit-level product feature.
