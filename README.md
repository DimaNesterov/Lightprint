# Lightprint

An AR experiment for iPhone and iPad with LiDAR. You scan a room several times over a day, and Lightprint
draws its light as a figure in the air. Rays come from the windows and lamps, ambient light fills the room,
warm light shows as amber and cold light as blue, and the figure is dense where the light is strong.

Built with ARKit, LiDAR and Metal. The phone's camera works as a light meter. The whole figure is made of
one element, identical Gaussian splats: one splat is one quantum of light. Intensity is density, colour is
the measured colour temperature, and nothing else changes from splat to splat.

## Background

Light in a room is invisible until it lands on something. Architectural daylight studies simulate light and
paint the result onto surfaces as false-colour maps. Lightprint measures it instead. The phone records how
bright every surface is, and what colour its light has, at a given moment. The app then reconstructs where
that light came from and draws its path through the room.

The figure follows a fixed set of rules rather than visual effects. There are no extra shapes, clouds or
glows, only splats placed according to the measurements. The visual language stays the same from a sunny
noon to a lamp at night, so moments can be compared directly.

## How it works

### Capturing a moment

1. **Mark the sources.** A lamp takes one tap on its shade or bulb, a window two taps on opposite corners.
   You can drag a window's corners afterwards; they slide within the window's plane.
2. **Scan the room.** One moment is one sweep over the whole room, for as long as it takes (up to 5
   minutes).
   - White balance is locked at 5000 K for the whole session, so a pixel's colour is the colour of the light.
   - Exposure stays automatic with a −1 EV bias. Every frame is normalised by its own exposure:
     `radiance = linear RGB / (exposure time × ISO)`.
3. **Surfaces.** Every high-confidence LiDAR pixel (128 × 96 per frame) becomes a world point carrying its
   camera colour. The points are averaged into 4 cm cells.
   - A clipped pixel only counts as a lower bound.
   - LiDAR sees through glass, so points behind a window's wall are dropped.
4. **Sources.** During the scan the app also reads the camera pixels inside each window's rectangle and
   around each lamp, skipping pixels where something stands in front. This tells a bright sky from closed
   blinds.

### The light law

For every moment:

1. **Colour.** Each cell's correlated colour temperature (McCamy) is placed on a fixed palette in mired
   space. 5000 K is neutral and ±90 mired reach the ends: amber at about 3450 K, ice blue at about 9100 K.
2. **Which sources shine.** A window or lamp casts rays only if it is itself at least 4× brighter than the
   room's median surface in that moment. A dark window at night, or a dim screen marked as a lamp, casts
   nothing.
3. **Direct light.** A cell brighter than 1.5× the median is directly lit. Its excess light is shared
   between the shining sources by `brightness × area / distance²`. Light that no shining source explains
   gets no rays.
4. **Rays.** Lit cells form one ray when they share a direction from a lamp (6° bins), or when they cross a
   window in the same 12 cm cell with the same direction. Only the first surface along a ray is lit; the
   rest lies in its shadow.
5. **Beams.** Every slice of a ray carries the same energy, spread over a disc as wide as the bundle of light
   paths it stands for.
   - From a lamp, a ray starts as a point and widens towards the patch it lights. Its density falls as
     `1/r²`, so it dissolves.
   - Sunlight through a window is parallel and stays a shaft.
   - Rays are drawn at 0.3 of their bundle's width so the direction stays readable.
6. **Ambient light.** A uniform density through the room, proportional to the median surface brightness
   and coloured by the median temperature.
7. **Quanta.** One quantum is the whole day's light energy divided by the splat budget (60 000).
   - A cell expecting `n = energy / quantum` splats splits into eight children when `n > 1`. Otherwise it
     emits one splat with probability `n`, at the energy centroid of the cell.
   - There is at most one splat per 4 cm cell. The densest light becomes a regular lattice and dim light a
     sparse one.
   - Each splat sits where its light passed, so rays become dotted lines.

### Time

Moments are layered by time of day, so moments from different days fill one day. The timeline has two
modes:

- **Accumulate**: light builds up as the day goes on.
- **Moment**: only the scans nearest to the current time are visible.

▶ plays the day.

