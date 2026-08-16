//! One-screen TUI: search over the profile's logins, reveal one password at
//! a time, copy it, and wipe on quit.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const core = @import("core");
const profiles = core.profiles;
const store_mod = core.store;

const masked_password = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}";

/// Every error store.zig and its dependencies can produce, given a message a
/// person can act on. The store has no fixed error set (it is `!T`
/// throughout), so the fallback branch exists for real: a DER or PBES2
/// parse error a person cannot do anything about beyond reporting a bug.
fn friendlyMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.WrongPassword => "wrong Primary Password",
        error.LegacyTripleDes => "this entry is still 3DES, which this app cannot decrypt",
        error.OpenFailed => "could not open key4.db for this profile",
        error.MissingPasswordRow, error.NoSdrKey, error.QueryFailed => "this profile's key4.db is missing data this app expects",
        error.NoLoginsArray => "logins.json is not in the shape this app expects",
        error.OutOfMemory => "out of memory",
        error.FileNotFound => "logins.json or key4.db is missing",
        error.AccessDenied => "permission denied reading this profile",
        else => "could not read this profile (unexpected error)",
    };
}

/// A password prompt with its own tiny buffer, drawn as one bullet per
/// grapheme typed. Kept separate from vxfw.TextField so the plaintext
/// Primary Password only ever exists in a buffer this file wipes itself.
const SecretField = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    userdata: ?*anyopaque = null,
    onSubmit: ?*const fn (?*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,

    fn init(gpa: std.mem.Allocator) SecretField {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *SecretField) void {
        std.crypto.secureZero(u8, self.buf.items);
        self.buf.deinit(self.gpa);
    }

    fn clear(self: *SecretField) void {
        std.crypto.secureZero(u8, self.buf.items);
        self.buf.clearRetainingCapacity();
    }

    fn widget(self: *SecretField) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *SecretField = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn handleEvent(self: *SecretField, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.onSubmit) |cb| try cb(self.userdata, ctx, self.buf.items);
                    return ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.backspace, .{})) {
                    if (self.buf.items.len == 0) return ctx.consumeAndRedraw();
                    var iter = vaxis.unicode.graphemeIterator(self.buf.items);
                    var last_start: usize = 0;
                    while (iter.next()) |g| last_start = g.start;
                    self.buf.items.len = last_start;
                    return ctx.consumeAndRedraw();
                } else if (key.text) |text| {
                    try self.buf.appendSlice(self.gpa, text);
                    return ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *SecretField = @ptrCast(@alignCast(ptr));
        var n: usize = 0;
        var iter = vaxis.unicode.graphemeIterator(self.buf.items);
        while (iter.next()) |_| n += 1;

        const dots = try ctx.arena.alloc(u8, n * 3);
        var i: usize = 0;
        while (i < n) : (i += 1) @memcpy(dots[i * 3 ..][0..3], "\u{2022}");

        const text: vxfw.Text = .{ .text = dots, .softwrap = false };
        // Text.draw() stamps its own (local, about-to-be-dangling) widget
        // identity onto the surface. Restamp it as this SecretField's, or
        // focus tracking can never find this field in the surface tree.
        var surface = try text.draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
};

/// One line in the list: "kind marker  hostname  username  password". Text
/// lives here so ListView's builder can hand out a stable pointer without an
/// arena of its own; only `.text` is replaced, in place, when reveal state
/// changes.
const Row = struct {
    text: vxfw.Text = .{ .text = "", .softwrap = false },

    fn widget(self: *Row) vxfw.Widget {
        return self.text.widget();
    }
};

