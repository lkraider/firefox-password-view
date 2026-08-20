//! One-screen TUI. It searches the profile's logins, reveals one password at
//! a time, copies the row under the cursor, and wipes on quit.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const core = @import("core");
const profiles = core.profiles;
const store_mod = core.store;
const friendlyMessage = core.messages.friendly;

const cli = @import("args.zig");
const build_options = @import("build_options");

const masked_password = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}";

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
/// arena of its own. Only `.text` is replaced, in place, when reveal state
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
    /// `main` reads WAYLAND_DISPLAY and DISPLAY and picks the chain.
    /// copySelected receives a vxfw.EventContext, and that struct carries no
    /// environment.
    helpers: []const []const []const u8,

    password_field: SecretField,
    password_error: bool = false,
    /// Set when the profile failed to open with a message the user cannot
    /// act on. The screen then shows that message and accepts `q`. A wrong
    /// Primary Password sets `password_error` and keeps the prompt.
    open_error: bool = false,

    store: ?store_mod.Store = null,
    rows: []Row = &.{},
    row_lines: [][]u8 = &.{}, // owned per-row formatted line, freed on rebuild
    match_indices: std.ArrayList(usize) = .empty,

    search_field: vxfw.TextField,
    list_view: vxfw.ListView = .{ .children = .{ .slice = &.{} } },

    /// Plain letters must stay typeable in the search field, so `y`/`q` and
    /// the other single-key shortcuts only fire in `.normal` mode, when the
    /// list holds focus and the search field does not. `/` enters `.search`.
    /// `enter` or `escape` in the search field returns to `.normal`.
    mode: enum { normal, search } = .normal,

    revealed_index: ?usize = null,
    /// The `chrome://FirefoxAccounts` password is Mozilla Account sync key
    /// material. Revealing it and copying it each ask for a second press,
    /// and each records which action was asked about, so pressing `y` and
    /// then `enter` asks twice.
    pending_account_action: ?enum { reveal, copy } = null,
    reveal_scratch: [8192]u8 = undefined,
    reveal_out: [8192]u8 = undefined,

    /// Filled by `y` when stdout is a pipe or a file. `main` writes it once,
    /// after app.run returns. Bytes already in the pipe cannot be retracted.
    /// A write per press would send every password of the run, with nothing
    /// between them.
    stdout_out: [8192]u8 = undefined,
    stdout_len: usize = 0,

    status: [160]u8 = undefined,
    status_len: usize = 0,
    status_line: vxfw.Text = .{ .text = "", .softwrap = false },

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        profile_path: []const u8,
        helpers: []const []const []const u8,
    ) !*Model {
        const model = try gpa.create(Model);
        errdefer gpa.destroy(model);
        model.* = .{
            .gpa = gpa,
            .io = io,
            .profile_path = profile_path,
            .helpers = helpers,
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
        std.crypto.secureZero(u8, &self.stdout_out);
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

    /// Returns no error. A wrong Primary Password sets `password_error`,
    /// and the prompt asks again. Every other failure sets `open_error` and
    /// a message through `setStatus`.
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
        self.pending_account_action = null;
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

    /// Copies the row under the cursor. The row stays masked. `reveal_out`
    /// holds the plaintext for the two clipboard writes. A revealed row owns
    /// that buffer and wipes it in `hideRevealed`. Every other case wipes it
    /// here.
    fn copySelected(self: *Model, ctx: *vxfw.EventContext) !void {
        const idx = self.selectedEntryIndex() orelse return;
        const s = &self.store.?;
        if (s.entries[idx].kind == .account_credential and self.pending_account_action != .copy) {
            self.pending_account_action = .copy;
            self.setStatus("this copies Firefox Sync account credentials to the clipboard -- press y again to confirm", .{});
            return;
        }
        self.pending_account_action = null;
        const plain = s.reveal(idx, &self.reveal_scratch, &self.reveal_out) catch |err| {
            self.setStatus("copy failed: {s}", .{friendlyMessage(err)});
            return;
        };
        try ctx.copyToClipboard(plain);
        copyViaHelper(self.io, self.helpers, plain);

        // A terminal on stdout puts the password into scrollback, into a tmux
        // buffer and into `script` output.
        if (!(std.Io.File.stdout().isTty(self.io) catch true)) {
            const n = @min(plain.len, self.stdout_out.len);
            @memcpy(self.stdout_out[0..n], plain[0..n]);
            self.stdout_len = n;
        }

        if (self.revealed_index == null) std.crypto.secureZero(u8, &self.reveal_out);
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
                // Focus routing (path_to_focused) becomes correct after the
                // first draw, so this asks for that draw now. A key typed
                // before the next incidental redraw (a resize, say) would
                // otherwise route through a stale, possibly-empty path.
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
                        if (kind == .account_credential and self.pending_account_action != .reveal and self.revealed_index != idx) {
                            self.pending_account_action = .reveal;
                            self.setStatus("this reveals Firefox Sync account credentials -- press enter again to confirm", .{});
                            return ctx.consumeAndRedraw();
                        }
                        self.pending_account_action = null;
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

        return self.composite(ctx, max, &.{ list_surface, search_surface, prompt_surface, status_surface });
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
        return self.composite(ctx, max, &.{ label_surface, hint_surface });
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
        return self.composite(ctx, max, &.{ label_surface, field_surface });
    }

    /// Every screen is one Surface over already-drawn children. The draw
    /// paths differ only in the children they pass here.
    fn composite(self: *Model, ctx: vxfw.DrawContext, size: vxfw.Size, children: []const vxfw.SubSurface) !vxfw.Surface {
        return .{
            .size = size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = try ctx.arena.dupe(vxfw.SubSurface, children),
        };
    }
};

/// wl-copy connects to a Wayland compositor. xclip and xsel need $DISPLAY.
/// Both reach a Wayland clipboard through XWayland.
const wayland_helpers: []const []const []const u8 = &.{
    &.{"wl-copy"},
    &.{ "xclip", "-selection", "clipboard" },
    &.{ "xsel", "--clipboard", "--input" },
};
const x11_helpers: []const []const []const u8 = wayland_helpers[1..];
const macos_helpers: []const []const []const u8 = &.{&.{"pbcopy"}};

/// Best-effort local clipboard write. libvaxis's OSC 52 write (via
/// ctx.copyToClipboard) never reports failure even when the terminal
/// ignores it, so this always also shells out.
fn copyViaHelper(io: std.Io, helpers: []const []const []const u8, text: []const u8) void {
    for (helpers) |argv| {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        if (child.stdin) |stdin| {
            var buf: [4096]u8 = undefined;
            var writer = stdin.writer(io, &buf);
            writer.interface.writeAll(text) catch {};
            writer.interface.flush() catch {};
            stdin.close(io);
            // wait()'s cleanup closes child.stdin itself if non-null. Closing
            // it above and leaving this set would double-close the fd.
            child.stdin = null;
        }
        const term = child.wait(io) catch continue;
        if (term == .exited and term.exited == 0) return;
    }
}

fn readProfilesIni(io: std.Io, gpa: std.mem.Allocator, firefox_dir: []const u8) ![]u8 {
    const ini_path = try std.fs.path.join(gpa, &.{ firefox_dir, "profiles.ini" });
    defer gpa.free(ini_path);
    return std.Io.Dir.cwd().readFileAlloc(io, ini_path, gpa, .unlimited);
}

fn resolveDefaultProfile(io: std.Io, gpa: std.mem.Allocator, firefox_dir: []const u8) ![]u8 {
    const ini = try readProfilesIni(io, gpa, firefox_dir);
    defer gpa.free(ini);
    return profiles.resolveDefault(gpa, firefox_dir, ini);
}

/// One profile per line, name then path, so a shell can cut either field.
/// The root goes to stderr. `cut -f1` over stdout keeps working.
fn listProfiles(io: std.Io, gpa: std.mem.Allocator, firefox_dir: []const u8) !void {
    var root_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&root_buf, "{s}\n", .{firefox_dir})) |line| {
        write(io, .stderr(), line) catch {};
    } else |_| {}

    const ini = try readProfilesIni(io, gpa, firefox_dir);
    defer gpa.free(ini);
    const list = try profiles.enumerate(gpa, firefox_dir, ini);
    defer {
        for (list) |p| {
            gpa.free(p.name);
            gpa.free(p.path);
        }
        gpa.free(list);
    }

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    for (list) |p| try writer.interface.print("{s}\t{s}\n", .{ p.name, p.path });
    try writer.interface.flush();
}

