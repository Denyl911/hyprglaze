//! Shadertoy compatibility: turn a Shadertoy-style fragment shader into
//! something hyprglaze's GLES 3.0 pipeline compiles.
//!
//! A Shadertoy shader defines only `void mainImage(out vec4, in vec2)` and
//! reads `iResolution`, `iTime`, `iMouse`, `iChannel0..3` and friends as
//! globals — the site owns the entry point. That convention is what
//! shadertoy.com, and every shader in kde-shader-wallpaper's library, is
//! written against. So the wrapper does four things:
//!
//!   1. Prepends `#version 300 es`, the precision qualifiers, the Shadertoy
//!      uniform block and the globals some shaders assume. `texture2D` and
//!      `textureCube` are aliased to `texture`, which is what GLSL ES 3.0
//!      calls them, so ES 2 style shaders keep compiling.
//!   2. Hoists top-level `#extension` directives into that prelude: they
//!      must appear before any declaration, and Shadertoy shaders usually
//!      carry them after their own `#version`.
//!   3. Blanks the shader's own `#version` / `precision` lines (they would
//!      fight ours), any `void main()` it carries (a duplicate definition),
//!      and a parameterless `mainImage()` overload when the real two-argument
//!      entry point is also present. Blanking keeps every newline and #line
//!      directives bracket the body, so GLSL errors name the line in the
//!      file the user wrote.
//!   4. Appends the `main()` that calls `mainImage`.
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

const version = "#version 300 es\n";

const header_rest =
    \\precision highp float;
    \\precision highp int;
    \\
    \\// --- Shadertoy host, injected by hyprglaze (src/core/shadertoy.zig) ---
    \\
    \\#define HW_PERFORMANCE 0
    \\
    \\// GLSL ES 2 sampler functions; ES 3.0 spells both `texture`.
    \\#define texture2D texture
    \\#define textureCube texture
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

const header = version ++ header_rest;

const footer_with_params =
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

/// Used by the rare shader whose only entry point is `void mainImage()` and
/// which writes the host's `fragColor` global itself.
const footer_without_params =
    \\
    \\// --- host entry point (src/core/shadertoy.zig) ---
    \\
    \\void main() {
    \\    fragCoord = gl_FragCoord.xy;
    \\    fragColor = vec4(0.0, 0.0, 0.0, 1.0);
    \\    mainImage();
    \\}
    \\
;

/// Wrap `raw` into a compilable GLES 3.0 fragment shader. The result is
/// sentinel-terminated because that is what `ShaderProgram.init` wants.
pub fn wrap(allocator: std.mem.Allocator, raw: []const u8) ![:0]u8 {
    const body = try allocator.dupe(u8, raw);
    defer allocator.free(body);

    const extensions = try hoistExtensions(allocator, body);
    defer allocator.free(extensions);

    blankDirectives(body);
    blankMain(body);

    // A few library shaders carry both `void mainImage()` (the KDE host's
    // entry point) and the canonical two-argument one. Keep the latter; a
    // parameterless overload would be dead code, and would make the call in
    // our footer ambiguous.
    const entry = mainImageKind(body);
    if (entry == .with_params) blankParameterlessMainImage(body);
    const footer = if (entry == .without_params) footer_without_params else footer_with_params;

    if (std.mem.indexOf(u8, body, "iChannel") != null) {
        log.warn("this shader reads iChannel0..3, which are not wired to any source yet " ++
            "(the samplers point at a 1x1 black texture), so whatever it samples will be black", .{});
    }

    // `#line` makes the compiler report the body's own line numbers (source
    // string 0) instead of the wrapper's. The footer gets source string 1,
    // so an error there is visibly ours.
    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}{s}{s}#line 1 0\n{s}#line 1 1\n{s}",
        .{ version, extensions, header_rest, body, footer },
        0,
    );
}

/// Move every top-level `#extension` line from `src` into a prelude buffer
/// and blank it in place. Extensions must precede declarations, and Shadertoy
/// shaders tend to put them right after their own `#version`, which the
/// wrapper blanks. Lines inside `#if`/`#endif` stay put: hoisting them would
/// change whether the extension is active.
fn hoistExtensions(allocator: std.mem.Allocator, src: []u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var conditional_depth: usize = 0;
    var offset: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (directiveName(trimmed)) |name| {
            if (std.mem.eql(u8, name, "if") or
                std.mem.eql(u8, name, "ifdef") or
                std.mem.eql(u8, name, "ifndef"))
            {
                conditional_depth += 1;
            } else if (std.mem.eql(u8, name, "endif")) {
                conditional_depth -|= 1;
            } else if (conditional_depth == 0 and std.mem.eql(u8, name, "extension")) {
                try out.appendSlice(allocator, trimmed);
                try out.append(allocator, '\n');
                const indent = line.len - trimmed.len;
                @memset(src[offset + indent .. offset + line.len], ' ');
            }
        }
        offset += line.len + 1;
    }
    return out.toOwnedSlice(allocator);
}

/// The keyword after `#`, or null for a line that is not a preprocessor
/// directive. Whitespace between `#` and the keyword is allowed.
fn directiveName(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '#') return null;
    const rest = std.mem.trimStart(u8, line[1..], " \t");
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) : (end += 1) {}
    if (end == 0) return null;
    return rest[0..end];
}

const MainImageKind = enum { with_params, without_params, missing };

