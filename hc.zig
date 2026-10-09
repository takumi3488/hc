const std = @import("std");
const builtin = @import("builtin");

const help_text =
    "Usage: hc -- <command> [args]\n" ++
    "       hc --help\n" ++
    "Run a command directly, preserving its arguments and inherited streams.\n";

const Invocation = union(enum) {
    help,
    command: []const [:0]const u8,
    invalid,
};

const Herdr = struct {
    pane_id: []const u8,
    bin_path: []const u8,
};

const CommandResult = struct {
    status: u32,
    started: bool,
};
const HerdrWait = struct {
    child: *std.process.Child,
    pid: std.process.Child.Id,
    io: std.Io,
    done: std.Io.Event = .unset,
    term: ?std.process.Child.Term = null,
};

const has_posix_signals = switch (builtin.os.tag) {
    .linux, .macos, .maccatalyst, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos, .haiku => true,
    else => false,
};
const has_signal_numbers = has_posix_signals or builtin.os.tag == .windows;
// Zig's fork-based spawn waits for exec, so a child stopped before exec would deadlock it.
const start_child_suspended = has_posix_signals and builtin.os.tag.isDarwin();

const SignalScope = if (has_posix_signals) struct {
    previous_interrupt: std.posix.Sigaction,
    previous_terminate: std.posix.Sigaction,
    previous_hangup: std.posix.Sigaction,

    extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;
    extern "c" fn tcgetpgrp(fd: std.posix.fd_t) std.posix.pid_t;
    extern "c" fn tcsetpgrp(fd: std.posix.fd_t, pgid: std.posix.pid_t) c_int;

    fn init() SignalScope {
        pending_signal.store(0, .seq_cst);
        active_child_pid.store(0, .seq_cst);

        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var scope: SignalScope = undefined;
        std.posix.sigaction(.INT, &action, &scope.previous_interrupt);
        std.posix.sigaction(.TERM, &action, &scope.previous_terminate);
        std.posix.sigaction(.HUP, &action, &scope.previous_hangup);
        return scope;
    }

    fn deinit(scope: *SignalScope) void {
        active_child_pid.store(0, .seq_cst);
        std.posix.sigaction(.INT, &scope.previous_interrupt, null);
        std.posix.sigaction(.TERM, &scope.previous_terminate, null);
        std.posix.sigaction(.HUP, &scope.previous_hangup, null);
    }

    fn setChild(pid: std.posix.pid_t) void {
        active_child_pid.store(pid, .seq_cst);
        const signal = SignalScope.caughtSignal() orelse return;
        _ = std.posix.system.kill(-pid, signal);
    }

    fn resumeChild(pid: std.posix.pid_t) void {
        _ = std.posix.system.kill(-pid, .CONT);
    }

    fn clearChild() void {
        active_child_pid.store(0, .seq_cst);
    }

    fn giveTerminalToChild(pgid: std.posix.pid_t) ?std.posix.pid_t {
        const foreground = terminalForegroundGroup() orelse return null;
        const current_group = currentProcessGroup() orelse return null;
        if (foreground != current_group) return null;
        if (!setTerminalForeground(pgid)) return null;
        return foreground;
    }

    fn restoreTerminal(foreground: ?std.posix.pid_t) void {
        if (foreground) |pgid| _ = setTerminalForeground(pgid);
    }

    fn terminalForegroundGroup() ?std.posix.pid_t {
        if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
            const linux = std.os.linux;
            var pgid: std.posix.pid_t = undefined;
            const request = switch (builtin.cpu.arch) {
                .mips,
                .mipsel,
                .mips64,
                .mips64el,
                .powerpc,
                .powerpcle,
                .powerpc64,
                .powerpc64le,
                .sparc,
                .sparc64,
                => linux.IOCTL.IOR('t', 0x77, std.posix.pid_t),
                else => linux.IOCTL.IO('T', 0x0f),
            };
            const result = linux.syscall3(.ioctl, 0, @intCast(request), @intFromPtr(&pgid));
            return if (linux.errno(result) == .SUCCESS) pgid else null;
        }
        const pgid = tcgetpgrp(std.posix.STDIN_FILENO);
        return if (pgid > 0) pgid else null;
    }

    fn currentProcessGroup() ?std.posix.pid_t {
        if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
            const linux = std.os.linux;
            const result = linux.syscall1(.getpgid, 0);
            return if (linux.errno(result) == .SUCCESS) @intCast(result) else null;
        }
        const pgid = getpgid(0);
        return if (pgid > 0) pgid else null;
    }

    fn setTerminalForeground(pgid: std.posix.pid_t) bool {
        var blocked_signals = std.posix.sigemptyset();
        std.posix.sigaddset(&blocked_signals, .TTOU);
        var previous_mask = std.posix.sigemptyset();
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked_signals, &previous_mask);
        defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);
        if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
            const linux = std.os.linux;
            const request = switch (builtin.cpu.arch) {
                .mips,
                .mipsel,
                .mips64,
                .mips64el,
                .powerpc,
                .powerpcle,
                .powerpc64,
                .powerpc64le,
                .sparc,
                .sparc64,
                => linux.IOCTL.IOW('t', 0x76, std.posix.pid_t),
                else => linux.IOCTL.IO('T', 0x10),
            };
            return linux.errno(linux.syscall3(
                .ioctl,
                0,
                @intCast(request),
                @intFromPtr(&pgid),
            )) == .SUCCESS;
        }
        return tcsetpgrp(std.posix.STDIN_FILENO, pgid) == 0;
    }

    fn caughtSignal() ?std.posix.SIG {
        const signal_value = pending_signal.load(.seq_cst);
        if (signal_value == 0) return null;
        return @fromBackingInt(signal_value);
    }

    fn handleSignal(signal: std.posix.SIG) callconv(.c) void {
        pending_signal.store(@intCast(@backingInt(signal)), .seq_cst);
        const pid = active_child_pid.load(.seq_cst);
        if (pid > 0) {
            _ = std.posix.system.kill(-pid, signal);
        }
    }

    var active_child_pid: std.atomic.Value(std.posix.pid_t) = .init(0);
    var pending_signal: std.atomic.Value(u32) = .init(0);
} else struct {};

