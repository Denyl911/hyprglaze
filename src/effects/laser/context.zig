const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const effects = @import("../../effects.zig");
const trace = @import("trace.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

pub const max_beams = 2;
/// Legs per beam. At the default falloff a beam fades out in ~18.
pub const max_legs = 32;
/// Must match the array sizes in shaders/laser.frag.
pub const max_segments = max_beams * max_legs;

const Beam = struct {
    origin: [2]f32,
    /// Theme palette index (0-based).
    color: i32,
    /// Last usable aim, kept while the cursor sits on the emitter.
    dir: [2]f32,
    segs: [max_legs]trace.Segment = undefined,
    count: usize = 0,
};

/// Lasers fired from screen corners toward the cursor, reflecting off
/// windows and the screen's edges and dimming by `falloff` at each bounce
/// (see trace.zig). The second beam fires from the opposite corner in
/// another theme colour. Retraced every frame from the live window rects.
pub const Context = struct {
    width: f32,
    height: f32,
    falloff: f32,
    min_intensity: f32,
    beam_width: f32,
    smoke: f32,
    speckle: f32,
    /// Speckle pattern seed, re-rolled only when a beam's aim moves.
    seed: f32 = 0,
    beams: [max_beams]Beam,
    beam_count: usize,
    now: f32 = 0,

    cached_program: c.GLuint = 0,
    loc_seg: c.GLint = -1,
    loc_int: c.GLint = -1,
    loc_count: c.GLint = -1,
    loc_split: c.GLint = -1,
    loc_width: c.GLint = -1,
    loc_color: c.GLint = -1,
    loc_color2: c.GLint = -1,
    loc_time: c.GLint = -1,
    loc_smoke: c.GLint = -1,
    loc_speckle: c.GLint = -1,
    loc_seed: c.GLint = -1,

    pub fn init(_: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) Context {
        // GL space is y-up: "bottom" is y = 0.
        const corner = params.getString("corner", "bottom-left") orelse "bottom-left";
        const inset: f32 = 2.0;
        const left = !std.mem.endsWith(u8, corner, "right");
        const bottom = !std.mem.startsWith(u8, corner, "top");
        const first: [2]f32 = .{ if (left) inset else width - inset, if (bottom) inset else height - inset };
        // The opposite corner: mirror both axes.
        const second: [2]f32 = .{ width - first[0], height - first[1] };
        const centre: [2]f32 = .{ width * 0.5, height * 0.5 };
        return .{
            .width = width,
            .height = height,
            .falloff = std.math.clamp(params.getFloat("falloff", 0.82), 0.05, 0.99),
            .min_intensity = 0.03,
            .beam_width = @max(params.getFloat("width", 1.6), 0.3),
            .smoke = std.math.clamp(params.getFloat("smoke", 0.6), 0.0, 2.0),
            .speckle = std.math.clamp(params.getFloat("speckle", 0.6), 0.0, 1.0),
            .beam_count = @intCast(std.math.clamp(params.getInt("beams", 2), 1, max_beams)),
            .beams = .{
                // Theme slots, 1-16 (the color_NN numbers): 2 is the red,
                // 5 the blue.
                .{ .origin = first, .color = themeSlot(params.getInt("color", 2)), .dir = .{ centre[0] - first[0], centre[1] - first[1] } },
                .{ .origin = second, .color = themeSlot(params.getInt("color2", 5)), .dir = .{ centre[0] - second[0], centre[1] - second[1] } },
            },
        };
    }

    fn themeSlot(slot: i64) i32 {
        return @intCast(std.math.clamp(slot, 1, 16) - 1);
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        self.now += std.math.clamp(state.dt, 0.0, 0.1);

        var rects: [32]trace.Rect = undefined;
        const n = @min(state.windows.len, rects.len);
        for (state.windows[0..n], 0..) |w, i| rects[i] = .{ .x = w.x, .y = w.y, .w = w.w, .h = w.h };

        var seed: f32 = 0;
        for (self.beams[0..self.beam_count], 0..) |*b, bi| {
            const aim: [2]f32 = .{ state.cursor[0] - b.origin[0], state.cursor[1] - b.origin[1] };
            if (aim[0] * aim[0] + aim[1] * aim[1] > 16.0) b.dir = aim;
            b.count = trace.trace(b.origin, b.dir, self.width, self.height, rects[0..n], self.falloff, self.min_intensity, &b.segs);
            // Speckle decorrelates when the geometry changes: key the
            // pattern to each beam's aim, quantized to ~a grain at range.
            const q = @round(std.math.atan2(b.dir[1], b.dir[0]) / 0.0015);
            seed += q * (if (bi == 0) @as(f32, 0.6180339) else 0.7548776);
        }
        self.seed = @mod(seed, 97.0);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_seg = c.glGetUniformLocation(prog.program, "iLaserSeg[0]");
            self.loc_int = c.glGetUniformLocation(prog.program, "iLaserLeg[0]");
            self.loc_count = c.glGetUniformLocation(prog.program, "iLaserCount");
            self.loc_split = c.glGetUniformLocation(prog.program, "iLaserSplit");
            self.loc_width = c.glGetUniformLocation(prog.program, "iLaserWidth");
            self.loc_color = c.glGetUniformLocation(prog.program, "iLaserColor");
            self.loc_color2 = c.glGetUniformLocation(prog.program, "iLaserColor2");
            self.loc_time = c.glGetUniformLocation(prog.program, "iLaserTime");
            self.loc_smoke = c.glGetUniformLocation(prog.program, "iLaserSmoke");
            self.loc_speckle = c.glGetUniformLocation(prog.program, "iLaserSpeckle");
            self.loc_seed = c.glGetUniformLocation(prog.program, "iLaserSeed");
        }
        // Beams back to back; legs from iLaserSplit on belong to beam 2.
        var seg: [max_segments][4]f32 = undefined;
        // (intensity, light arriving at the leg's start, flare twinkle, 0)
        var legs: [max_segments][4]f32 = undefined;
        var total: usize = 0;
        var split: usize = 0;
        for (self.beams[0..self.beam_count], 0..) |b, bi| {
            if (bi == 1) split = total;
            for (b.segs[0..b.count], 0..) |s, j| {
                seg[total] = .{ s.a[0], s.a[1], s.b[0], s.b[1] };
                const arrived = if (j == 0) 1.0 else b.segs[j - 1].intensity;
                const twinkle = 0.85 + 0.15 * @sin(self.now * 9.0 + @as(f32, @floatFromInt(total)) * 2.3);
                legs[total] = .{ s.intensity, arrived, twinkle, 0 };
                total += 1;
            }
        }
        if (self.beam_count == 1) split = total;
        const n: c_int = @intCast(total);
        if (self.loc_seg >= 0 and n > 0) c.glUniform4fv(self.loc_seg, n, @ptrCast(&seg[0]));
        if (self.loc_int >= 0 and n > 0) c.glUniform4fv(self.loc_int, n, @ptrCast(&legs[0]));
        if (self.loc_count >= 0) c.glUniform1i(self.loc_count, n);
        if (self.loc_split >= 0) c.glUniform1i(self.loc_split, @intCast(split));
        if (self.loc_width >= 0) c.glUniform1f(self.loc_width, self.beam_width);
        if (self.loc_color >= 0) c.glUniform1i(self.loc_color, self.beams[0].color);
        if (self.loc_color2 >= 0) c.glUniform1i(self.loc_color2, self.beams[1].color);
        // Effect-local clock keeps shader time small (fire.zig pattern).
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, @mod(self.now, 1000.0));
        if (self.loc_smoke >= 0) c.glUniform1f(self.loc_smoke, self.smoke);
        if (self.loc_speckle >= 0) c.glUniform1f(self.loc_speckle, self.speckle);
        if (self.loc_seed >= 0) c.glUniform1f(self.loc_seed, self.seed);
    }

    pub fn deinit(_: *Context) void {}
};
