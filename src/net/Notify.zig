const Notify = @This();

context: *anyopaque,
call: *const fn (*anyopaque) void,

pub fn send(self: Notify) void {
    self.call(self.context);
}
