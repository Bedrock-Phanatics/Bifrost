const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");
const abi = @import("abi.zig");
const Plugins = @import("Plugins.zig");
const library_format = @import("Library.zig");
const Library = library_format.Library;
const Io = std.Io;
const ext = library_format.extension;
pub const library_extension = ext;

const log = std.log.scoped(.plugin);

pub const manifest_file = "plugin.toml";
pub const max_manifest_bytes = abi.max_manifest_bytes;
pub const max_plugins = 64;

pub const Manifest = struct {
    metadata: Plugins.Metadata = .{},
};

const fields = [_][]const u8{ "name", "version", "description" };

pub fn parse(gpa: std.mem.Allocator, source: []const u8, label: []const u8) error{ InvalidManifest, OutOfMemory }!Manifest {
    if (source.len > max_manifest_bytes) return invalid(label, "is larger than {d} bytes", .{max_manifest_bytes});
    if (!std.unicode.utf8ValidateSlice(source)) return invalid(label, "is not valid UTF-8", .{});
    try checkShape(source, label);
    var parser = toml.Parser(toml.Table).init(gpa);
    defer parser.deinit();
    var parsed = parser.parseString(source) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (parser.error_info) |info| if (info == .parse)
            return invalid(label, "invalid TOML at line {d}, column {d}", .{ info.parse.line, info.parse.pos });
        return invalid(label, "invalid TOML ({t})", .{err});
    };
    defer parsed.deinit();

    var values: [fields.len]?[]const u8 = @splat(null);
    var it = parsed.value.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const index = for (fields, 0..) |field, i| {
            if (std.mem.eql(u8, field, key)) break i;
        } else return invalid(label, "unknown key \"{f}\"", .{std.zig.fmtString(key)});
        if (entry.value_ptr.* != .string) return invalid(label, "{s} must be a string", .{key});
        values[index] = entry.value_ptr.string;
    }
    for (fields, values) |field, value| if (value == null) return invalid(label, "{s} is required", .{field});

    var manifest: Manifest = .{};
    const meta = &manifest.metadata;
    const name, const version, const description = .{ values[0].?, values[1].?, values[2].? };
    if (!text(name, Plugins.max_name_len)) return invalid(label, "name must be 1 to {d} bytes of printable UTF-8", .{Plugins.max_name_len});
    if (!text(version, Plugins.max_version_len)) return invalid(label, "version must be 1 to {d} bytes of printable UTF-8", .{Plugins.max_version_len});
    if (!text(description, Plugins.max_description_len))
        return invalid(label, "description must be 1 to {d} bytes of printable UTF-8", .{Plugins.max_description_len});
    @memcpy(meta.name_buffer[0..name.len], name);
    meta.name_len = @intCast(name.len);
    @memcpy(meta.version_buffer[0..version.len], version);
    meta.version_len = @intCast(version.len);
    @memcpy(meta.description_buffer[0..description.len], description);
    meta.description_len = @intCast(description.len);
    return manifest;
}

fn checkShape(source: []const u8, label: []const u8) error{InvalidManifest}!void {
    // The TOML parser overwrites duplicate keys, so bound assignments before parsing
    var assignments: usize = 0;
    var quote: u8 = 0;
    var triple = false;
    var value = false;
    var done = false;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\') {
                if (i + 1 < source.len) i += 1;
            } else if (c == quote) {
                if (triple) {
                    var end = i;
                    while (end < source.len and source[end] == quote) : (end += 1) {}
                    if (end - i < 3) continue;
                    i = end - 1;
                }
                quote = 0;
                if (value) {
                    value = false;
                    done = true;
                }
            }
            continue;
        }
        if (c == '#') {
            if (value) return invalid(label, "expected a string", .{});
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            done = false;
            continue;
        }
        if (c == '\n') {
            if (value) return invalid(label, "expected a string", .{});
            done = false;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') continue;
        if (done) return invalid(label, "expected a newline after a string", .{});
        if (c == '"' or c == '\'') {
            quote = c;
            triple = i + 2 < source.len and source[i + 1] == c and source[i + 2] == c;
            if (triple) i += 2;
        } else if (c == '=' and !value) {
            assignments += 1;
            if (assignments > fields.len) return invalid(label, "too many fields or duplicate keys", .{});
            value = true;
        } else if (value or c == '[' or c == ']' or c == '{' or c == '}' or c == '.') {
            return invalid(label, "expected three string fields", .{});
        }
    }
    if (quote != 0 or value) return invalid(label, "unterminated string or field", .{});
}

