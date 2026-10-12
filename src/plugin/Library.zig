const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

// std.DynLib has no Windows backend in 0.17
pub const Library = if (builtin.os.tag == .windows) Windows else std.DynLib;

pub const extension = switch (builtin.os.tag) {
    .windows => ".dll",
    .macos => ".dylib",
    else => ".so",
};

pub const FormatError = error{ NotALibrary, WrongArchitecture };

pub const header_len = 512;

pub fn checkFormat(header: []const u8) FormatError!void {
    switch (builtin.os.tag) {
        .windows => {
            if (header.len < 0x40 or !std.mem.eql(u8, header[0..2], "MZ")) return error.NotALibrary;
            const pe = std.mem.readInt(u32, header[0x3c..0x40], .little);
            if (pe > header.len - 24 or !std.mem.eql(u8, header[pe..][0..4], "PE\x00\x00")) return error.NotALibrary;
            const characteristics = std.mem.readInt(u16, header[pe + 22 ..][0..2], .little);
            if (characteristics & 0x2000 == 0) return error.NotALibrary;
            const machine = std.mem.readInt(u16, header[pe + 4 ..][0..2], .little);
            if (machine != @backingInt(builtin.target.toCoffMachine())) return error.WrongArchitecture;
        },
        .macos => {
            if (header.len < 16) return error.NotALibrary;
            const magic = std.mem.readInt(u32, header[0..4], .little);
            if (std.mem.readInt(u32, header[0..4], .big) == 0xcafebabe) return;
            if (magic != 0xfeedfacf) return error.NotALibrary;
            const filetype = std.mem.readInt(u32, header[12..16], .little);
            if (filetype != 6 and filetype != 8) return error.NotALibrary;
            const cpu: u32 = switch (builtin.cpu.arch) {
                .x86_64 => 0x01000007,
                .aarch64 => 0x0100000c,
                else => return,
            };
            if (std.mem.readInt(u32, header[4..8], .little) != cpu) return error.WrongArchitecture;
        },
        else => {
            if (header.len < 20 or !std.mem.eql(u8, header[0..4], std.elf.MAGIC)) return error.NotALibrary;
            const endian: std.builtin.Endian = switch (header[5]) {
                1 => .little,
                2 => .big,
                else => return error.NotALibrary,
            };
            if (std.mem.readInt(u16, header[16..18], endian) != @backingInt(std.elf.ET.DYN)) return error.NotALibrary;
            const class: u8 = if (@sizeOf(usize) == 8) 2 else 1;
            const machine = std.mem.readInt(u16, header[18..20], endian);
            if (header[4] != class or endian != builtin.cpu.arch.endian() or machine != @backingInt(builtin.target.toElfMachine()))
                return error.WrongArchitecture;
        },
    }
}

const Windows = struct {
    module: windows.HMODULE,

    // Dependencies come from the DLL's directory, the exe's and System32, never cwd or PATH; needs an absolute path
    const search_dll_load_dir = 0x100;
    const search_default_dirs = 0x1000;

    pub fn open(path: []const u8) !Windows {
        var wide: [std.fs.max_path_bytes + 1]u16 = undefined;
        if (path.len > std.fs.max_path_bytes) return error.NameTooLong;
        const len = try std.unicode.wtf8ToWtf16Le(&wide, path);
        wide[len] = 0;
        const module = LoadLibraryExW(wide[0..len :0], null, search_dll_load_dir | search_default_dirs) orelse return switch (windows.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND, .MOD_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .BAD_EXE_FORMAT, .EXE_MACHINE_TYPE_MISMATCH => error.WrongArchitecture,
            else => error.InvalidLibrary,
        };
        return .{ .module = module };
    }

    pub fn lookup(self: *Windows, comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(GetProcAddress(self.module, name.ptr) orelse return null);
    }

    pub fn close(self: *Windows) void {
        _ = FreeLibrary(self.module);
    }

    extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?windows.HANDLE, flags: u32) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn GetProcAddress(module: windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?windows.FARPROC;
    extern "kernel32" fn FreeLibrary(module: windows.HMODULE) callconv(.winapi) c_int;
};

/// With `native` false the header is for another CPU.
pub fn fakeHeader(native: bool) [header_len]u8 {
    var header: [header_len]u8 = @splat(0);
    switch (builtin.os.tag) {
        .windows => {
            header[0..2].* = "MZ".*;
            std.mem.writeInt(u32, header[0x3c..0x40], 0x80, .little);
            header[0x80..0x84].* = "PE\x00\x00".*;
            const machine: u16 = if (native) @backingInt(builtin.target.toCoffMachine()) else 0x1c0;
            std.mem.writeInt(u16, header[0x84..0x86], machine, .little);
            std.mem.writeInt(u16, header[0x96..0x98], 0x2000, .little);
        },
        .macos => {
            std.mem.writeInt(u32, header[0..4], 0xfeedfacf, .little);
            const x86_64: u32 = 0x01000007;
            const arm64: u32 = 0x0100000c;
            const cpu = if (builtin.cpu.arch == .x86_64) x86_64 else arm64;
            std.mem.writeInt(u32, header[4..8], if (native) cpu else x86_64 ^ arm64 ^ cpu, .little);
            std.mem.writeInt(u32, header[12..16], 6, .little);
        },
        else => {
            const endian = builtin.cpu.arch.endian();
            header[0..4].* = std.elf.MAGIC.*;
            header[4] = if (@sizeOf(usize) == 8) 2 else 1;
            header[5] = if (endian == .little) 1 else 2;
            std.mem.writeInt(u16, header[16..18], @backingInt(std.elf.ET.DYN), endian);
            const machine = if (native) builtin.target.toElfMachine() else if (builtin.cpu.arch == .sparc64) std.elf.EM.X86_64 else std.elf.EM.SPARCV9;
            std.mem.writeInt(u16, header[18..20], @backingInt(machine), endian);
        },
    }
    return header;
}

test "checkFormat accepts only shared libraries for this target" {
    try std.testing.expectError(error.NotALibrary, checkFormat(""));
    try std.testing.expectError(error.NotALibrary, checkFormat("not a library, just text that happens to be long enough to read"));
    var header = fakeHeader(true);
    try checkFormat(&header);
    try std.testing.expectError(error.WrongArchitecture, checkFormat(&fakeHeader(false)));
    try std.testing.expectError(error.NotALibrary, checkFormat(header[0..8]));
    switch (builtin.os.tag) {
        .windows => {
            std.mem.writeInt(u16, header[0x96..0x98], 0, .little);
            try std.testing.expectError(error.NotALibrary, checkFormat(&header));
            std.mem.writeInt(u32, header[0x3c..0x40], 0xfffffff0, .little);
            try std.testing.expectError(error.NotALibrary, checkFormat(&header));
        },
        .macos => {},
        else => {
            std.mem.writeInt(u16, header[16..18], @backingInt(std.elf.ET.EXEC), builtin.cpu.arch.endian());
            try std.testing.expectError(error.NotALibrary, checkFormat(&header));
        },
    }
}