/// Which `mainImage` entry point the shader provides. The canonical form wins
/// when both exist.
fn mainImageKind(src: []const u8) MainImageKind {
    var kind: MainImageKind = .missing;
    var from: usize = 0;
    while (findVoidSignature(src, "mainImage", from)) |sig| {
        if (!sig.empty) return .with_params;
        kind = .without_params;
        from = sig.start + "void".len;
    }
    return kind;
}

/// Blank parameterless `mainImage` overloads so only the canonical entry
/// point is callable from the footer. Only called after `mainImageKind`
/// confirmed a two-argument definition exists.
fn blankParameterlessMainImage(src: []u8) void {
    var from: usize = 0;
    while (findVoidSignature(src, "mainImage", from)) |sig| {
        from = if (sig.empty)
            blankFunctionBody(src, sig.start) orelse sig.start + "void".len
        else
            sig.start + "void".len;
    }
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
    const sig = findVoidSignature(src, "main", 0) orelse return;
    _ = blankFunctionBody(src, sig.start);
}

/// Blank from a function signature's `void` through its closing brace.
/// Returns the index just past the blanked range, or null when the signature
/// is a prototype (no body). On a body with no closing brace the rest of the
/// shader is blanked, so the wrapper's own `main()` at least parses and the
/// GLSL compiler can report the real error.
fn blankFunctionBody(src: []u8, start: usize) ?usize {
    var i = start;
    var depth: i32 = 0;
    var opened = false;
    while (i < src.len) {
        if (skipComment(src, i)) |next| {
            i = next;
            continue;
        }
        switch (src[i]) {
            ';' => if (!opened) return null, // prototype, nothing to blank
            '{' => {
                depth += 1;
                opened = true;
            },
            '}' => {
                depth -= 1;
                if (opened and depth == 0) {
                    blankRange(src, start, i + 1);
                    return i + 1;
                }
            },
            else => {},
        }
        i += 1;
    }
    if (opened) {
        blankRange(src, start, src.len);
        return src.len;
    }
    return null;
}

const Signature = struct {
    /// Index of the `void` that starts the signature.
    start: usize,
    /// True for `void name()` / `void name(void)`; false when there are
    /// parameters.
    empty: bool,
};

/// Index of the `void` in a `void <name>(...)` signature at or after `from`.
/// The identifier has to end right after `name`, so `main` does not match
/// `mainImage`.
fn findVoidSignature(src: []const u8, comptime name: []const u8, from: usize) ?Signature {
    var i = from;
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
        if (!std.mem.startsWith(u8, src[j..], name)) {
            i += 1;
            continue;
        }
        var k = j + name.len;
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
        if (k < src.len and src[k] == ')') return .{ .start = i, .empty = true };
        // `void name(void)`
        if (std.mem.startsWith(u8, src[k..], "void")) {
            const m = skipSpaceAndComments(src, k + "void".len);
            if (m < src.len and src[m] == ')') return .{ .start = i, .empty = true };
        }
        return .{ .start = i, .empty = false };
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

    // Blanking preserved every line, and #line points the compiler at the
    // user's file again.
    const start_marker = "#line 1 0\n";
    const end_marker = "#line 1 1\n";
    const body_start = (std.mem.indexOf(u8, out, start_marker) orelse
        return error.TestUnexpectedResult) + start_marker.len;
    const body_end = std.mem.indexOfPos(u8, out, body_start, end_marker) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(
        std.mem.count(u8, raw, "\n"),
        std.mem.count(u8, out[body_start..body_end], "\n"),
    );
}

test "wrap hoists top-level #extension lines ahead of declarations" {
    const extension = "#extension GL_OES_standard_derivatives : enable";
    const raw = "#version 300 es\n" ++ extension ++ "\n" ++
        "void mainImage(out vec4 c, in vec2 p) { c = vec4(fwidth(p.x)); }\n";
    const out = try wrapAlloc(raw);
    defer testing.allocator.free(out);

    const version_at = std.mem.indexOf(u8, out, "#version 300 es") orelse
        return error.TestUnexpectedResult;
    const extension_at = std.mem.indexOf(u8, out, extension) orelse
        return error.TestUnexpectedResult;
    const precision_at = std.mem.indexOf(u8, out, "precision highp float") orelse
        return error.TestUnexpectedResult;

    try testing.expect(version_at < extension_at);
    try testing.expect(extension_at < precision_at);
    // Hoisted, not duplicated: the body's copy was blanked.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "#extension"));
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

test "wrap calls a parameterless mainImage" {
    const raw =
        "void mainImage() {\n" ++
        "    fragColor = vec4(fragCoord / iResolution.xy, 0.0, 1.0);\n" ++
        "}\n";
    const out = try wrapAlloc(raw);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "mainImage();") != null);
    try testing.expect(std.mem.indexOf(u8, out, "mainImage(color, fragCoord)") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "void mainImage"));
}

test "wrap strips a redundant parameterless mainImage overload" {
    const raw =
        "void mainImage() { fragColor = vec4(1.0); }\n" ++
        "void mainImage(out vec4 c, in vec2 p) { c = vec4(0.5); }\n";
    const out = try wrapAlloc(raw);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "void mainImage"));
    try testing.expect(std.mem.indexOf(u8, out, "mainImage(color, fragCoord);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "vec4(1.0)") == null);
}

test "wrap defines the GLSL ES 2 texture aliases" {
    const out = try wrapAlloc("void mainImage(out vec4 c, in vec2 p) { c = texture2D(iChannel0, p); }\n");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "#define texture2D texture") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#define textureCube texture") != null);
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

test "header starts with the version directive" {
    try testing.expect(std.mem.startsWith(u8, header, "#version 300 es\n"));
}
