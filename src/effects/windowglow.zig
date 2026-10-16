const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// The glow itself is shader-side; this context only lets the focused
// window's halo breathe with the music — a slow energy swell plus a
// whisper of bass. Both uniforms are zero in silence (or with
// music = false), which collapses the shader to the classic look.
pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    /// Film-grain amplitude (config: grain, 0 disables).
    grain: f32,
    /// Grain reseed clock: ~10fps at rest, treble drives it toward 24fps.
    /// Accumulated here so the rate change never stutters the sequence.
    grain_clock: f64 = 0,

    cached_program: c.GLuint = 0,
    loc_energy: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_grain: c.GLint = -1,
    loc_grain_t: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        const music = try spectral.Analyzer.init(allocator, params);
        return .{
            .allocator = allocator,
            .music = music,
            .grain = std.math.clamp(params.getFloat("grain", 0.5), 0.0, 2.0),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        _ = self.music.update(dt);
        const treble = self.music.treble();
        self.grain_clock += dt * (10.0 + @min(treble, 1.0) * 14.0);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_energy = c.glGetUniformLocation(prog.program, "iGlowEnergy");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iGlowBass");
            self.loc_grain = c.glGetUniformLocation(prog.program, "iGlowGrain");
            self.loc_grain_t = c.glGetUniformLocation(prog.program, "iGlowGrainT");
        }
        if (self.loc_energy >= 0) c.glUniform1f(self.loc_energy, self.music.bands.energy_ema);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.music.bass());
        if (self.loc_grain >= 0) c.glUniform1f(self.loc_grain, self.grain);
        if (self.loc_grain_t >= 0) c.glUniform1f(self.loc_grain_t, @floatCast(self.grain_clock));
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
    }
};
