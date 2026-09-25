# Architecture

## Concept

The desktop image lives on a fixed plane at the **release angle**. The physical screen is a pane of
frosted glass rotating about the hinge. For any lid angle, each point of the glass shows the part of
the content plane behind it along the viewer's line of sight, blurred in proportion to the distance
between glass and plane along that line. That distance is zero at the hinge and grows towards the
top edge. At the release angle glass and plane coincide and the output equals the desktop exactly,
which lets the overlay disappear without a visible change.

The lid position alone drives the effect. Alignment with the physical lid has to be judged by hand
on the real screen.

## Pipeline

```
LidSensor ──► MotionModel ──► FoldState ──┐
                                          ├──► Effect ──► OverlayWindow (CAMetalLayer)
DisplayCapture ──► frame ──► BlurPyramid ─┘
                    RenderHost: one frame per display refresh
```

| Component | Responsibility |
|---|---|
| `LidSensor` | Polls the HID lid-angle sensor on its own thread ([sensor notes](sensor.md)). Publishes the newest sample, reports loss and reconnects. |
| `MotionModel` | Turns samples into a `FoldState`: where the glass is, where the content plane is, and whether the overlay is visible. Owns smoothing, thresholds and hold policies. |
| `DisplayCapture` | ScreenCaptureKit stream of the built-in display, excluding the app's own windows. Frames stay on the GPU (IOSurface → `MTLTexture` without copying). 5 fps while hidden, 60 fps while shown. |
| `BlurPyramid` | Half-resolution mip chain of each new frame with a known variance per level. |
| `Effect` | Draws one frame from the captured desktop and the fold state. |
| `OverlayWindow` | Borderless, click-through panel above all windows on every Space, built-in display only. |
| `RenderHost` | Display-link loop: motion model → visibility → pyramid → effect → present. |
| `AppModel` | Decides when the engine runs, applies settings and presets, publishes status to the UI. |

`MotionModel` and `Effect` are protocols. The app ships one of each (`OpticalReferenceMotion` and
`OpticalGlassEffect`); new ones are registered in `ComponentRegistry`, and their parameters get
generated controls in Settings → Tuning.

## Release rule

The overlay is drawn only below the release angle the motion model is tuned to, and
`FoldLimits.releaseAngle` (120°) caps every tuning. Each motion model enforces this itself. Any
amount it smooths separately from the lid angle is limited by what its own smoothed lid angle
allows, which keeps filter lag from holding the effect above the release angle. The render host
leaves violations visible on purpose. `FoldLimitsInvariantTests` drives every model through
realistic lid movements (brisk and slow closes, stops just above the release angle, dither on a
rounding boundary, sensor gaps) at fine and whole-degree resolution and fails on any violation.

## Motion between sensor updates

The sensor refreshes about every 100 ms, also while the lid moves. A brisk close therefore arrives
in steps of about 10°. Extrapolation overshoots at every stop and could flash the effect above the
release angle. `SampleInterpolator` plays the lid back about 0.1 s behind real time and interpolates
linearly between readings, which keeps it within the measured values. A critically damped spring
(closed form, frame-rate independent) follows the result.

## Power tiers

While enabled, the engine is in one of two tiers:

- **Dormant**: only the sensor runs, 5 reads per second at utility priority. `ArmingDetector`
  watches every reading on the sensor thread. Capture, display link and drawing are stopped; after
  30 s the overlay's drawable pool (about 100 MB at native size) and the blur pyramid are freed too.
  A CAMetalLayer keeps its drawable pool for its whole lifetime, and freeing the pool means
  replacing the layer.
- **Awake**: capture (about 25 ms to the first frame with a cached content filter), display link and
  120 Hz sensor reads.

`ArmingDetector` measures movement from the last rest position (held within 0.5° for 0.6 s). A knock
that springs back adds up to nothing, while a slow, deliberate close keeps adding up:

| Lid position | Wakes on |
|---|---|
| At or above release + 15° | Ignored |
| Between release and release + 15° | Closing by 2.5° |
| Below the release angle | Moving by 6° in either direction |

`DormancyTimer` returns the engine to dormant once nothing has been drawn and the lid has been still
for 1 s. Waking from sleep starts awake. Pause is dormant with the detector off.

## Safety

- The overlay is ordered in transparent and revealed only after its first frame is presented.
- GPU errors, missing drawables, sensor loss and capture failure remove it at once. Drawing resumes
  on the next wake, which reports a permanent failure once per wake.
- Sleep, lock, user switch and display changes stop the engine. Across plain sleep the last frame is
  kept for the first frames after waking; on lock or user switch it is discarded.
- Capture starts and stops run strictly in request order; a start that is superseded while in
  flight abandons its stream.

## Rendering details

- **Colour**: capture in Display P3, sampled through `_srgb` views (linear light), blurred and shaded
  in linear light, written to an `_srgb` drawable tagged Display P3. At rest the output equals the
  captured desktop bit for bit.
- **Blur**: each pyramid step applies a [1,5,10,10,5,1]/32 binomial kernel; `mdBlurSample`
  (`Shaders/Common.h`) serves any per-pixel Gaussian σ by interpolating levels in variance with cubic
  B-spline reconstruction. The self-test measures edge widths within a few percent of a true
  Gaussian from σ = 2 to 192 px.
- **Geometry**: `OpticalGlass.metal` works in physical millimetres from `CGDisplayScreenSize`. Eye
  distance and hinge offset are real lengths and independent of resolution.

## Adding a component

**Motion model** (`Sources/MacDuoKit/Motion/Models/<Name>/`): a value type conforming to
`MotionModel`. `update` runs once per display frame while the app is awake and pauses while it is
dormant, which means consecutive calls can be far apart. Smoothing must be time-based. Treat a
missing or stale sample (`isFresh` false) as "sensor unavailable" and return a hidden state. Expose
the release angle through `releaseAngleParameter`; the menu bar slider and the arming detector read
it from there. Add the model to `FoldLimitsInvariantTests` and give it its own tests.

**Effect** (`Sources/MacDuo/Effects/<Name>/`): a `@MainActor` class conforming to `Effect`, a
fragment function using `Shaders/Common.h`, and a `<Name>Types.h` uniforms header included from
`Shaders/BridgingHeader.h`. Draw with `FullscreenPipeline` (texture 0 source, texture 1 pyramid,
buffer 0 `BlurInfo`, buffer 1 uniforms). Work in linear light, and return the source pixel exactly
when the glass lies on the content plane. The self-test runs every registered effect.

Parameters are declared as `ParameterSpec`s with stable ids; their names are localized with
`String(localized:)`.
