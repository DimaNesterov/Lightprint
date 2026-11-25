# Lightprint

An AR app for iPhone and iPad with LiDAR. Over a day you capture short "moments" of the light in a room.
Lightprint turns them into a light figure anchored in the room. The figure is built only from identical
Gaussian splats.

> In the code the project still uses its working title, Lumen: the `Lumen` app target and the `LumenCore`
> package.

## The visual law

- **One splat is one quantum of light.** Every splat has the same size, shape and opacity. Only the colour
  differs.
- **Colour is the measured colour temperature** on a fixed scale: amber (warm), neutral, ice blue (cold).
- **Intensity is density.** Where there is more light, splats stand closer together, down to one per 4 cm
  cell. Ambient light becomes a sparse lattice.
- **Direct light is rays** from marked windows and lamps to the surfaces they light.
  - Lit surfaces in the same direction from a source share one ray: 6° bins for lamps, 12 cm steps across a
    window.
  - Only the first surface along a ray is lit. What lies behind it is in shadow.
- **Rays widen like the light they carry.** A ray is as wide as the patch it leaves at the source and the
  patch it lights. Every slice carries the same energy.
  - Lamp rays spread out and dissolve, with density falling as 1/r².
  - Sunlight through a window stays a parallel shaft.
  - Rays are drawn narrower than their full bundle (`rayWidth`, 0.3 by default), so the direction stays
    readable.
- **A source casts rays only while it shines.** In each moment a window or lamp counts as a light source only
  if it is itself at least 4× brighter than the room's median surface. A dark window at night, or a dim
  screen marked as a lamp, casts nothing. Lit surfaces that no shining source explains get no rays.
- **One quantum for the whole day.** A sunny noon is denser than an overcast morning.

## How the light is measured

- **White balance** is locked at 5000 K for the whole session. A pixel's colour then reflects the light's
  colour, not the camera's adjustment.
- **One moment is one scan of the whole room.** It runs until you stop it, at most 5 minutes.
  - Exposure stays automatic, biased by −1 EV to keep highlights.
  - Every frame is divided by its own exposure time × ISO, taken from EXIF. This keeps frames and moments
    comparable.
- **Surface cells.** Every high-confidence LiDAR pixel (128 × 96 per frame) becomes a world point with the
  camera's colour, averaged into 4 cm cells.
  - A saturated pixel only counts as a lower bound ("at least this bright").
- **Source brightness** is measured from camera pixels during the scan: inside the window's rectangle (sky,
  blinds, street) and around the lamp's marked point. Pixels with something in front of the source are
  skipped.
- **Window glass.** LiDAR sees through it, so points behind a window's wall (the street) are dropped.
- **Moments from different days** are combined by time of day.

## Build

Requirements: Xcode 16, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an iPhone or iPad with LiDAR
running iOS 18.

```
xcodegen generate
open Lumen.xcodeproj
```

1. Set your Team under target **Lumen** → Signing & Capabilities. Put it in `DEVELOPMENT_TEAM` in
   `project.yml` so it survives regeneration.
2. If the bundle identifier is taken, change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
3. The Run scheme builds Release on purpose: building the light field is much slower without optimisation.

## Using the app

- **Mark**
  - Lamp: tap its shade or bulb.
  - Window: tap one corner, then the opposite one. Drag any corner to adjust it; it moves within the
    window's plane.
  - Sources that are not shining in the latest moment turn grey.
- **Scan (big button):** sweep over the whole room, including walls, floor, ceiling and corners, then tap
  again to stop.
  - Scanned surfaces appear as dots coloured by the light that falls on them.
  - Elapsed time and scanned area are shown above the button.
- **Timeline:** *Accumulate* builds the light up over the day; *Moment* shows the nearest scan. ▶ plays
  the day.
- **Hide interface** (crossed-out eye, top right): only the camera and the light remain. The faint eye in
  the bottom-right corner brings the interface back.
- **Room menu** (room name, top left): new room, delete all moments, reset the whole room, switch rooms.
- **Settings:**
  - Look: room brightness, splat size and opacity, exposure, LiDAR occlusion, markers.
  - Light law: splat budget, thresholds, ray angle, width and spacing, ambient light, colour range.
- **Relocalisation:** when a room is reopened, Lumen relocalises with its saved ARKit world map. If that
  fails, tap **Align** and re-mark the corners of the first window, or the first two lamps.

Data lives in Files → On My iPhone → Lumen → Rooms (the app's working name):
- `room.json` holds the sources, moments and law.
- `captures/*.bin` holds the surface cells.
- `world.armap` holds the ARKit map.

## Honest limitations

- The camera sees light reflected by surfaces, not the light itself. A red wall under white light reads as
  warm light.
- Clipped highlights only give a lower bound for brightness.
- The direction of direct light comes from the marked sources. Light from an unmarked source gets no rays.

## Structure

```
LumenCore/              platform-independent core (Swift Package, with tests)
  Colorimetry.swift     YCbCr → RGB → linear, colour temperature, palette
  LightSource.swift     windows and lamps, window geometry
  Capture.swift         surface cells, accumulator (clipping-aware)
  LightField.swift      the law: source gating, bundled rays, ambient light, quantum sampling,
                        timeline, alignment
App/
  Capture/              camera settings, scan processing, source brightness probes
  Controller/           AR session, modes, scanning, reset, rebuilding the light
  Rendering/            Metal: camera, splats, composite, markers, scan preview
  Storage/              rooms, moments, ARKit world map
  UI/                   SwiftUI interface
prototype/              Python prototype of the law (synthetic room, renders for comparison)
```
