# Vision

## Product intent

DropShot moet een lichte, native macOS screenshot-tool zijn die de standaard screenshotflow vervangt met twee directe paden: snelle regiocapture en scrolling capture voor lange content. De eerste versie moet bruikbaar voelen zonder extra setup in het moment van gebruik: selecteren, vastleggen, previewen, kopieren, opslaan of slepen.

## UX principles

- De flow blijft menu bar-first en toetsenbordgedreven, zonder volle hoofdapp of complexe setupschermen.
- Quick capture en scroll capture voelen als twee varianten van dezelfde capture-ervaring, niet als twee losse producten.
- Resultaatdelivery blijft direct en lokaal: thumbnail, preview, copy, save en drag-and-drop.
- V0.1 vermijdt geschiedenis, annotatie, sync en andere afleidende uitbreidingen.

## Runner Prep

```yaml
goal: Ship DropShot v0.1 as a reliable native macOS screenshot replacement with quick capture and scrolling capture.
audience:
  - macOS users who frequently capture and share screenshots
  - People who need long stitched screenshots from scrollable content
success_criteria:
  - The app builds cleanly from DropShot.xcodeproj on the supported macOS toolchain.
  - Quick capture and scrolling capture share one coherent selection and result-delivery experience.
  - Scrolling capture produces a stitched final image and hands it off through a lightweight result surface.
constraints:
  - Keep the product native to macOS 14+ and aligned with the existing Xcode project layout.
  - Keep v0.1 local-only with no cloud sync, uploads, or account concepts.
  - Preserve a minimal menu bar footprint and avoid adding a full document-style app shell.
non_goals:
  - Annotation or editing tools
  - Screenshot history or gallery management
  - Cross-platform support
```
