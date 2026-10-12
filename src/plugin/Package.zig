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
pub const max_manifest_bytes = 4096;
pub const max_library_len = 255;
pub const max_packages = 64;

pub const Manifest = struct {
    metadata: Plugins.Metadata = .{},
    library_buffer: [max_library_len]u8 = undefined,
    library_len: u8 = 0,

    pub fn library(self: *const Manifest) []const u8 {
        return self.library_buffer[0..self.library_len];
    }
};

const fields = [_][]const u8{ "name", "version", "description", "library" };

pub fn parse(gpa: std.mem.Allocator, source: []const u8, label: []const u8) error{ InvalidManifest, OutOfMemory }!Manifest {
    if (source.len > max_manifest_bytes) return invalid(label, "is larger than {d} bytes", .{max_manifest_bytes});
    if (!std.unicode.utf8ValidateSlice(source)) return invalid(label, "is not valid UTF-8", .{});
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
    const name, const version, const description, const library = .{ values[0].?, values[1].?, values[2].?, values[3].? };
    if (!text(name, Plugins.max_name_len)) return invalid(label, "name must be 1 to {d} bytes of printable UTF-8", .{Plugins.max_name_len});
    if (!text(version, Plugins.max_version_len)) return invalid(label, "version must be 1 to {d} bytes of printable UTF-8", .{Plugins.max_version_len});
    if (!text(description, Plugins.max_description_len))
        return invalid(label, "description must be 1 to {d} bytes of printable UTF-8", .{Plugins.max_description_len});
    if (!text(library, max_library_len)) return invalid(label, "library must be 1 to {d} bytes of printable UTF-8", .{max_library_len});
    if (std.mem.indexOfAny(u8, library, "/\\:") != null)
        return invalid(label, "library must be a file name inside the package, not a path", .{});
    if (!hasExtension(library)) return invalid(label, "library must be a {s} file", .{ext});

    @memcpy(meta.name_buffer[0..name.len], name);
    meta.name_len = @intCast(name.len);
    @memcpy(meta.version_buffer[0..version.len], version);
    meta.version_len = @intCast(version.len);
    @memcpy(meta.description_buffer[0..description.len], description);
    meta.description_len = @intCast(description.len);
    @memcpy(manifest.library_buffer[0..library.len], library);
    manifest.library_len = @intCast(library.len);
    return manifest;
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
        switch (kind) {
            .directory => {},
            .sym_link => {
                log.warn("{s}{c}{s} is a symlink; plugin packages must be real directories", .{ path, std.fs.path.sep, entry.name });
                return error.SymlinkedPackage;
            },
            .file => {
                if (!hasExtension(entry.name)) continue;
                log.warn("{s}{c}{s} is a loose library; move it into its own directory next to a " ++ manifest_file, .{ path, std.fs.path.sep, entry.name });
                return error.LooseLibrary;
            },
            else => continue,
        }
        if (names.items.len == max_packages) {
            log.warn("{s} has more than {d} plugin packages", .{ path, max_packages });
            return error.TooManyPlugins;
        }
        try names.ensureUnusedCapacity(plugins.gpa, 1);
        names.appendAssumeCapacity(try plugins.gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    next: for (names.items) |name| {
        for (disabled) |off| {
            if (!std.ascii.eqlIgnoreCase(off, name)) continue;
            log.info("skipping disabled plugin package {s}", .{name});
            continue :next;
        }
        try load(plugins, io, dir, name);
    }
}

pub fn load(plugins: *Plugins, io: Io, parent: Io.Dir, name: []const u8) !void {
    var dir = parent.openDir(io, name, .{ .follow_symlinks = false }) catch |err| {
        log.warn("can't open plugin package {s}: {t}", .{ name, err });
        return err;
    };
    defer dir.close(io);
    const path_buffer = try plugins.gpa.alloc(u8, std.fs.max_path_bytes);
    defer plugins.gpa.free(path_buffer);
    const path = path_buffer[0..try dir.realPath(io, path_buffer)];

    const source = dir.readFileAlloc(io, manifest_file, plugins.gpa, .limited(max_manifest_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound => {
            log.warn("{s} has no " ++ manifest_file ++ "; every plugin package needs one", .{path});
            return error.MissingManifest;
        },
        error.StreamTooLong => return invalid(path, "is larger than {d} bytes", .{max_manifest_bytes}),
        else => {
            log.warn("{s}{c}" ++ manifest_file ++ ": {t}", .{ path, std.fs.path.sep, err });
            return err;
        },
    };
    defer plugins.gpa.free(source);
    var manifest = try parse(plugins.gpa, source, path);
    manifest.metadata.package = path;
    if (plugins.isLoaded(manifest.metadata.name())) {
        log.warn("{s}: a plugin named {s} is already loaded", .{ path, manifest.metadata.name() });
        return error.DuplicatePlugin;
    }

    var library = try openLibrary(plugins.gpa, io, dir, path, manifest.library());
    errdefer library.close();
    const entry = library.lookup(abi.InitFn, abi.entrypoint) orelse {
        log.warn("{s}{c}{s} doesn't export " ++ abi.entrypoint, .{ path, std.fs.path.sep, manifest.library() });
        return error.MissingEntrypoint;
    };
    try plugins.load(entry, library, &manifest.metadata);
}

fn openLibrary(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, package: []const u8, name: []const u8) !Library {
    const file = dir.openFile(io, name, .{}) catch |err| {
        log.warn("{s}{c}{s}: {t}", .{ package, std.fs.path.sep, name, err });
        return err;
    };
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) {
        log.warn("{s}{c}{s} is not a file", .{ package, std.fs.path.sep, name });
        return error.NotALibrary;
    }
    var header: [library_format.header_len]u8 = undefined;
    library_format.checkFormat(header[0..try file.readPositionalAll(io, &header, 0)]) catch |err| {
        log.warn("{s}{c}{s} is not a library for {t}-{t}", .{ package, std.fs.path.sep, name, builtin.cpu.arch, builtin.os.tag });
        return err;
    };

    const real_buffer = try gpa.alloc(u8, std.fs.max_path_bytes);
    defer gpa.free(real_buffer);
    const real = real_buffer[0..try file.realPath(io, real_buffer)];
    if (!std.mem.eql(u8, std.fs.path.dirname(real) orelse "", package)) {
        log.warn("{s}{c}{s} resolves to {s}, outside its package", .{ package, std.fs.path.sep, name, real });
        return error.LibraryOutsidePackage;
    }
    return Library.open(real) catch |err| {
        log.warn("{s}: can't load it or a library it depends on ({t})", .{ real, err });
        return err;
    };
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
    log.warn("{s}{c}" ++ manifest_file ++ ": " ++ fmt, .{ label, std.fs.path.sep } ++ args);
    return error.InvalidManifest;
}

const testing = std.testing;
const head = "name = \"Pkg\"\nversion = \"1.0.0\"\ndescription = \"A test package\"\n";
const valid = head ++ "library = \"Pkg" ++ ext ++ "\"\n";

fn expectInvalid(source: []const u8) !void {
    try testing.expectError(error.InvalidManifest, parse(testing.allocator, source, "test"));
}

fn writePackage(parent: Io.Dir, name: []const u8, manifest: ?[]const u8, library: ?[]const u8) !void {
    const io = testing.io;
    var dir = try parent.createDirPathOpen(io, name, .{});
    defer dir.close(io);
    if (manifest) |source| try dir.writeFile(io, .{ .sub_path = manifest_file, .data = source });
    if (library) |bytes| try dir.writeFile(io, .{ .sub_path = "Pkg" ++ ext, .data = bytes });
}

test "a manifest needs every field as a bounded printable string and a bare library file name" {
    const manifest = try parse(testing.allocator, valid, "test");
    try testing.expectEqualStrings("Pkg", manifest.metadata.name());
    try testing.expectEqualStrings("1.0.0", manifest.metadata.version());
    try testing.expectEqualStrings("A test package", manifest.metadata.description());
    try testing.expectEqualStrings("Pkg" ++ ext, manifest.library());

    const library = "library = \"Pkg" ++ ext ++ "\"\n";
    try expectInvalid("");
    try expectInvalid(head);
    try expectInvalid("version = \"1.0.0\"\ndescription = \"d\"\n" ++ library);
    try expectInvalid("name = \"Pkg\"\ndescription = \"d\"\n" ++ library);
    try expectInvalid("name = \"Pkg\"\nversion = \"1.0.0\"\n" ++ library);
    try expectInvalid(valid ++ "permissions = \"all\"\n");
    try expectInvalid("name = \"Pkg\"\nversion = 1\ndescription = \"d\"\n" ++ library);
    try expectInvalid(head ++ "library = [\"Pkg" ++ ext ++ "\"]\n");
    try expectInvalid(head ++ "[library]\npath = \"Pkg" ++ ext ++ "\"\n");
    try expectInvalid("name = \"Pkg\nversion = \"1.0.0\"\n");
    try expectInvalid("name = \"Pkg\xff\"\nversion = \"1.0.0\"\ndescription = \"d\"\n" ++ library);
    try expectInvalid("name = \"\"\nversion = \"1.0.0\"\ndescription = \"d\"\n" ++ library);
    try expectInvalid("name = \"Pkg\"\nversion = \"1.0.0\"\ndescription = \"\"\n" ++ library);
    try expectInvalid("name = \"Pkg\"\nversion = \"1.0.0\"\ndescription = \"ring\\u0007\"\n" ++ library);
    const long_name: [Plugins.max_name_len + 1]u8 = @splat('n');
    const long_description: [Plugins.max_description_len + 1]u8 = @splat('d');
    try expectInvalid("name = \"" ++ long_name ++ "\"\nversion = \"1.0.0\"\ndescription = \"d\"\n" ++ library);
    try expectInvalid("name = \"Pkg\"\nversion = \"1.0.0\"\ndescription = \"" ++ long_description ++ "\"\n" ++ library);

    const names = [_][]const u8{ "", ext, "Pkg.txt", "Pkg" ++ ext ++ ".txt", "Pkg", "../Pkg" ++ ext, "..\\\\Pkg" ++ ext, "sub/Pkg" ++ ext, "/abs/Pkg" ++ ext, "C:\\\\Pkg" ++ ext, "C:Pkg" ++ ext, "Pkg" ++ ext ++ ":stream", "line\\nbreak" ++ ext };
    for (names) |name| {
        var buffer: [256]u8 = undefined;
        try expectInvalid(try std.fmt.bufPrint(&buffer, head ++ "library = \"{s}\"\n", .{name}));
    }
    var big: [max_manifest_bytes + 1]u8 = @splat('#');
    big[0..valid.len].* = valid.*;
    try expectInvalid(&big);
    _ = try parse(testing.allocator, big[0..max_manifest_bytes], "test");
}

test "a package needs its manifest and a library for this platform inside it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();

    try writePackage(tmp.dir, "Empty", null, null);
    try testing.expectError(error.MissingManifest, load(&plugins, io, tmp.dir, "Empty"));
    try testing.expectError(error.FileNotFound, load(&plugins, io, tmp.dir, "Nowhere"));
    try writePackage(tmp.dir, "Broken", "name = ", null);
    try testing.expectError(error.InvalidManifest, load(&plugins, io, tmp.dir, "Broken"));
    try writePackage(tmp.dir, "Missing", valid, null);
    try testing.expectError(error.FileNotFound, load(&plugins, io, tmp.dir, "Missing"));
    try writePackage(tmp.dir, "Text", valid, "just some text pretending to be a library, long enough to be read as a header");
    try testing.expectError(error.NotALibrary, load(&plugins, io, tmp.dir, "Text"));
    try writePackage(tmp.dir, "Short", valid, "");
    try testing.expectError(error.NotALibrary, load(&plugins, io, tmp.dir, "Short"));
    if (builtin.os.tag != .macos) {
        try writePackage(tmp.dir, "Foreign", valid, &library_format.fakeHeader(false));
        try testing.expectError(error.WrongArchitecture, load(&plugins, io, tmp.dir, "Foreign"));
    }
    try writePackage(tmp.dir, "Folder", valid, null);
    try tmp.dir.createDirPath(io, "Folder" ++ std.fs.path.sep_str ++ "Pkg" ++ ext);
    if (load(&plugins, io, tmp.dir, "Folder")) |_| return error.TestUnexpectedResult else |err| try testing.expect(err == error.NotALibrary or err == error.IsDir);

    try plugins.add(Named.init, null);
    try writePackage(tmp.dir, "Twin", "name = \"named\"\nversion = \"1.0.0\"\ndescription = \"d\"\nlibrary = \"Pkg" ++ ext ++ "\"\n", null);
    try testing.expectError(error.DuplicatePlugin, load(&plugins, io, tmp.dir, "Twin"));
    try testing.expectEqual(@as(usize, 1), plugins.loaded.items.len);
}

