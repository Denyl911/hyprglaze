//! Shadertoy compatibility: turn a Shadertoy-style fragment shader into
//! something hyprglaze's GLES 3.0 pipeline compiles.
//!
//! A Shadertoy shader defines only `void mainImage(out vec4, in vec2)` and
//! reads `iResolution`, `iTime`, `iMouse`, `iChannel0..3` and friends as
//! globals — the site owns the entry point. That convention is what
//! shadertoy.com, and every shader in kde-shader-wallpaper's library, is
//! written against. So the wrapper does three things:
//!
//!   1. Prepends `#version 300 es`, the precision qualifiers, the Shadertoy
//!      uniform block and the globals some shaders assume.
//!   2. Blanks the shader's own `#version` / `precision` lines (they would
//!      fight ours) and any `void main()` it carries (a duplicate
//!      definition). Blanking keeps every newline, so GLSL error line
//!      numbers still point at the file the user named — subtract
//!      `header_line_count` to get the line in the wrapper.
//!   3. Appends the `main()` that calls `mainImage`.
//!
//! `HW_PERFORMANCE` is defined as 0: Shadertoy sets it per GPU tier, and the
//! cheap branch is the right default for a wallpaper.
//!
//! Measured against kde-shader-wallpaper's 247 `.frag` files: 245 compile
//! through this wrapper — 238 of the 240 non-buffer shaders plus all 7
//! `_bufferA` passes. The two that do not are broken upstream —
//! `N64_Logo.frag` has `#define SURFACE_DIST.0001` (missing the space, so the
//! macro name is `SURFACE_DIST.0001`) and `Ocean_Sky.frag` uses an undeclared
//! `intersect`.

const std = @import("std");
const iohelp = @import("io_helper.zig");

const log = std.log.scoped(.shadertoy);

/// The effect this wrapper is for. With no `shader` configured,
/// `Effect.defaultShader` uses `shaders/shadertoy/default.frag`, a demo
/// `mainImage` shader; point `--shader` (or `shader =` in the config) at
/// anything else to run it.
pub const effect_name = "shadertoy";

pub fn enabledFor(effect: []const u8) bool {
    return std.mem.eql(u8, effect, effect_name);
}

const header =
    \\#version 300 es
    \\precision highp float;
    \\precision highp int;
    \\
    \\// --- Shadertoy host, injected by hyprglaze (src/core/shadertoy.zig) ---
    \\
    \\#define HW_PERFORMANCE 0
    \\
    \\uniform vec3 iResolution;
    \\uniform float iTime;
    \\uniform float iTimeDelta;
    \\uniform float iFrameRate;
    \\uniform int iFrame;
    \\uniform vec4 iMouse;
    \\uniform vec4 iDate;
    \\uniform float iSampleRate;
    \\uniform vec3 iChannelResolution[4];
    \\uniform float iChannelTime[4];
    \\
    \\uniform sampler2D iChannel0;
    \\uniform sampler2D iChannel1;
    \\uniform sampler2D iChannel2;
    \\uniform sampler2D iChannel3;
    \\
    \\out vec4 fragColor;
    \\
    \\// Helpers in some shaders read fragCoord without taking it as a
    \\// parameter — the KDE host declares it as a global, so they were
    \\// written against that. main() fills it in before mainImage runs.
    \\vec2 fragCoord;
    \\
    \\// hyprglaze extensions, so a shader can follow the active theme.
    \\uniform vec3 iPalette[16];
    \\uniform int iPaletteSize;
    \\uniform vec3 iPaletteBg;
    \\uniform vec3 iPaletteFg;
    \\
    \\
;

const footer =
    \\
    \\// --- host entry point (src/core/shadertoy.zig) ---
    \\
    \\void main() {
    \\    fragCoord = gl_FragCoord.xy;
    \\    vec4 color = vec4(0.0, 0.0, 0.0, 1.0);
    \\    mainImage(color, fragCoord);
    \\    fragColor = color;
    \\}
    \\
;

/// Lines the wrapper adds before the shader body. A GLSL compile error on
/// wrapper line N is line N - header_line_count of the user's file.
pub const header_line_count: usize = std.mem.count(u8, header, "\n");

