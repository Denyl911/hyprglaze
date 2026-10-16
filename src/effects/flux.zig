const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const spectral = @import("spectral.zig");
const smoothstep = @import("bands.zig").smoothstep;

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// Magnetic field lines: every window is a bar magnet, a north and a south
// pole of unit charge inside it along its long axis, and the cursor is a
// compass needle that swings to follow the local field. The shader draws
// the field lines as contours of the 2D stream function (the sum of each
// pole's charge times its angle), which superposes exactly, so lines leave
// one magnet and land on its neighbours the way iron filings show it.
//
// Charges stay at exactly +-1: the stream function jumps by 2*pi*q across
// each pole's branch cut, and only an integer q keeps that jump a whole
// number of line spacings, so contours pass through the cut unbroken.
// Strength therefore comes from geometry instead: a pole pair's separation
// scales with its window, so a window opening from nothing grows its field
// in smoothly. The same lever fades magnets in and out: each is tracked
// by window address with a strength envelope that scales its separation,
// so a window opening, closing or leaving with a workspace switch grows
// its poles out of (or collapses them into) its centre instead of popping.

/// Window magnets plus the ambient one, with room for some still fading out.
pub const max_magnets = 40;
pub const max_poles = 2 * max_magnets + 2;

/// Key of the ambient magnet that holds the field while no window is on
/// screen (window addresses are never zero).
const ambient_key: u64 = 0;