pub fn main(init: std.process.Init) void {
    const status = run(init);
    if (comptime builtin.os.tag == .windows) {
        std.os.windows.ntdll.RtlExitUserProcess(status);
    } else {
        std.process.exit(@intCast(status));
    }
}

fn run(init: std.process.Init) u32 {
    const all_args = init.minimal.args.toSlice(init.arena.allocator()) catch return 126;
    if (all_args.len == 0) {
        writeError(init.io, "hc: missing process arguments\n");
        return 2;
    }

    const invocation = parseInvocation(all_args[1..]);
    switch (invocation) {
        .help => {
            std.Io.File.stdout().writeStreamingAll(init.io, help_text) catch {};
            return 0;
        },
        .invalid => {
            writeError(init.io, help_text);
            return 2;
        },
        .command => {},
    }

    const herdr = configuredHerdr(init.environ_map);
    if (comptime has_posix_signals) {
        var signals = SignalScope.init();
        defer signals.deinit();
        return runCommandInvocation(init.io, init.gpa, invocation.command, herdr);
    }
    return runCommandInvocation(init.io, init.gpa, invocation.command, herdr);
}

fn runCommandInvocation(
    io: std.Io,
    gpa: std.mem.Allocator,
    argv: []const [:0]const u8,
    herdr: ?Herdr,
) u32 {
    if (herdr) |config| runHerdrState(io, config, "working");
    const result: CommandResult = if (caughtSignal()) |signal| .{
        .status = signalStatus(signal),
        .started = false,
    } else runChild(io, gpa, @ptrCast(argv));
    if (result.started) {
        if (herdr) |config| runHerdrState(io, config, "idle");
    }

    if (herdr) |config| runHerdrRelease(io, config);
    return result.status;
}