/// Wrap `raw` into a compilable GLES 3.0 fragment shader. The result is
/// sentinel-terminated because that is what `ShaderProgram.init` wants.
pub fn wrap(allocator: std.mem.Allocator, raw: []const u8) ![:0]u8 {
    const body = try allocator.dupe(u8, raw);
    defer allocator.free(body);

    blankDirectives(body);
    blankMain(body);

    if (std.mem.indexOf(u8, body, "iChannel") != null) {
        log.warn("this shader reads iChannel0..3, which are not wired to any source yet " ++
            "(the samplers point at a 1x1 black texture), so whatever it samples will be black", .{});
    }

    return std.fmt.allocPrintSentinel(allocator, "{s}{s}{s}", .{ header, body, footer }, 0);
}

/// Blank the `#version` and `precision` statements the shader carries: the
/// wrapper sets both, and a second `#version` is an error.
fn blankDirectives(src: []u8) void {
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const indent = line.len - trimmed.len;
        if (isVersionLine(trimmed) or isPrecisionLine(trimmed)) {
            @memset(src[offset + indent .. offset + line.len], ' ');
        }
        offset += line.len + 1;
    }
}

/// `#version ...`, allowing the whitespace a preprocessor directive may carry
/// between `#` and the keyword.
fn isVersionLine(line: []const u8) bool {
    if (line.len == 0 or line[0] != '#') return false;
    const rest = std.mem.trimStart(u8, line[1..], " \t");
    return std.mem.startsWith(u8, rest, "version");
}

/// `precision <highp|mediump|lowp> <type>;`
fn isPrecisionLine(line: []const u8) bool {
    const keyword = "precision";
    if (!std.mem.startsWith(u8, line, keyword)) return false;
    var rest = std.mem.trimStart(u8, line[keyword.len..], " \t");

    const quals = [_][]const u8{ "highp", "mediump", "lowp" };
    for (quals) |q| {
        if (!std.mem.startsWith(u8, rest, q)) continue;
        rest = std.mem.trimStart(u8, rest[q.len..], " \t");
        // `indexOfAny`, not `indexOfNone`: this wants the end of the type
        // name, i.e. the first character that IS a separator.
        const name_end = std.mem.indexOfAny(u8, rest, " \t;") orelse return false;
        if (name_end == 0) return false; // no type name
        rest = std.mem.trimStart(u8, rest[name_end..], " \t");
        return std.mem.startsWith(u8, rest, ";");
    }
    return false;
}

/// Blank a `void main() { ... }` the shader carries: the wrapper defines one,
/// so a second is a duplicate definition. Brace-matched and comment-aware, so
/// a brace inside a comment can't unbalance the scan. `mainImage` is not
/// matched — the identifier has to end right after `main`.
fn blankMain(src: []u8) void {
    const start = findMainSignature(src) orelse return;

    var i = start;
    var depth: i32 = 0;
    var opened = false;
    while (i < src.len) {
        if (skipComment(src, i)) |next| {
            i = next;
            continue;
        }
        switch (src[i]) {
            '{' => {
                depth += 1;
                opened = true;
            },
            '}' => {
                depth -= 1;
                if (opened and depth == 0) {
                    blankRange(src, start, i + 1);
                    return;
                }
            },
            else => {},
        }
        i += 1;
    }
    // No closing brace: a broken shader. Blank the rest so the wrapper's own
    // main() at least parses, and let the GLSL compiler report the real error.
    if (opened) blankRange(src, start, src.len);
}

/// Index of the `void` in a `void main(void)` / `void main()` signature, or
/// null when the shader has no `main` of its own.
fn findMainSignature(src: []const u8) ?usize {
    var i: usize = 0;
    while (i < src.len) {
        if (skipComment(src, i)) |next| {
            i = next;
            continue;
        }
        if (!std.mem.startsWith(u8, src[i..], "void")) {
            i += 1;
            continue;
        }
        var j = i + "void".len;
        if (j < src.len and !isSpace(src[j])) {
            i += 1;
            continue;
        }
        j = skipSpaceAndComments(src, j);
        if (!std.mem.startsWith(u8, src[j..], "main")) {
            i += 1;
            continue;
        }
        var k = j + "main".len;
        // `mainImage`, `mainLoop`, ... are different identifiers.
        if (k < src.len and (std.ascii.isAlphanumeric(src[k]) or src[k] == '_')) {
            i += 1;
            continue;
        }
        k = skipSpaceAndComments(src, k);
        if (k >= src.len or src[k] != '(') {
            i += 1;
            continue;
        }
        k = skipSpaceAndComments(src, k + 1);
        if (k < src.len and src[k] == ')') return i;
        // `void main(void)`
        if (std.mem.startsWith(u8, src[k..], "void")) {
            const m = skipSpaceAndComments(src, k + "void".len);
            if (m < src.len and src[m] == ')') return i;
        }
        i += 1;
    }
    return null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn skipSpaceAndComments(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len) {
        if (isSpace(src[i])) {
            i += 1;
            continue;
        }
        if (skipComment(src, i)) |next| {
            i = next;
            continue;
        }
        break;
    }
    return i;
}