const Magnet = struct {
    key: u64,
    cx: f32,
    cy: f32,
    /// Full-strength north pole offset from the centre.
    ox: f32,
    oy: f32,
    /// Window index for focus, -1 once the window is gone.
    index: f32,
    /// Envelope 0..1, linear; eased when it scales the separation.
    strength: f32,
    present: bool,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    an: spectral.Bands = .{},
    onset: spectral.Onset = .{},

    width: f32,
    height: f32,
    lines: f32,
    compass: bool,

    /// Pulse clock along the lines, quickening with music energy
    /// (accumulated so a rate change never snaps phase).
    flow: f64 = 0,
    /// Compass needle heading (radians), eased toward the local field.
    needle: f32 = 0,
    needle_seeded: bool = false,

    magnets: [max_magnets]Magnet = undefined,
    magnet_count: u32 = 0,

    /// (x, y, charge, window index or -1) per pole, surface pixels.
    poles: [max_poles][4]f32 = undefined,
    pole_count: u32 = 0,

    cached_program: c.GLuint = 0,
    loc_poles: c.GLint = -1,
    loc_pole_count: c.GLint = -1,
    loc_lines: c.GLint = -1,
    loc_flow: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_beat: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        var audio: ?*audio_mod.AudioCapture = null;
        if (params.getBool("music", true)) audio = try audio_mod.spawn(allocator, params);
        return .{
            .allocator = allocator,
            .audio = audio,
            .width = width,
            .height = height,
            .lines = @round(std.math.clamp(params.getFloat("lines", 36.0), 4.0, 64.0)),
            .compass = params.getBool("compass", true),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        if (self.audio) |audio| {
            const wave = audio.getWaveform();
            const mags = spectral.magnitudes(&wave);
            self.an.update(&mags, dt);
            self.onset.update(&mags, dt, self.an.bands[0]);
        }
        self.flow += dt * (0.35 + self.an.energy_ema * 0.9);

        for (self.magnets[0..self.magnet_count]) |*m| m.present = false;
        var on_screen = false;
        for (state.windows, 0..) |w, i| {
            if (w.w < 1.0 or w.h < 1.0) continue;
            const hw = w.w * 0.5;
            const hh = w.h * 0.5;
            // Poles sit near the ends of the long axis, like a bar magnet,
            // so the flux leaves through the window's edges. They slide
            // continuously to the diagonal as the window nears square, so
            // a resize never snaps the magnet's orientation. Polarity comes
            // from the window's address, so it survives windows being
            // added or reordered.
            const wide = smoothstep(0.7, 1.4, w.w / w.h);
            var ox = hw * 0.85 * wide;
            var oy = hh * 0.85 * (1.0 - wide);
            if ((w.address *% 0x9E3779B97F4A7C15) >> 63 == 1) {
                ox = -ox;
                oy = -oy;
            }
            const m = self.track(w.address) orelse continue;
            const strength = m.strength;
            m.* = .{
                .key = w.address,
                .cx = w.x + hw,
                .cy = w.y + hh,
                .ox = ox,
                .oy = oy,
                .index = @floatFromInt(i),
                .strength = strength,
                .present = true,
            };
            if (w.x < self.width and w.x + w.w > 0 and w.y < self.height and w.y + w.h > 0) on_screen = true;
        }
        // With no window on screen (an empty workspace, or the windows
        // riding off with a workspace slide) one broad magnet holds the
        // middle of the screen.
        if (!on_screen) {
            if (self.track(ambient_key)) |m| {
                m.cx = self.width * 0.5;
                m.cy = self.height * 0.5;
                m.ox = -self.width * 0.12;
                m.oy = 0;
                m.present = true;
            }
        }

        // Envelopes: windows grow in over ~0.4s, the ambient magnet more
        // slowly so a quick workspace flick barely stirs it. Gone magnets
        // collapse in place, then drop.
        var n: u32 = 0;
        var kept: u32 = 0;
        for (self.magnets[0..self.magnet_count]) |*m| {
            const rate: f32 = if (m.key == ambient_key) 1.2 else 2.5;
            m.strength = std.math.clamp(m.strength + (if (m.present) dt else -dt) * rate, 0.0, 1.0);
            if (!m.present) m.index = -1;
            if (!m.present and m.strength <= 0.0) continue;
            self.magnets[kept] = m.*;
            kept += 1;
            const e = smoothstep(0.0, 1.0, m.strength);
            self.poles[n] = .{ m.cx + m.ox * e, m.cy + m.oy * e, 1.0, m.index };
            self.poles[n + 1] = .{ m.cx - m.ox * e, m.cy - m.oy * e, -1.0, m.index };
            n += 2;
        }
        self.magnet_count = kept;

        if (self.compass) {
            // The needle aligns with the field the magnets make at the
            // cursor (2D Coulomb: q * d / |d|^2, north to south).
            var bx: f32 = 0;
            var by: f32 = 0;
            for (self.poles[0..n]) |p| {
                const dx = state.cursor[0] - p[0];
                const dy = state.cursor[1] - p[1];
                const r2 = @max(dx * dx + dy * dy, 400.0);
                bx += p[2] * dx / r2;
                by += p[2] * dy / r2;
            }
            if (bx * bx + by * by > 1e-12) {
                const target = std.math.atan2(by, bx);
                if (!self.needle_seeded) {
                    self.needle = target;
                    self.needle_seeded = true;
                }
                var delta = target - self.needle;
                delta -= std.math.tau * @round(delta / std.math.tau);
                self.needle += delta * @min(1.0, 4.0 * dt);
            }
            const half: f32 = 14.0;
            const ux = @cos(self.needle) * half;
            const uy = @sin(self.needle) * half;
            self.poles[n] = .{ state.cursor[0] + ux, state.cursor[1] + uy, 1.0, -2.0 };
            self.poles[n + 1] = .{ state.cursor[0] - ux, state.cursor[1] - uy, -1.0, -2.0 };
            n += 2;
        }
        self.pole_count = n;
    }

    /// The magnet for `key`, added at zero strength if new; null when the
    /// table is full (only possible past 32 windows plus fading ones).
    fn track(self: *Context, key: u64) ?*Magnet {
        for (self.magnets[0..self.magnet_count]) |*m| if (m.key == key) return m;
        if (self.magnet_count == max_magnets) return null;
        const m = &self.magnets[self.magnet_count];
        m.* = .{ .key = key, .cx = 0, .cy = 0, .ox = 0, .oy = 0, .index = -1, .strength = 0, .present = false };
        self.magnet_count += 1;
        return m;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_poles = c.glGetUniformLocation(prog.program, "iFluxPoles[0]");
            self.loc_pole_count = c.glGetUniformLocation(prog.program, "iFluxPoleCount");
            self.loc_lines = c.glGetUniformLocation(prog.program, "iFluxLines");
            self.loc_flow = c.glGetUniformLocation(prog.program, "iFluxFlow");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iFluxBass");
            self.loc_beat = c.glGetUniformLocation(prog.program, "iFluxBeat");
        }
        if (self.loc_poles >= 0 and self.pole_count > 0)
            c.glUniform4fv(self.loc_poles, @intCast(self.pole_count), @ptrCast(&self.poles[0]));
        if (self.loc_pole_count >= 0) c.glUniform1i(self.loc_pole_count, @intCast(self.pole_count));
        if (self.loc_lines >= 0) c.glUniform1f(self.loc_lines, self.lines);
        if (self.loc_flow >= 0) c.glUniform1f(self.loc_flow, @floatCast(self.flow));
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, (self.an.smooth[0] + self.an.smooth[1]) * 0.5);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.onset.beat);
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| audio_mod.shutdown(audio, self.allocator);
    }
};