fn parseInvocation(args: []const [:0]const u8) Invocation {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return .help;
    if (args.len < 2) return .invalid;
    if (!std.mem.eql(u8, args[0], "--")) return .invalid;
    return .{ .command = args[1..] };
}
fn herdrEnabled(
    environment: ?[]const u8,
    pane_id: ?[]const u8,
    bin_path: ?[]const u8,
    socket_path: ?[]const u8,
) bool {
    const environment_value = environment orelse return false;
    if (!std.mem.eql(u8, environment_value, "1")) return false;
    const pane_value = pane_id orelse return false;
    const binary_value = bin_path orelse return false;
    const socket_value = socket_path orelse return false;
    if (pane_value.len == 0) return false;
    if (binary_value.len == 0) return false;
    if (socket_value.len == 0) return false;
    return true;
}

fn configuredHerdr(environ: *const std.process.Environ.Map) ?Herdr {
    const environment = environ.get("HERDR_ENV");
    const pane_id = environ.get("HERDR_PANE_ID");
    const bin_path = environ.get("HERDR_BIN_PATH");
    const socket_path = environ.get("HERDR_SOCKET_PATH");
    if (!herdrEnabled(environment, pane_id, bin_path, socket_path)) return null;
    return .{ .pane_id = pane_id.?, .bin_path = bin_path.? };
}

fn runHerdrState(io: std.Io, herdr: Herdr, state: []const u8) void {
    const argv = [_][]const u8{
        herdr.bin_path,
        "pane",
        "report-agent",
        herdr.pane_id,
        "--source",
        "hc",
        "--agent",
        "hc",
        "--state",
        state,
    };
    runHerdr(io, &argv);
}

fn runHerdrRelease(io: std.Io, herdr: Herdr) void {
    const argv = [_][]const u8{
        herdr.bin_path,
        "pane",
        "release-agent",
        herdr.pane_id,
        "--source",
        "hc",
        "--agent",
        "hc",
    };
    runHerdr(io, &argv);
}

fn runHerdr(io: std.Io, argv: []const []const u8) void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;

    var wait: HerdrWait = .{ .child = &child, .pid = child.id.?, .io = io };
    var group: std.Io.Group = .init;
    group.concurrent(io, waitHerdrChild, .{&wait}) catch {
        stopChild(&child, wait.pid, io);
        return;
    };

    const timeout: std.Io.Timeout = .{
        .duration = .{
            .raw = .{ .nanoseconds = 500_000_000 },
            .clock = .awake,
        },
    };
    wait.done.waitTimeout(io, timeout) catch {
        group.cancel(io);
        if (wait.term == null) stopChild(&child, wait.pid, io);
        return;
    };
    group.await(io) catch {
        group.cancel(io);
        if (wait.term == null) stopChild(&child, wait.pid, io);
        return;
    };
    if (wait.term == null) stopChild(&child, wait.pid, io);
}

fn waitHerdrChild(wait: *HerdrWait) std.Io.Cancelable!void {
    defer wait.done.set(wait.io);
    wait.term = wait.child.wait(wait.io) catch return;
}
fn stopChild(child: *std.process.Child, pid: std.process.Child.Id, io: std.Io) void {
    if (comptime has_posix_signals) {
        while (true) switch (std.posix.errno(std.posix.system.kill(pid, .KILL))) {
            .SUCCESS => break,
            .INTR => continue,
            .SRCH => break,
            else => return,
        };
        // The cancelled waiter has relinquished ownership; never kill this PID twice.
        child.id = null;
        if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
            const linux = std.os.linux;
            var information: linux.siginfo_t = undefined;
            while (true) switch (linux.errno(linux.waitid(
                .PID,
                pid,
                &information,
                linux.W.EXITED,
                null,
            ))) {
                .SUCCESS, .CHILD => return,
                .INTR => continue,
                else => return,
            };
        }
        var status: if (builtin.link_libc) c_int else i32 = undefined;
        while (true) switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
            .SUCCESS, .CHILD => return,
            .INTR => continue,
            else => return,
        };
    } else {
        child.kill(io);
    }
}