| Setting | Default | What it does |
|---|---|---|
| Room brightness | 45% | camera brightness while the light is shown |
| Splat size | 6 mm | Gaussian σ of every splat |
| Splat opacity | 0.14 | peak opacity of every splat |
| Light exposure | 1.0 | tonemap `1 − exp(−exposure · light)` |
| Hide light behind objects | on | occlusion by LiDAR depth |
| Splats for the whole room | 60k | splat budget; sets the size of one quantum |
| Direct light threshold | ×1.5 median | when a surface counts as directly lit |
| Source threshold | ×4 median | when a window or lamp counts as shining |
| Rays | 1.0 | energy of direct light |
| Ambient light | 0.3 | energy of ambient light |
| Angle between rays | 6° | angular spacing of rays |
| Ray width | 0.3 | ray width relative to its bundle |
| Ray spacing in windows | 12 cm | spacing of the cells where rays cross a window |
| Colour range | ±90 mired | temperature span of the palette |

## Rendering

- **Camera feed.** YCbCr → RGB conversion happens in a Metal shader. The feed is dimmed while the light is
  shown, so the light reads better.
- **Identical splats.** Every splat is the same camera-facing quad with one Gaussian profile. Splats are
  accumulated additively into a half-resolution float target. Splats closer than 0.3 m are hidden and fade
  in up to 0.7 m.
- **Occlusion.** Each splat's distance is compared with the LiDAR depth at its point on screen, so light
  behind real objects disappears.
- **Composite.** The light is tonemapped as `1 − exp(−k · light)` and screen-blended over the camera:
  `result = light + camera · (1 − light)`.
- **Scan preview.** During a scan, the cells covered so far appear as dots coloured by the light that falls
  on them.
- **Finding the room again.** ARKit's own relocalisation matches visual features, which change with the
  light, and light is what this app records. So a reopened room is found from LiDAR geometry alone.
  - While you look around, the walls and furniture you see are matched against the earlier scans. Both AR
    sessions are gravity aligned, so only a turn about the vertical and a shift are unknown.
  - A coarse search votes over every 3° of turn, comparing 20 cm height layers on a 10 cm grid. The best
    candidates are then refined point-to-point and point-to-plane, ignoring the 30% worst matches.
  - A pose is accepted when most of what you see lands on the old surfaces, no line of sight passes through
    them, no clearly different pose comes close, and two attempts in a row agree.
  - A perfectly symmetric empty room cannot be told apart from its turned copy, so the app keeps waiting
    instead of guessing.
  - Manual alignment by two marked points (a window's corners or two lamps) remains as a fallback.

## Project structure

In the code the project still uses its working title, Lumen.

```
LumenCore/              light law as a Swift package, platform-independent, with unit tests
  Colorimetry.swift     YCbCr → RGB → linear, colour temperature, palette
  LightSource.swift     windows and lamps, window geometry
  Capture.swift         surface cells, clipping-aware accumulation
  LightField.swift      source gating, rays and beams, ambient light, quantum sampling,
                        timeline, alignment
  RoomRegistration.swift  finding a room again from LiDAR geometry
App/
  Capture/              camera settings, scan processing, source brightness probes, geometry probe
  Controller/           AR session, marking, scanning, rebuilding the light
  Rendering/            Metal: camera, splats, composite, markers, scan preview
  Storage/              rooms and moments
  UI/                   SwiftUI screen and settings
prototype/              Python model of the law on a synthetic room
```

## Running

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), run `xcodegen generate` and open
   `Lumen.xcodeproj`. The deployment target is iOS 18.
2. Choose your team under Signing & Capabilities.
3. Run on an iPhone or iPad with LiDAR. The scheme builds Release, because building the light field is slow
   without optimisation.

**In the app:**

- **Mark**: tap a lamp, or two opposite corners of a window. Sources that aren't shining in the latest
  moment turn grey.
- The big button starts and stops a scan.
- **Accumulate** / **Moment** and ▶ on the timeline.
- The eye button hides every control for a clean screen recording. A tap anywhere brings them back.
- The room name opens the room menu: new room, delete moments, reset, switch rooms.

## Limitations

- The camera measures light reflected by surfaces, not the light itself. A red wall under white light reads
  as warm light.
- Clipped highlights, such as a bulb or a sun patch, only give a lower bound.
- The direction of direct light comes from the marked sources. Light from an unmarked source gets no rays.
- Rays model where the light travels; they are not a simulation of scattering in air. The figure shows what
  the measured surfaces imply.
- LiDAR reaches about 5 m. Everything depends on ARKit tracking: in poor light the scan can drift.
- Finding a room needs some structure: you have to look around at least 150°, and an empty, perfectly
  symmetric room cannot be found automatically.

## Credits

Design and engineering by Dima Nesterov.