const Model = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    profile_path: []const u8,

    password_field: SecretField,
    password_error: bool = false,
    /// Set when opening the profile failed for a reason other than a wrong
    /// or missing Primary Password. Nothing is interactive at that point;
    /// the screen just states why and waits to be quit.
    open_error: bool = false,

    store: ?store_mod.Store = null,
    rows: []Row = &.{},
    row_lines: [][]u8 = &.{}, // owned per-row formatted line, freed on rebuild
    match_indices: std.ArrayList(usize) = .empty,

    search_field: vxfw.TextField,
    list_view: vxfw.ListView = .{ .children = .{ .slice = &.{} } },

    /// Plain letters must stay typeable in the search field, so `y`/`q` and
    /// the other single-key shortcuts only fire in `.normal` mode, when the
    /// list rather than the search field holds focus. `/` enters `.search`;
    /// `enter` or `escape` in the search field returns to `.normal`.
    mode: enum { normal, search } = .normal,

    revealed_index: ?usize = null,
    confirm_account_reveal: bool = false,
    reveal_scratch: [8192]u8 = undefined,
    reveal_out: [8192]u8 = undefined,

    status: [160]u8 = undefined,
    status_len: usize = 0,
    status_line: vxfw.Text = .{ .text = "", .softwrap = false },

    fn init(gpa: std.mem.Allocator, io: std.Io, profile_path: []const u8) !*Model {
        const model = try gpa.create(Model);
        errdefer gpa.destroy(model);
        model.* = .{
            .gpa = gpa,
            .io = io,
            .profile_path = profile_path,
            .password_field = SecretField.init(gpa),
            .search_field = .init(gpa),
        };
        model.password_field.userdata = model;
        model.password_field.onSubmit = Model.onPasswordSubmit;
        model.search_field.userdata = model;
        model.search_field.onChange = Model.onSearchChange;
        return model;
    }

    fn deinit(self: *Model) void {
        if (self.revealed_index != null) self.hideRevealed();
        std.crypto.secureZero(u8, &self.reveal_scratch);
        std.crypto.secureZero(u8, &self.reveal_out);
        self.password_field.deinit();
        self.search_field.deinit();
        self.match_indices.deinit(self.gpa);
        for (self.row_lines) |line| self.gpa.free(line);
        self.gpa.free(self.row_lines);
        self.gpa.free(self.rows);
        if (self.store) |*s| s.deinit();
        self.gpa.destroy(self);
    }

    fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn setStatus(self: *Model, comptime fmt: []const u8, args: anytype) void {
        self.status_len = if (std.fmt.bufPrint(&self.status, fmt, args)) |s| s.len else |_| 0;
        self.status_line.text = self.status[0..self.status_len];
    }

    /// Never propagates an error: every failure ends in either
    /// `password_error` (ask again) or `open_error` (nothing to do but
    /// quit), each paired with a message in `statusMessage`.
    fn tryOpen(self: *Model, password: []const u8) void {
        const s = store_mod.Store.open(self.gpa, self.io, self.profile_path, password) catch |err| {
            switch (err) {
                error.WrongPassword => self.password_error = true,
                else => {
                    self.open_error = true;
                    self.setStatus("{s}", .{friendlyMessage(err)});
                },
            }
            return;
        };
        self.store = s;
        self.buildRows() catch |err| {
            self.open_error = true;
            self.setStatus("{s}", .{friendlyMessage(err)});
            return;
        };
        self.setStatus(
            "{d} logins ({d} tombstones skipped) -- / search, enter reveal, y copy, q quit",
            .{ self.store.?.entries.len, self.store.?.tombstones_skipped },
        );
    }

    fn buildRows(self: *Model) !void {
        const s = &self.store.?;
        self.rows = try self.gpa.alloc(Row, s.entries.len);
        for (self.rows) |*r| r.* = .{};
        self.row_lines = try self.gpa.alloc([]u8, s.entries.len);
        for (self.row_lines) |*l| l.* = &.{};
        for (s.entries, 0..) |_, i| try self.refreshRow(i);

        self.list_view = .{
            .children = .{ .builder = .{ .userdata = self, .buildFn = Model.buildListItem } },
            .item_count = @intCast(s.entries.len),
        };
        try self.rebuildMatches("");
    }

    fn refreshRow(self: *Model, index: usize) !void {
        const s = &self.store.?;
        const e = s.entries[index];
        const marker: []const u8 = switch (e.kind) {
            .account_credential => "[account] ",
            .extension => "[extension] ",
            .normal => "",
        };
        const user_display = if (e.legacy_3des) "<3DES, unsupported>" else e.username;
        const password_display: []const u8 = if (self.revealed_index == index) blk: {
            const plain = s.reveal(index, &self.reveal_scratch, &self.reveal_out) catch |err| {
                break :blk switch (err) {
                    error.LegacyTripleDes => "<3DES, unsupported>",
                    else => "<could not decrypt>",
                };
            };
            break :blk plain;
        } else masked_password;

        self.gpa.free(self.row_lines[index]);
        self.row_lines[index] = try std.fmt.allocPrint(
            self.gpa,
            "{s}{s}  {s}  {s}",
            .{ marker, e.hostname, user_display, password_display },
        );
        self.rows[index].text.text = self.row_lines[index];
    }

    fn hideRevealed(self: *Model) void {
        const idx = self.revealed_index orelse return;
        self.revealed_index = null;
        self.confirm_account_reveal = false;
        std.crypto.secureZero(u8, &self.reveal_out);
        self.refreshRow(idx) catch {};
    }

    fn revealAt(self: *Model, index: usize) void {
        if (self.revealed_index) |prev| {
            if (prev != index) self.hideRevealed();
        }
        self.revealed_index = index;
        self.refreshRow(index) catch |err| {
            self.setStatus("reveal failed: {s}", .{friendlyMessage(err)});
        };
    }

    fn selectedEntryIndex(self: *Model) ?usize {
        if (self.match_indices.items.len == 0) return null;
        const cursor = @min(self.list_view.cursor, self.match_indices.items.len - 1);
        return self.match_indices.items[cursor];
    }

    fn rebuildMatches(self: *Model, query: []const u8) !void {
        const s = &self.store.?;
        try self.match_indices.resize(self.gpa, s.entries.len);
        const count = s.search(query, self.match_indices.items);
        self.match_indices.items.len = @min(count, s.entries.len);

        self.list_view.item_count = @intCast(self.match_indices.items.len);
        self.list_view.cursor = 0;
        self.list_view.scroll = .{};
    }

    fn buildListItem(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.match_indices.items.len) return null;
        const entry_index = self.match_indices.items[idx];
        return @constCast(&self.rows[entry_index]).widget();
    }

    fn onSearchChange(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        if (self.revealed_index != null) self.hideRevealed();
        try self.rebuildMatches(str);
        ctx.consumeAndRedraw();
    }

    fn onPasswordSubmit(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        self.password_error = false;
        self.tryOpen(str);
        self.password_field.clear();
        if (self.store != null) try ctx.requestFocus(self.list_view.widget());
        ctx.consumeAndRedraw();
    }

    fn copySelected(self: *Model, ctx: *vxfw.EventContext) !void {
        const idx = self.revealed_index orelse return;
        const s = &self.store.?;
        const plain = s.reveal(idx, &self.reveal_scratch, &self.reveal_out) catch |err| {
            self.setStatus("copy failed: {s}", .{friendlyMessage(err)});
            return;
        };
        try ctx.copyToClipboard(plain);
        try copyViaPbcopy(self.io, self.gpa, plain);
        self.setStatus("copied", .{});
    }

    fn focusForMode(self: *Model) vxfw.Widget {
        // In the open_error screen nothing but Model itself is drawn.
        // Requesting focus on password_field there would ask the focus
        // handler to find a widget that is not in the surface tree at all.
        if (self.open_error) return self.widget();
        if (self.store == null) return self.password_field.widget();
        return switch (self.mode) {
            .normal => self.list_view.widget(),
            .search => self.search_field.widget(),
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init, .focus_in => {
                // Focus routing (path_to_focused) only becomes correct after
                // the first draw. Without forcing one here, a key typed
                // before an incidental redraw (e.g. a resize) would be
                // routed using a stale, possibly-empty path.
                ctx.redraw = true;
                return ctx.requestFocus(self.focusForMode());
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
                if (self.store == null) {
                    if (self.open_error and key.matches('q', .{})) ctx.quit = true;
                    return; // otherwise routed to password_field by focus
                }

                if (self.mode == .search) {
                    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.escape, .{})) {
                        self.mode = .normal;
                        try ctx.requestFocus(self.list_view.widget());
                        return ctx.consumeAndRedraw();
                    }
                    return; // let the search field handle everything else
                }

                // .normal mode: the list holds focus, so plain letters are
                // free to use as shortcuts.
                if (key.matches('/', .{})) {
                    self.mode = .search;
                    try ctx.requestFocus(self.search_field.widget());
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('q', .{})) {
                    ctx.quit = true;
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.selectedEntryIndex()) |idx| {
                        const kind = self.store.?.entries[idx].kind;
                        if (kind == .account_credential and !self.confirm_account_reveal and self.revealed_index != idx) {
                            self.confirm_account_reveal = true;
                            self.setStatus("this reveals Firefox Sync account credentials -- press enter again to confirm", .{});
                            return ctx.consumeAndRedraw();
                        }
                        self.confirm_account_reveal = false;
                        if (self.revealed_index == idx) {
                            self.hideRevealed();
                        } else {
                            self.revealAt(idx);
                        }
                        return ctx.consumeAndRedraw();
                    }
                    return;
                }
                if (key.matches('y', .{})) {
                    try self.copySelected(ctx);
                    return ctx.consumeAndRedraw();
                }
                return self.list_view.handleEvent(ctx, event);
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        if (self.open_error) {
            return self.drawOpenError(ctx, max);
        }
        if (self.store == null) {
            return self.drawPasswordPrompt(ctx, max);
        }

        const list_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.list_view.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width, .height = max.height -| 3 },
            )),
        };
        const search_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 2 },
            .surface = try self.search_field.draw(ctx.withConstraints(ctx.min, .{ .width = max.width -| 2, .height = 1 })),
        };
        const prompt: vxfw.Text = .{ .text = "/", .softwrap = false };
        const prompt_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try prompt.draw(ctx.withConstraints(ctx.min, .{ .width = 2, .height = 1 })),
        };
        const status_surface: vxfw.SubSurface = .{
            .origin = .{ .row = max.height -| 1, .col = 0 },
            .surface = try self.status_line.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 1 })),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 4);
        children[0] = list_surface;
        children[1] = search_surface;
        children[2] = prompt_surface;
        children[3] = status_surface;

        return .{ .size = max, .widget = self.widget(), .buffer = &.{}, .children = children };
    }

    fn drawOpenError(self: *Model, ctx: vxfw.DrawContext, max: vxfw.Size) !vxfw.Surface {
        const label: vxfw.Text = .{ .text = self.status_line.text, .softwrap = true };
        const label_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try label.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 3 })),
        };
        const hint: vxfw.Text = .{ .text = "press q to quit", .softwrap = false };
        const hint_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 4, .col = 0 },
            .surface = try hint.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 1 })),
        };
        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = label_surface;
        children[1] = hint_surface;
        return .{ .size = max, .widget = self.widget(), .buffer = &.{}, .children = children };
    }

    fn drawPasswordPrompt(self: *Model, ctx: vxfw.DrawContext, max: vxfw.Size) !vxfw.Surface {
        const label: vxfw.Text = .{
            .text = if (self.password_error)
                "Wrong Primary Password. Try again:"
            else
                "This profile needs its Primary Password:",
            .softwrap = false,
        };
        const label_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try label.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 1 })),
        };
        const field_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.password_field.widget().draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 1 })),
        };
        const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
        children[0] = label_surface;
        children[1] = field_surface;
        return .{ .size = max, .widget = self.widget(), .buffer = &.{}, .children = children };
    }
};