fn runChild(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) CommandResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = if (comptime has_posix_signals) 0 else null,
        .start_suspended = start_child_suspended,
    }) catch |err| {
        const status = spawnErrorStatus(err);
        writeSpawnError(io, gpa, argv[0], err, status);
        return .{ .status = status, .started = false };
    };
    defer child.kill(io);
    const child_pid = child.id.?;
    if (comptime has_posix_signals) SignalScope.setChild(child_pid);
    defer {
        if (comptime has_posix_signals) SignalScope.clearChild();
    }
    const previous_foreground = if (comptime has_posix_signals)
        SignalScope.giveTerminalToChild(child_pid)
    else
        null;
    defer if (comptime has_posix_signals) SignalScope.restoreTerminal(previous_foreground);
    if (comptime start_child_suspended) SignalScope.resumeChild(child_pid);
    const status = if (comptime builtin.os.tag == .windows)
        waitWindowsChild(&child, io)
    else blk: {
        while (true) {
            const term = waitChild(child_pid) orelse {
                if (comptime has_posix_signals) SignalScope.clearChild();
                stopChild(&child, child_pid, io);
                return .{ .status = 126, .started = true };
            };

            if (term == .stopped) {
                // A child that touched the terminal before receiving the foreground keeps running.
                if ((term.stopped == .TTIN or term.stopped == .TTOU) and
                    SignalScope.terminalForegroundGroup() == child_pid)
                {
                    SignalScope.resumeChild(child_pid);
                    continue;
                }
                SignalScope.restoreTerminal(previous_foreground);
                _ = std.posix.system.kill(std.posix.system.getpid(), .TSTP);
                _ = SignalScope.setTerminalForeground(child_pid);
                SignalScope.resumeChild(child_pid);
                continue;
            }

            if (comptime has_posix_signals) SignalScope.clearChild();
            child.id = null;
            break :blk switch (term) {
                .exited => |code| code,
                .signal => |signal| signalStatus(signal),
                .stopped => unreachable,
                .unknown => 1,
            };
        }
    };
    return .{ .status = status, .started = true };
}

/// Waits until the child exits or stops; null when waiting fails.
fn waitChild(pid: std.posix.pid_t) ?std.process.Child.Term {
    if (comptime builtin.os.tag == .linux and !builtin.link_libc) {
        // riscv32 and loongarch32 Linux have no wait4 syscall behind waitpid.
        const linux = std.os.linux;
        var information: linux.siginfo_t = undefined;
        const flags = linux.W.EXITED | linux.W.STOPPED;
        while (true) switch (linux.errno(linux.waitid(.PID, pid, &information, flags, null))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return null,
        };
        const status: u32 = @bitCast(information.fields.common.second.sigchld.status);
        const code: linux.CLD = @fromBackingInt(@intCast(information.code));
        return switch (code) {
            .EXITED => .{ .exited = @truncate(status) },
            .KILLED, .DUMPED => .{ .signal = @fromBackingInt(@intCast(status)) },
            .TRAPPED, .STOPPED => .{ .stopped = @fromBackingInt(@intCast(status)) },
            _, .CONTINUED => .{ .unknown = status },
        };
    }
    var status: if (builtin.link_libc) c_int else i32 = undefined;
    while (true) switch (std.posix.errno(std.posix.system.waitpid(pid, &status, std.posix.W.UNTRACED))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return null,
    };
    return std.Io.Threaded.statusToTerm(@bitCast(status));
}

fn waitWindowsChild(child: *std.process.Child, io: std.Io) u32 {
    const windows = std.os.windows;
    const wait_status = windows.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, null);
    var exit_status: u32 = 126;
    if (wait_status == windows.NTSTATUS.WAIT_0) {
        var information: windows.PROCESS.BASIC_INFORMATION = undefined;
        if (windows.ntdll.NtQueryInformationProcess(
            child.id.?,
            .BasicInformation,
            &information,
            @sizeOf(windows.PROCESS.BASIC_INFORMATION),
            null,
        ) == .SUCCESS) {
            exit_status = @bitCast(information.ExitStatus);
        }
    }
    // The stdlib wait releases handles, but its exit status truncates to eight bits.
    _ = child.wait(io) catch return exit_status;
    return exit_status;
}

