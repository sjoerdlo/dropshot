# SPEC.md

Dit is de canonieke runner-spec voor DropShot. De productbeschrijving in [README.md](README.md) blijft de menselijke samenvatting; deze root-spec maakt de roadmap en units machine-checkbaar voor de runner.

## Traceability

- `REQ-P1-M1` dekt de native macOS app shell, agent-statusitem en permissievoorbereiding voor het vervangen van de standaard screenshot-tool.
- `REQ-P1-M2` dekt capture-entry, regioselectie en de eerste gebruikersinvoer voor quick capture en scroll capture.
- `REQ-P1-M3` dekt de live scrollsessie en de sessie-shell die frames verzamelt tijdens het scrollen.
- `REQ-P1-M4` dekt stitching correctness met Vision-gebaseerde translatiemetingen en testbare compositing-juistheid.
- `REQ-P1-M5` dekt result delivery, thumbnail-ervaring, clipboard/drag-and-drop en nette sessie-afsluiting.

## Runner Spec

```yaml
requirements:
  - id: REQ-P1-M1
    title: App shell and permission gating
    summary: Bouw de minimale macOS agent-app, statusitem-shell en permissievoorbereiding waarop alle latere capture-flow rust.
    paths:
      - DropShot/
      - DropShot.xcodeproj
      - DropShotTests/
    acceptance:
      - De repo bevat een buildbare native DropShot shell met de juiste app-doelstructuur.
      - Permissie- en shellwerk blijft beperkt tot de expliciete app-start- en statusitemlaag.
    mode: local
  - id: REQ-P1-M2
    title: Capture entry and region selection
    summary: Voeg de capture-entry en regioselectie toe voor quick capture en scrolling capture zonder al stitching te implementeren.
    paths:
      - DropShot/
      - DropShotTests/
    acceptance:
      - De gebruiker kan de capture-flow starten en een regio selecteren volgens de productsamenvatting.
      - De selectie-ervaring blijft traceerbaar naar de gespecificeerde quick capture en scroll capture modes.
    mode: local
  - id: REQ-P1-M3
    title: Live scroll session shell
    summary: Bouw de live sessie die scrollframes verzamelt en de sessiestaat beheert tijdens scrolling capture.
    paths:
      - DropShot/
      - DropShotTests/
    acceptance:
      - De live scroll capture heeft een expliciete sessie-shell met controle over verzamelde frames.
      - De fase blijft beperkt tot sessiegedrag en neemt stitching correctness nog niet over.
    mode: local
  - id: REQ-P1-M4
    title: Stitching correctness
    summary: Lever Vision-gedreven translatiemeting en de compositing-logica die van de sessieframes een correcte lange screenshot maakt.
    paths:
      - DropShot/
      - DropShotTests/
    acceptance:
      - Scrollframes worden juist uitgelijnd en samengesteld tot één consistente output.
      - Tests bewaken de stitching-correctheid die in README is beschreven.
    mode: local
  - id: REQ-P1-M5
    title: Result delivery and session closure
    summary: Rond de captureflow af met thumbnail-preview, clipboard/drag-and-drop gedrag en nette sessie-afsluiting.
    paths:
      - DropShot/
      - DropShotTests/
      - README.md
    acceptance:
      - Een voltooide capture levert een direct bruikbare preview/resultaatflow op voor openen, slepen en plakken.
      - De sessie sluit voorspelbaar af zonder losse tussenstates of half-afgemaakte output.
    mode: local
environment:
  required_tools:
    - python3
    - xcodebuild
  required_paths:
    - DropShot
    - DropShot.xcodeproj
    - DropShotTests
    - units
    - ROADMAP.md
    - README.md
  install_commands: []
  run_commands:
    - xcodebuild -list -project DropShot.xcodeproj
  test_commands:
    - xcodebuild -project DropShot.xcodeproj -scheme DropShot build
  external_dependencies:
    - Xcode 15 or newer with macOS SDK support
    - Screen Recording permission on macOS for real capture testing
```