/// Best-effort local clipboard write. libvaxis's OSC 52 write (via
/// ctx.copyToClipboard) never reports failure even when the terminal
/// ignores it, so this always also shells out to pbcopy, which works on
/// every macOS terminal regardless of OSC 52 support.
fn copyViaPbcopy(io: std.Io, gpa: std.mem.Allocator, text: []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = &.{"pbcopy"},
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    if (child.stdin) |stdin| {
        var buf: [4096]u8 = undefined;
        var writer = stdin.writer(io, &buf);
        writer.interface.writeAll(text) catch {};
        writer.interface.flush() catch {};
        stdin.close(io);
        // wait()'s cleanup closes child.stdin itself if non-null. Closing it
        // above and leaving this set would double-close the fd.
        child.stdin = null;
    }
    _ = child.wait(io) catch {};
    _ = gpa;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    const home = init.environ_map.get("HOME") orelse {
        var stderr_buf: [64]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        try stderr_writer.interface.writeAll("HOME is not set\n");
        try stderr_writer.interface.flush();
        return 1;
    };
    const firefox_dir = try std.fs.path.join(gpa, &.{ home, "Library/Application Support/Firefox" });
    defer gpa.free(firefox_dir);

    const cwd = std.Io.Dir.cwd();
    const ini_path = try std.fs.path.join(gpa, &.{ firefox_dir, "profiles.ini" });
    defer gpa.free(ini_path);
    const ini = try cwd.readFileAlloc(io, ini_path, gpa, .unlimited);
    defer gpa.free(ini);

    const profile = try profiles.resolveDefault(gpa, firefox_dir, ini);
    defer gpa.free(profile);

    const model = try Model.init(gpa, io, profile);
    defer model.deinit();

    model.tryOpen("");

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, gpa, init.environ_map, &buffer);
    defer app.deinit();

    try app.run(model.widget(), .{});
    return 0;
}