/// A missing directory means no plugins.
pub fn discover(plugins: *Plugins, io: Io, path: []const u8, disabled: []const []const u8) !void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("no {s} directory, so no plugins", .{path});
            return;
        },
        else => {
            log.warn("can't open plugin directory {s}: {t}", .{ path, err });
            return err;
        },
    };
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| plugins.gpa.free(name);
        names.deinit(plugins.gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name[0] == '.') continue;
        const kind = if (entry.kind == .unknown) (try dir.statFile(io, entry.name, .{ .follow_symlinks = false })).kind else entry.kind;
        if (kind == .directory) {
            log.warn("{s}{c}{s}: directory packages are no longer supported", .{ path, std.fs.path.sep, entry.name });
            return error.DirectoryPackage;
        }
        if (!hasExtension(entry.name)) continue;
        if (isDisabled(entry.name, disabled)) {
            log.info("skipping disabled plugin {s}", .{entry.name});
            continue;
        }
        if (kind == .sym_link) return error.SymlinkedLibrary;
        if (kind != .file) return error.NotALibrary;
        if (names.items.len == max_plugins) return error.TooManyPlugins;
        try names.ensureUnusedCapacity(plugins.gpa, 1);
        names.appendAssumeCapacity(try plugins.gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    for (names.items) |name| try load(plugins, io, dir, name);
}

fn isDisabled(name: []const u8, disabled: []const []const u8) bool {
    const stem = name[0 .. name.len - ext.len];
    for (disabled) |off| if (std.ascii.eqlIgnoreCase(off, stem)) return true;
    return false;
}

pub fn load(plugins: *Plugins, io: Io, dir: Io.Dir, name: []const u8) !void {
    if (!hasExtension(name) or std.mem.indexOfAny(u8, name, "/\\:") != null) return error.NotALibrary;
    const kind = (try dir.statFile(io, name, .{ .follow_symlinks = false })).kind;
    if (kind == .sym_link) return error.SymlinkedLibrary;
    if (kind != .file) return error.NotALibrary;
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var header: [library_format.header_len]u8 = undefined;
    library_format.checkFormat(header[0..try file.readPositionalAll(io, &header, 0)]) catch |err| {
        log.warn("{s} is not a library for {t}-{t}", .{ name, builtin.cpu.arch, builtin.os.tag });
        return err;
    };

    const path_buffer = try plugins.gpa.alloc(u8, std.fs.max_path_bytes);
    defer plugins.gpa.free(path_buffer);
    const path = path_buffer[0..try file.realPath(io, path_buffer)];
    const parent = try dir.realPathFileAlloc(io, ".", plugins.gpa);
    defer plugins.gpa.free(parent);
    if (!std.mem.eql(u8, std.fs.path.dirname(path) orelse "", parent)) return error.LibraryOutsideDirectory;

    var library = Library.open(path) catch |err| {
        log.warn("{s}: can't load it or a library it depends on ({t})", .{ path, err });
        return err;
    };
    errdefer library.close();
    const get_manifest = library.lookup(abi.ManifestFn, abi.manifest_entrypoint) orelse {
        log.warn("{s} doesn't export " ++ abi.manifest_entrypoint, .{path});
        return error.MissingManifest;
    };
    var manifest = try retrieve(plugins.gpa, get_manifest, path);
    manifest.metadata.package = path;
    if (plugins.isLoaded(manifest.metadata.name())) {
        log.warn("{s}: a plugin named {s} is already loaded", .{ path, manifest.metadata.name() });
        return error.DuplicatePlugin;
    }
    const entry = library.lookup(abi.InitFn, abi.entrypoint) orelse {
        log.warn("{s} doesn't export " ++ abi.entrypoint, .{path});
        return error.MissingEntrypoint;
    };
    try plugins.load(entry, library, &manifest.metadata);
}