/// The first root under $HOME holding a profiles.ini. Null means this
/// function already wrote the reason to stderr. `main` then returns 1.
///
/// Call this only where a profiles.ini has to be read. Calling it before
/// `--profile` is read makes a populated root a precondition for every run.
fn resolveFirefoxDir(io: std.Io, gpa: std.mem.Allocator, home: ?[]const u8) !?[]u8 {
    const dir = home orelse {
        try write(io, .stderr(), "HOME is not set\n");
        return null;
    };
    return profiles.resolveDir(io, gpa, dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.NoFirefoxDir => {
            try reportNoFirefoxDir(io, gpa, dir);
            return null;
        },
    };
}

fn reportNoFirefoxDir(io: std.Io, gpa: std.mem.Allocator, home: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    try writer.interface.writeAll("keywise: found no profiles.ini under\n");
    for (profiles.home_relative_dirs) |rel| {
        const dir = try std.fs.path.join(gpa, &.{ home, rel });
        defer gpa.free(dir);
        try writer.interface.print("  {s}\n", .{dir});
    }
    try writer.interface.flush();
}

fn write(io: std.Io, file: std.Io.File, text: []const u8) !void {
    var buf: [512]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

/// Collects the arguments after the program name. Each slice points into
/// the iterator's own storage. That storage lives as long as the process.
fn collectArgs(gpa: std.mem.Allocator, argv: std.process.Args) ![]const []const u8 {
    var it: std.process.Args.Iterator = .init(argv);
    _ = it.skip();
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    while (it.next()) |arg| try list.append(gpa, arg);
    return list.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    const argv = try collectArgs(gpa, init.minimal.args);
    defer gpa.free(argv);
    const options = cli.parse(argv) catch |err| {
        const message = switch (err) {
            error.MissingValue => "keywise: --profile needs a path\n",
            error.UnknownFlag => "keywise: unrecognized argument, see keywise --help\n",
        };
        try write(io, .stderr(), message);
        return 2;
    };
    if (options.help) {
        try write(io, .stdout(), cli.usage);
        return 0;
    }
    if (options.version) {
        try write(io, .stdout(), "keywise " ++ build_options.version ++ "\n");
        return 0;
    }

    const home = init.environ_map.get("HOME");

    if (options.list_profiles) {
        const firefox_dir = try resolveFirefoxDir(io, gpa, home) orelse return 1;
        defer gpa.free(firefox_dir);
        try listProfiles(io, gpa, firefox_dir);
        return 0;
    }

    // Duped so one `free` covers both this and resolveDefault's allocation.
    const profile = if (options.profile_path) |path|
        try gpa.dupe(u8, path)
    else default: {
        const firefox_dir = try resolveFirefoxDir(io, gpa, home) orelse return 1;
        defer gpa.free(firefox_dir);
        break :default try resolveDefaultProfile(io, gpa, firefox_dir);
    };
    defer gpa.free(profile);

    const helpers: []const []const []const u8 = if (builtin.os.tag == .macos)
        macos_helpers
    else if (init.environ_map.get("WAYLAND_DISPLAY") != null)
        wayland_helpers
    else if (init.environ_map.get("DISPLAY") != null)
        x11_helpers
    else
        &.{};

    const model = try Model.init(gpa, io, profile, helpers);
    defer model.deinit();

    model.tryOpen("");

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, gpa, init.environ_map, &buffer);
    defer app.deinit();

    try app.run(model.widget(), .{});

    // std.Io.Threaded installs a SIGPIPE handler (Threaded.zig:1661), so a
    // reader that exited first gives error.BrokenPipe here. A `try`
    // would make `keywise | head -c 5` exit non-zero with a trace.
    if (model.stdout_len > 0) {
        write(io, .stdout(), model.stdout_out[0..model.stdout_len]) catch {};
    }
    return 0;
}
