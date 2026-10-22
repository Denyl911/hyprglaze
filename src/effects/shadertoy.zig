//! Host for Shadertoy-style shaders: the effect that runs anything written
//! against the `mainImage` convention, including the shader library in
//! kde-shader-wallpaper.
//!
//! `src/core/shadertoy.zig` does the source work (injects `#version 300 es`,
//! the Shadertoy uniform block and the `main()` that calls `mainImage`) and
//! is applied by `renderer.loadShader` whenever this effect is the active
//! one. This file supplies the uniforms the shared `ShaderProgram` does not
//! already set, and the `iChannel0..3` samplers.
//!
//! What comes for free from `ShaderProgram.draw`: `iResolution`, `iTime`,
//! `iMouse` (xy; z/w are always 0 — hyprglaze does not read mouse buttons, so
//! shaders that gate interaction on `iMouse.z` render static) and the theme
//! palette, which is why the wrapper also declares `iPalette*`.
//!
//! Usage: `hyprglaze --effect shadertoy --shader /path/to/thing.frag`, or
//! `effect = "shadertoy"` plus `shader = "..."` in the config. With no
//! `shader` set it runs the bundled demo, `shaders/shadertoy/default.frag`.

const std = @import("std");

const shader_mod = @import("../core/shader.zig");
const iohelp = @import("../core/io_helper.zig");
const effects = @import("../effects.zig");
const Uniforms = @import("uniforms.zig").Uniforms;

const c = @cImport({
    @cInclude("GLES3/gl3.h");
    @cInclude("time.h");
});

/// Channels the wrapper declares.
const n_channels = 4;

/// What effects/audio.zig captures at; Shadertoy's iSampleRate.
const sample_rate: f32 = 44100.0;

pub const Context = struct {
    /// iFrame: frames since the effect started. Starts at -1 so the first
    /// update — which runs before the first draw — reports 0, like Shadertoy.
    /// Wrapping add: a shader that multiplies iFrame would overflow an i32
    /// after ~2 years at 60fps.
    frame: i32 = -1,
    /// Last frame's dt, and a smoothed rate, for iTimeDelta / iFrameRate.
    dt: f32 = 1.0 / 60.0,
    dt_ema: f32 = 1.0 / 60.0,
    /// iTime, for iChannelTime. Channels are static black for now, but the
    /// KDE host gives them iTime too, and zero makes some shaders take a
    /// "no video input" branch.
    time: f32 = 0.0,
    /// One 1x1 black texture, bound to every channel. Sampling an unbound
    /// texture unit is driver-defined; sampling a black texel is not, and it
    /// is the honest answer for a shader asking for a channel it has not
    /// been given. Replaced by real sources when channels are wired.
    blank_tex: c.GLuint = 0,

    u: Uniforms(.{
        .frame = "iFrame",
        .date = "iDate",
        .time_delta = "iTimeDelta",
        .frame_rate = "iFrameRate",
        .sample_rate = "iSampleRate",
        .channel0 = "iChannel0",
        .channel1 = "iChannel1",
        .channel2 = "iChannel2",
        .channel3 = "iChannel3",
        .channel_resolution = "iChannelResolution[0]",
        .channel_time = "iChannelTime[0]",
    }) = .{},

    pub fn init() Context {
        return .{};
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        self.frame +%= 1;
        self.dt = std.math.clamp(state.dt, 0.0, 0.25);
        self.time = state.time;
        // ~20 frame time constant, so iFrameRate is steady enough to drive
        // something with rather than twitching every frame.
        self.dt_ema += (self.dt - self.dt_ema) * 0.05;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        if (self.blank_tex == 0) self.blank_tex = makeBlankTexture();
        for (0..n_channels) |unit| {
            c.glActiveTexture(@as(c.GLenum, c.GL_TEXTURE0) + @as(c.GLuint, @intCast(unit)));
            c.glBindTexture(c.GL_TEXTURE_2D, self.blank_tex);
        }

        self.u.use(prog.program);
        self.u.int(.channel0, 0);
        self.u.int(.channel1, 1);
        self.u.int(.channel2, 2);
        self.u.int(.channel3, 3);
        self.u.int(.frame, self.frame);
        self.u.f1(.time_delta, self.dt);
        self.u.f1(.frame_rate, 1.0 / self.dt_ema);
        self.u.f1(.sample_rate, sample_rate);
        const d = wallDate();
        self.u.f4(.date, d[0], d[1], d[2], d[3]);

        // The channels are all the same 1x1 black texture, so report that
        // size rather than leaving the array zeroed — a shader that divides
        // by iChannelResolution[0].xy would otherwise get 0/0.
        const resolution = [_][3]f32{
            .{ 1.0, 1.0, 1.0 },
            .{ 1.0, 1.0, 1.0 },
            .{ 1.0, 1.0, 1.0 },
            .{ 1.0, 1.0, 1.0 },
        };
        const times = [_]f32{ self.time, self.time, self.time, self.time };
        self.u.f3v(.channel_resolution, n_channels, &resolution);
        self.u.f1v(.channel_time, n_channels, &times);
    }

    pub fn deinit(self: *Context) void {
        if (self.blank_tex != 0) {
            c.glDeleteTextures(1, &self.blank_tex);
            self.blank_tex = 0;
        }
    }
};

/// Shadertoy's iDate: `(year, month, day, seconds since midnight)`, with the
/// same field ranges as JavaScript's Date: month 0-based, day of month 1-based.
/// Local time, like the browser's clock (and the KDE host). Zeros if the clock
/// is unreadable, which no shader should depend on.
fn wallDate() [4]f32 {
    const secs = iohelp.wallSeconds();
    if (secs <= 0) return .{ 0, 0, 0, 0 };

    var t: c.time_t = @intCast(secs);
    var tm: c.tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return .{ 0, 0, 0, 0 };

    return .{
        @floatFromInt(tm.tm_year + 1900),
        @floatFromInt(tm.tm_mon), // 0-11
        @floatFromInt(tm.tm_mday), // 1-31
        @floatFromInt(tm.tm_hour * 3600 + tm.tm_min * 60 + tm.tm_sec),
    };
}

fn makeBlankTexture() c.GLuint {
    var tex: c.GLuint = 0;
    c.glGenTextures(1, &tex);
    c.glBindTexture(c.GL_TEXTURE_2D, tex);
    const black = [_]u8{ 0, 0, 0, 0 };
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, 1, 1, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &black);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    return tex;
}