pub fn retrieve(gpa: std.mem.Allocator, get: abi.ManifestFn, label: []const u8) !Manifest {
    var source: abi.Str = .{};
    if (get(&source) != .ok) return invalid(label, "manifest export failed", .{});
    if (source.len == 0 or source.len > max_manifest_bytes or source.ptr == null)
        return invalid(label, "manifest export must return 1 to {d} bytes", .{max_manifest_bytes});
    return parse(gpa, source.slice(), label);
}

fn text(bytes: []const u8, max: usize) bool {
    return bytes.len != 0 and bytes.len <= max and Plugins.printable(bytes);
}

fn hasExtension(name: []const u8) bool {
    if (name.len <= ext.len) return false;
    const tail = name[name.len - ext.len ..];
    return if (builtin.os.tag == .linux) std.mem.eql(u8, tail, ext) else std.ascii.eqlIgnoreCase(tail, ext);
}

fn invalid(label: []const u8, comptime fmt: []const u8, args: anytype) error{InvalidManifest} {
    log.warn("{s}: embedded " ++ manifest_file ++ ": " ++ fmt, .{label} ++ args);
    return error.InvalidManifest;
}

const testing = std.testing;
const valid = "name = \"Pkg\"\nversion = \"1.0.0\"\ndescription = \"A test plugin\"\n";

fn expectInvalid(source: []const u8) !void {
    try testing.expectError(error.InvalidManifest, parse(testing.allocator, source, "test"));
}

test "an embedded manifest needs three bounded printable UTF-8 strings" {
    const manifest = try parse(testing.allocator, valid, "test");
    try testing.expectEqualStrings("Pkg", manifest.metadata.name());
    try testing.expectEqualStrings("1.0.0", manifest.metadata.version());
    try testing.expectEqualStrings("A test plugin", manifest.metadata.description());
    const bad = [_][]const u8{
        "",
        "version = \"1\"\ndescription = \"d\"",
        "name = \"Pkg\"\ndescription = \"d\"",
        "name = \"Pkg\"\nversion = \"1\"",
        valid ++ "library = \"Pkg.so\"\n",
        valid ++ "name = \"Again\"\n",
        valid ++ "\"n\\u0061me\" = \"Again\"\n",
        "name = \"Pkg\" version = \"1\" description = \"d\"",
        "name = # missing value\n\"Pkg\"\nversion = \"1\"\ndescription = \"d\"",
        "name.x = \"Pkg\"\nversion = \"1\"\ndescription = \"d\"",
        "name = \"Pkg\"\nversion = 1\ndescription = \"d\"",
        "name = \"Pkg\nversion = \"1\"",
        "name = \"Pkg\xff\"\nversion = \"1\"\ndescription = \"d\"",
        "name = \"\"\nversion = \"1\"\ndescription = \"d\"",
        "name = \"Pkg\"\nversion = \"\"\ndescription = \"d\"",
        "name = \"Pkg\"\nversion = \"1\"\ndescription = \"\"",
        "name = \"Pkg\"\nversion = \"1\"\ndescription = \"ring\\u0007\"",
        "name = \"Pkg\"\nversion = \"1\"\ndescription = []",
    };
    for (bad) |source| try expectInvalid(source);
    const long_name = @as([Plugins.max_name_len + 1]u8, @splat('n'));
    const long_version = @as([Plugins.max_version_len + 1]u8, @splat('v'));
    const long_description = @as([Plugins.max_description_len + 1]u8, @splat('d'));
    try expectInvalid("name = \"" ++ long_name ++ "\"\nversion = \"1\"\ndescription = \"d\"");
    try expectInvalid("name = \"Pkg\"\nversion = \"" ++ long_version ++ "\"\ndescription = \"d\"");
    try expectInvalid("name = \"Pkg\"\nversion = \"1\"\ndescription = \"" ++ long_description ++ "\"");
    var big: [max_manifest_bytes + 1]u8 = @splat('#');
    big[0..valid.len].* = valid.*;
    try expectInvalid(&big);
    _ = try parse(testing.allocator, big[0..max_manifest_bytes], "test");
    _ = try parse(testing.allocator, "# header\r\n'name' = 'Pkg' # comment\r\n\"version\" = \"1.0.0\"\r\ndescription = \"\"\"A # = [description]\"\"\"", "test");
    const nested = "name = " ++ @as([1024]u8, @splat('['));
    try expectInvalid(nested);
}

