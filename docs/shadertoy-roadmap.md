# Shadertoy roadmap

Status of the `shadertoy` effect: what shipped, what is next, and the
constraints that shaped it. The wrapper lives in `src/core/shadertoy.zig`; the
effect (uniforms, frame state, channels) in `src/effects/shadertoy.zig`.

## Phase 1 — run Shadertoy shaders (done, `c6a680c`)

- Wrap `void mainImage(out vec4, in vec2)` files into a GLES 3.0 fragment
  shader: inject the version, precision qualifiers, uniform block and `main()`.
- Support the globals shaders assume: `iResolution`, `iTime`, `iTimeDelta`,
  `iFrameRate`, `iFrame`, `iMouse`, `iDate`, `iSampleRate`, `fragCoord`,
  `iChannelResolution`, `iChannelTime`, plus the hyprglaze palette uniforms.
- Blank a shader's own `#version`, `precision` and `main()`, preserving line
  numbers.
- Bundle `shaders/shadertoy/default.frag`; make `--shader` / `shader =` point
  at any file.
- Verified against kde-shader-wallpaper's library: 245 of 247 root `.frag`
  files compile. The two failures are upstream bugs (`N64_Logo.frag`,
  `Ocean_Sky.frag`), not wrapper gaps.

The KDE clone is a local test corpus only. It is not committed or vendored
(licenses); committed tests use synthetic fixtures under `tools/fixtures/`.

## Phase 2 — robustness and validation (this change)

- Hoist top-level `#extension` directives above declarations, and blank them
  in place so line numbers survive. Extensions inside `#if` stay conditional.
- Define `texture2D` and `textureCube` as `texture` for GLSL ES 2 style
  shaders.
- Accept a parameterless `void mainImage()` (the KDE host convention) with a
  matching footer; strip it when the canonical two-argument entry point also
  exists.
- Bracket the body with `#line 1 0` / `#line 1 1`, so compiler errors name the
  line in the user's file instead of the wrapper's.
- Add `src/shadertoy_wrap.zig` (`zig build shadertoy-wrap -- file.frag`) and
  synthetic fixtures; CI wraps and `glslangValidator`s all of them.
- Reset `iTime` to 0 when the shader/effect is (re)loaded, matching Shadertoy,
  instead of continuing on the daemon's clock.

## Phase 3 — inputs

- Wire `iChannel0..3` to real sources: still images, video frames, and audio
  textures (waveform/FFT), with per-channel config.
- Upload real `iChannelResolution` and `iChannelTime` values for the bound
  sources; today they describe a 1×1 black fallback.
- Feed `iMouse` from the pointer and clicks; decide whether the wallpaper
  should see motion when no window has focus.
- Add keyboard state (`iKeyboard`) if a cheap, compositor-safe source exists.
- Keep the current warning when a shader samples an unbound channel.

## Phase 4 — multi-pass shaders

- Detect and run `_bufferA`–`_bufferD` passes: each buffer owns an FBO and the
  previous frames, in dependency order, before the image pass.
- Map Shadertoy's buffer uniforms and `iChannel` bindings between buffers.
- Support cubemap/volume channel types where the source can provide them.
- Handle feedback safely: one read texture, one write FBO per pass, no
  read/write aliasing.
- Revisit shader time: each loaded pass shares the image pass's time base, and
  `iFrame`/`iTimeDelta` stay consistent across passes.

## Phase 5 — KDE corpus and polish

- KDE-only window uniforms (`iWindowCount`, `iWindowRects`) and any remaining
  `WindowReactive` extras, fed from the Hyprland window snapshot.
- Compile cache keyed by wrapped source hash, so switching back to a shader is
  instant.
- Surface GLSL errors in the log with the source file and line (the `#line`
  work in phase 2 makes this accurate).
- Optional hot-reload of the current shader on file change, without a config
  reload.
- Keep a small, committed fixture per wrapper rule and one full-source smoke
  test; never commit the KDE shader corpus.

## Ground rules

- `zig build test` and the fixture validation in CI must stay green.
- Wrapper output is `#version 300 es`; host-specific escape hatches go behind
  feature checks, not into the shaders.
- A shader that fails to compile must leave the previous wallpaper running.