const Named = struct {
    fn init(_: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("NAMED");
        plugin.plugin_version = .of("1.0.0");
        return .ok;
    }
};

test "a library that resolves outside its package is refused" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "outside" ++ ext, .data = &library_format.fakeHeader(true) });
    try writePackage(tmp.dir, "Escape", valid, null);
    const target = try tmp.dir.realPathFileAlloc(io, "outside" ++ ext, testing.allocator);
    defer testing.allocator.free(target);
    tmp.dir.symLink(io, target, "Escape" ++ std.fs.path.sep_str ++ "Pkg" ++ ext, .{}) catch return error.SkipZigTest;
    try testing.expectError(error.LibraryOutsidePackage, load(&plugins, io, tmp.dir, "Escape"));
    try testing.expectEqual(@as(usize, 0), plugins.loaded.items.len);
}

test "discovery skips hidden and disabled packages and refuses loose libraries, symlinked packages and floods" {
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

    try writePackage(tmp.dir, ".git", null, null);
    try writePackage(tmp.dir, "Broken", null, null);
    try tmp.dir.writeFile(io, .{ .sub_path = "README.txt", .data = "packages go in directories" });
    try discover(&plugins, io, root, &.{"broken"});
    try testing.expectError(error.MissingManifest, discover(&plugins, io, root, &.{}));

    try tmp.dir.writeFile(io, .{ .sub_path = "Loose" ++ ext, .data = &library_format.fakeHeader(true) });
    try testing.expectError(error.LooseLibrary, discover(&plugins, io, root, &.{"Broken"}));
    try tmp.dir.deleteFile(io, "Loose" ++ ext);

    if (tmp.dir.symLink(io, "Broken", "Linked", .{ .is_directory = true })) |_| {
        try testing.expectError(error.SymlinkedPackage, discover(&plugins, io, root, &.{"Broken"}));
        tmp.dir.deleteDir(io, "Linked") catch try tmp.dir.deleteFile(io, "Linked");
    } else |_| {}

    for (0..max_packages) |i| {
        var name: [8]u8 = undefined;
        try writePackage(tmp.dir, try std.fmt.bufPrint(&name, "P{d}", .{i}), null, null);
    }
    try testing.expectError(error.TooManyPlugins, discover(&plugins, io, root, &.{"Broken"}));
    try testing.expectEqual(@as(usize, 0), plugins.loaded.items.len);
}