/// Just past a comment starting at `i`, or null when there is none. A `//`
/// runs to the newline; a `/* */` may nest-free span newlines.
fn skipComment(src: []const u8, i: usize) ?usize {
    if (src[i] != '/' or i + 1 >= src.len) return null;
    if (src[i + 1] == '/') {
        var j = i + 2;
        while (j < src.len and src[j] != '\n') j += 1;
        return j;
    }
    if (src[i + 1] == '*') {
        var j = i + 2;
        while (j + 1 < src.len) : (j += 1) {
            if (src[j] == '*' and src[j + 1] == '/') return j + 2;
        }
        return src.len;
    }
    return null;
}

/// Overwrite [from, to) with spaces, keeping newlines so line numbers hold.
fn blankRange(src: []u8, from: usize, to: usize) void {
    for (src[from..to]) |*c| {
        if (c.* != '\n') c.* = ' ';
    }
}

// --- tests ---

const testing = std.testing;

fn wrapAlloc(raw: []const u8) ![:0]u8 {
    return wrap(testing.allocator, raw);
}

test "wrap injects the host header and footer around mainImage" {
    const out = try wrapAlloc("void mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }\n");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.startsWith(u8, out, "#version 300 es\n"));
    try testing.expect(std.mem.indexOf(u8, out, "uniform sampler2D iChannel0;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "mainImage(color, fragCoord);") != null);
    // The shader's own body survives untouched.
    try testing.expect(std.mem.indexOf(u8, out, "void mainImage(out vec4 c, in vec2 p)") != null);
}

test "wrap blanks the shader's own #version and precision lines" {
    const raw = "#version 330 core\nprecision highp float;\nvoid mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }\n";
    const out = try wrapAlloc(raw);
    defer testing.allocator.free(out);

    // Only the wrapper's own #version, and only its own precisions.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "#version"));
    try testing.expect(std.mem.indexOf(u8, out, "#version 330 core") == null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "precision highp"));
    // Blanking preserved the line count, so GLSL error lines still map.
    try testing.expectEqual(
        @as(usize, 3 + header_line_count),
        std.mem.count(u8, out, "\n") - std.mem.count(u8, footer, "\n"),
    );
}

test "wrap strips a main() the shader carries but keeps mainImage" {
    const raw =
        \\void mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }
        \\void main() {
        \\    vec4 c;
        \\    mainImage(c, vec2(0.0));
        \\    gl_FragColor = c; // brace in a comment: }
        \\}
        \\
    ;
    const out = try wrapAlloc(raw);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "gl_FragColor") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "void mainImage"));
    // Exactly one `void main()`: the wrapper's, plus the one in the footer.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "void main()"));
}

test "wrap does not mistake mainImage for main" {
    const raw = "void mainImage(out vec4 c, in vec2 p) { c = vec4(0.5); }\n";
    const out = try wrapAlloc(raw);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "vec4(0.5)") != null);
}

test "wrap strips void main(void)" {
    const raw = "void mainImage(out vec4 c, in vec2 p) { c = vec4(1.0); }\nvoid main(void) { vec4 c; mainImage(c, vec2(0.0)); }\n";
    const out = try wrapAlloc(raw);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "void main("));
}

test "the bundled demo shader wraps" {
    const raw = iohelp.readFileAlloc(testing.allocator, "shaders/shadertoy/default.frag", 1 << 20) catch
        return error.SkipZigTest;
    defer testing.allocator.free(raw);

    const out = try wrapAlloc(raw);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "void mainImage(") != null);
    // The body carries neither a #version nor its own main; the wrapper
    // supplies both, so a regression that makes them duplicate shows here.
    try testing.expect(std.mem.startsWith(u8, out, "#version 300 es\n"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\n#version"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "void main("));
}

test "header_line_count matches the injected header" {
    try testing.expect(header_line_count > 10);
    try testing.expect(std.mem.startsWith(u8, header, "#version 300 es\n"));
}