fn spawnErrorStatus(err: std.process.SpawnError) u32 {
    return switch (err) {
        error.FileNotFound, error.NotDir => 127,
        else => 126,
    };
}

fn signalStatus(signal: std.posix.SIG) u32 {
    if (comptime has_signal_numbers) {
        return 128 + @as(u32, @intCast(@backingInt(signal)));
    }
    return 1;
}

fn caughtSignal() ?std.posix.SIG {
    if (comptime has_posix_signals) return SignalScope.caughtSignal();
    return null;
}

fn writeError(io: std.Io, message: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, message) catch {};
}

fn writeSpawnError(
    io: std.Io,
    gpa: std.mem.Allocator,
    command: []const u8,
    err: std.process.SpawnError,
    status: u32,
) void {
    const message = if (status == 127)
        gpa.print("hc: command not found: {s}\n", .{command}) catch return
    else
        gpa.print("hc: cannot execute {s}: {s}\n", .{ command, @errorName(err) }) catch return;
    defer gpa.free(message);
    writeError(io, message);
}

test "wrapper syntax preserves opaque command arguments" {
    const parsed = parseInvocation(&.{
        "--",
        "printf",
        "%s",
        "value with spaces",
        "$(not-interpolated)",
    });
    switch (parsed) {
        .command => |args| {
            try std.testing.expectEqual(@as(usize, 4), args.len);
            try std.testing.expectEqualStrings("printf", args[0]);
            try std.testing.expectEqualStrings("%s", args[1]);
            try std.testing.expectEqualStrings("value with spaces", args[2]);
            try std.testing.expectEqualStrings("$(not-interpolated)", args[3]);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(switch (parseInvocation(&.{ "--", "true" })) {
        .command => |args| args.len == 1 and std.mem.eql(u8, args[0], "true"),
        else => false,
    });
    try std.testing.expect(switch (parseInvocation(&.{"--help"})) {
        .help => true,
        else => false,
    });
    try std.testing.expect(switch (parseInvocation(&.{})) {
        .invalid => true,
        else => false,
    });
    try std.testing.expect(switch (parseInvocation(&.{"--"})) {
        .invalid => true,
        else => false,
    });
    try std.testing.expect(switch (parseInvocation(&.{"printf"})) {
        .invalid => true,
        else => false,
    });
    try std.testing.expect(switch (parseInvocation(&.{ "--help", "extra" })) {
        .invalid => true,
        else => false,
    });
}

test "Herdr requires every exact nonempty gate value" {
    try std.testing.expect(herdrEnabled("1", "pane", "/bin/herdr", "/tmp/herdr.sock"));
    try std.testing.expect(!herdrEnabled("true", "pane", "/bin/herdr", "/tmp/herdr.sock"));
    try std.testing.expect(!herdrEnabled("1 ", "pane", "/bin/herdr", "/tmp/herdr.sock"));
    try std.testing.expect(!herdrEnabled("1", null, "/bin/herdr", "/tmp/herdr.sock"));
    try std.testing.expect(!herdrEnabled("1", "", "/bin/herdr", "/tmp/herdr.sock"));
    try std.testing.expect(!herdrEnabled("1", "pane", null, "/tmp/herdr.sock"));
    try std.testing.expect(!herdrEnabled("1", "pane", "", "/tmp/herdr.sock"));
    try std.testing.expect(!herdrEnabled("1", "pane", "/bin/herdr", null));
    try std.testing.expect(!herdrEnabled("1", "pane", "/bin/herdr", ""));
}

test "command spawn errors and signal statuses map to shell statuses" {
    try std.testing.expectEqual(@as(u32, 127), spawnErrorStatus(error.FileNotFound));
    try std.testing.expectEqual(@as(u32, 127), spawnErrorStatus(error.NotDir));
    try std.testing.expectEqual(@as(u32, 126), spawnErrorStatus(error.PermissionDenied));
    try std.testing.expectEqual(@as(u32, 130), signalStatus(.INT));
}

test "a real child receives exact arguments and its exit status is preserved" {
    if (builtin.os.tag == .windows) {
        const argv = [_][]const u8{ "cmd.exe", "/d", "/c", "exit 256" };
        const result = runChild(std.testing.io, std.testing.allocator, &argv);
        try std.testing.expect(result.started);
        try std.testing.expectEqual(@as(u32, 256), result.status);
    } else {
        const parsed = parseInvocation(&.{
            "--",
            "/bin/sh",
            "-c",
            "test \"$1\" = 'value with spaces' && test \"$2\" = '$(false)' && exit 23",
            "hc-test",
            "value with spaces",
            "$(false)",
        });
        const command = switch (parsed) {
            .command => |args| args,
            else => return error.TestUnexpectedResult,
        };
        const argv: []const []const u8 = @ptrCast(command);
        const result = runChild(std.testing.io, std.testing.allocator, argv);
        try std.testing.expect(result.started);
        try std.testing.expectEqual(@as(u32, 23), result.status);
    }
}

test "handled forwarded termination preserves the real child's exit status" {
    if (comptime has_posix_signals) {
        const io = std.testing.io;
        const gpa = std.testing.allocator;
        const fifo_path = try gpa.printSentinel("/tmp/hc-signal-{d}", .{
            std.posix.system.getpid(),
        }, 0);
        defer gpa.free(fifo_path);
        defer {
            const unlink_error = std.posix.errno(std.posix.system.unlinkat(
                std.posix.AT.FDCWD,
                fifo_path,
                0,
            ));
            std.debug.assert(unlink_error == .SUCCESS or unlink_error == .NOENT);
        }

        const script =
            "fifo=$1; " ++
            "mkfifo \"$fifo\" || exit 91; " ++
            "trap 'rm -f \"$fifo\"; exit 23' TERM; " ++
            "kill -TERM \"$PPID\"; " ++
            "read input < \"$fifo\"; " ++
            "exit 92";
        const argv: []const [:0]const u8 = &.{
            "/bin/sh",
            "-c",
            script,
            "hc-test",
            fifo_path,
        };
        const Context = struct {
            io: std.Io,
            gpa: std.mem.Allocator,
            argv: []const [:0]const u8,
            done: std.Io.Event = .unset,
            status: ?u32 = null,

            fn invoke(context: *@This()) std.Io.Cancelable!void {
                var signals = SignalScope.init();
                defer signals.deinit();
                context.status = runCommandInvocation(
                    context.io,
                    context.gpa,
                    context.argv,
                    null,
                );
                context.done.set(context.io);
            }
        };
        var context: Context = .{
            .io = io,
            .gpa = gpa,
            .argv = argv,
        };
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        group.async(io, Context.invoke, .{&context});

        const deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{
            .raw = .fromSeconds(5),
            .clock = .awake,
        });
        var timed_out = false;
        while (!context.done.isSet()) {
            context.done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => {
                    if (deadline.durationFromNow(io).raw.nanoseconds <= 0) {
                        timed_out = true;
                    }
                },
                error.Canceled => return err,
            };
            if (timed_out) break;
        }
        if (timed_out) {
            const child_pid = SignalScope.active_child_pid.load(.seq_cst);
            if (child_pid > 0) {
                const kill_error = std.posix.errno(std.posix.system.kill(child_pid, .KILL));
                try std.testing.expect(kill_error == .SUCCESS or kill_error == .SRCH);
            }
            group.cancel(io);
        } else {
            try group.await(io);
        }
        try std.testing.expect(!timed_out);
        const status = context.status orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, 23), status);
    }
}

test "Herdr helper processes are bounded and reaped" {
    if (builtin.os.tag == .windows) return;
    const argv = [_][]const u8{ "/bin/sleep", "4" };
    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    runHerdr(std.testing.io, &argv);
    const finished = std.Io.Timestamp.now(std.testing.io, .awake);
    const elapsed_nanoseconds = started.durationTo(finished).nanoseconds;
    try std.testing.expect(elapsed_nanoseconds < 2_000_000_000);
}
