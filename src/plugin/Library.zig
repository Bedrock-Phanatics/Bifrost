const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

// std.DynLib has no Windows backend in 0.17
pub const Library = if (builtin.os.tag == .windows) Windows else std.DynLib;

const Windows = struct {
    module: windows.HMODULE,

    pub fn open(path: []const u8) !Windows {
        var wide: [std.fs.max_path_bytes + 1]u16 = undefined;
        if (path.len > std.fs.max_path_bytes) return error.NameTooLong;
        const len = try std.unicode.wtf8ToWtf16Le(&wide, path);
        wide[len] = 0;
        return .{ .module = LoadLibraryW(wide[0..len :0]) orelse return error.FileNotFound };
    }

    pub fn lookup(self: *Windows, comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(GetProcAddress(self.module, name.ptr) orelse return null);
    }

    pub fn close(self: *Windows) void {
        _ = FreeLibrary(self.module);
    }

    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn GetProcAddress(module: windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?windows.FARPROC;
    extern "kernel32" fn FreeLibrary(module: windows.HMODULE) callconv(.winapi) c_int;
};