fn parseWithAllocator(gpa: std.mem.Allocator) !void {
    _ = try parse(gpa, valid, "test");
}

test "embedded manifest allocation failures release parser storage" {
    try testing.checkAllAllocationFailures(testing.allocator, parseWithAllocator, .{});
}

test "manifest exports are checked before dereferencing their bytes" {
    const Export = struct {
        var value: abi.Str = .{};
        var status: abi.Status = .ok;
        fn get(out: ?*abi.Str) callconv(.c) abi.Status {
            out.?.* = value;
            return status;
        }
    };
    const bad = [_]abi.Str{
        .{},
        .{ .ptr = null, .len = 8 },
        .{ .ptr = @ptrFromInt(1), .len = max_manifest_bytes + 1 },
    };
    for (bad) |value| {
        Export.value = value;
        try testing.expectError(error.InvalidManifest, retrieve(testing.allocator, Export.get, "test"));
    }
    Export.value = .of(valid);
    Export.status = .failed;
    try testing.expectError(error.InvalidManifest, retrieve(testing.allocator, Export.get, "test"));
    Export.status = .ok;
    const manifest = try retrieve(testing.allocator, Export.get, "test");
    try testing.expectEqualStrings("Pkg", manifest.metadata.name());
}

test "native discovery skips hidden and disabled files and rejects directories and floods" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "none" });
    defer testing.allocator.free(missing);
    try discover(&plugins, io, missing, &.{});
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = "README.txt", .data = "copy native libraries here" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden" ++ ext, .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Broken" ++ ext, .data = "" });
    try discover(&plugins, io, root, &.{"broken"});
    try testing.expectError(error.NotALibrary, discover(&plugins, io, root, &.{}));
    try tmp.dir.createDirPath(io, "OldPackage");
    try testing.expectError(error.DirectoryPackage, discover(&plugins, io, root, &.{"Broken"}));
    try tmp.dir.deleteDir(io, "OldPackage");
    for (0..max_plugins) |i| {
        var name: [32]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "P{d}" ++ ext, .{i}), .data = "" });
    }
    try testing.expectError(error.TooManyPlugins, discover(&plugins, io, root, &.{}));
    try testing.expectEqual(@as(usize, 0), plugins.loaded.items.len);
}

test "native loading rejects missing files, invalid formats, wrong architectures and symlinks" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try testing.expectError(error.FileNotFound, load(&plugins, io, tmp.dir, "Missing" ++ ext));
    try testing.expectError(error.NotALibrary, load(&plugins, io, tmp.dir, "../Escape" ++ ext));
    for ([_][]const u8{ "", "this is not a native shared library" }) |bytes| {
        try tmp.dir.writeFile(io, .{ .sub_path = "Bad" ++ ext, .data = bytes });
        try testing.expectError(error.NotALibrary, load(&plugins, io, tmp.dir, "Bad" ++ ext));
    }
    var foreign: [library_format.header_len]u8 = @splat(0);
    foreign[0..4].* = if (builtin.os.tag == .windows) "\x7fELF".* else "MZ\x00\x00".*;
    try tmp.dir.writeFile(io, .{ .sub_path = "Bad" ++ ext, .data = &foreign });
    try testing.expectError(error.NotALibrary, load(&plugins, io, tmp.dir, "Bad" ++ ext));
    try tmp.dir.writeFile(io, .{ .sub_path = "Bad" ++ ext, .data = &library_format.fakeHeader(false) });
    try testing.expectError(error.WrongArchitecture, load(&plugins, io, tmp.dir, "Bad" ++ ext));
    try tmp.dir.createDirPath(io, "Folder" ++ ext);
    try testing.expectError(error.NotALibrary, load(&plugins, io, tmp.dir, "Folder" ++ ext));
    tmp.dir.symLink(io, "Bad" ++ ext, "Linked" ++ ext, .{}) catch return error.SkipZigTest;
    try testing.expectError(error.SymlinkedLibrary, load(&plugins, io, tmp.dir, "Linked" ++ ext));
}
