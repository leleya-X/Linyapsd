//! Linyapsd —— 玲珑应用在宿主机侧的小助手。
//!
//! 玲珑容器把 / 挂成只读 overlay，容器内的应用因此读不到宿主的
//! /var/lib/linglong/states.json，也跑不动 ll-cli（缺宿主那套共享库）。
//! 但容器与宿主共享 $HOME 和 session bus，所以应用可以放一份 D-Bus 服务文件，
//! 由宿主的 bus 按需把本程序拉起来，替它做这两件事。
//!
//! D-Bus 用的是 libdbus（见 src/dbus.zig）—— 会话总线的服务激活路径
//! 有一堆规范没写死、实现却必须照做的细节，自己重造划不来。

const std = @import("std");
const dbus = @import("dbus.zig");

const posix = std.posix;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("time.h");
});

/// 单调时钟的毫秒数，用来量"等了多久"。
/// 不用墙上时钟：它会被系统对时往回拨，把等待算成负数。
fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    // CLOCK_MONOTONIC 是内核保证不会失败的时钟
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), std.time.ns_per_ms);
}

const bus_name = "io.github.leleya_x.Linyapsd";
const interface = "io.github.leleya_x.Linyapsd.Manager";
/// 版本号来自 build.zig.zon（由 build.zig 注入），源码里不另写一份。
/// 部署方要拿这个号跟落点上那份比，决定要不要覆盖（见 host_bridge.dart）
const version = @import("build_options").version;

/// 同一份版本号，补上 NUL 结尾 —— libdbus 按 C 字符串取长。
/// 注入进来的是普通切片，这里用 ++ "" 把它补成带哨兵的字面量
const version_z: [:0]const u8 = version ++ "";

const states_path = "/var/lib/linglong/states.json";
const ll_cli = "/usr/bin/ll-cli";

/// 允许经 D-Bus 触发的 ll-cli 子命令。全是只读查询，
/// 挡的是 uninstall/install 这类会改系统状态的。
const ll_allowed = [_][]const u8{ "list", "info", "search", "ps" };

const max_states = 8 * 1024 * 1024;
const max_output = 8 * 1024 * 1024;

// 缓冲放 .bss，不占二进制体积。末尾那一字节留给 NUL，
// 因为 libdbus 追加字符串时靠 strlen 定长。
var states_buf: [max_states]u8 = undefined;
var out_buf: [max_output]u8 = undefined;
var err_buf: [64 * 1024]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    // 部署方要拿这个版本号跟落点上那份比，决定要不要覆盖（见 host_bridge.dart）
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // argv[0] 是路径，不用看
    if (args.next()) |first| {
        if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) {
            _ = c.write(1, version.ptr, version.len);
            _ = c.write(1, "\n", 1);
            return 0;
        }
        // 认不出的参数直接说，不当作没看见然后照常提供服务
        std.debug.print("linyapsd: 无法识别的参数 {s}\n用法: linyapsd [--version]\n", .{first});
        return 2;
    }

    const conn = dbus.connectSessionBus() catch |e| {
        std.debug.print("linyapsd: 连接 session bus 失败: {s} ({s})\n", .{ @errorName(e), dbus.lastError() });
        return 1;
    };

    const result = dbus.requestName(conn, bus_name) catch |e| {
        std.debug.print("linyapsd: 注册服务名失败: {s} ({s})\n", .{ @errorName(e), dbus.lastError() });
        return 1;
    };
    if (result != 1) {
        std.debug.print("linyapsd: 服务名已被占用 (RequestName 返回 {d})\n", .{result});
        return 1;
    }

    // 先订上 NameOwnerChanged。没有它就只能知道有人调用过我们，
    // 不知道人家什么时候走的 —— 那这个进程只能一直留在总线上。
    dbus.watchNameOwnerChanged(conn) catch |e| {
        std.debug.print("linyapsd: 订阅 NameOwnerChanged 失败: {s} ({s})\n", .{ @errorName(e), dbus.lastError() });
        return 1;
    };

    var callers: CallerSet = .{};
    const started_ms = monotonicMs();

    while (true) {
        // 还没人用过我们的时候才定期醒来看一眼 —— 那是在等第一个调用方，
        // 等到了就一直阻塞下去，不必再空转。
        const timeout: c_int = if (callers.len == 0) poll_ms else -1;

        switch (dbus.nextEvent(conn, timeout)) {
            .closed => break,

            .idle => {
                // 起来之后一直没人调用。正常被激活时不会这样：bus 是把调用方
                // 那个挂起的调用转给我们才拉起我们的，也就是说一醒来就该有人来。
                // 只有"被 StartServiceByName 单独叫起来、调用方随后却没来"才会走到这里，
                // 那种情况下没人会记得我们，也就没人会来划掉我们。
                //
                // 掐的是时钟而不是累加 poll_ms：总线上别的连接进进出出都会推广播过来，
                // 每一轮都被打断一次的话，累加出来的"等待"会远小于真实经过的时间
                if (monotonicMs() - started_ms >= idle_grace_ms) {
                    std.debug.print("linyapsd: 起来 {d} 秒无人调用，本实例收工\n", .{idle_grace_ms / 1000});
                    break;
                }
            },

            .event => |ev| switch (ev) {
                .call => |call| {
                    callers.add(call.sender) catch {
                        // 记不下就无从知道它什么时候走，"没人用了就退出"这条就失效了。
                        // 与其留一个嘴上会说退、实际不会退的常驻进程，不如现在就说清楚
                        std.debug.print("linyapsd: 调用方 {s} 记不进跟踪表，无法得知它何时退出\n", .{call.sender});
                        dbus.done(ev);
                        dbus.closeConnection(conn);
                        return 1;
                    };
                    // 回不出消息、发不出去，都只可能是这条连接已经不能用 ——
                    // 不吞掉，报出来并退出，留一个坏掉的连接继续转毫无意义。
                    const keep_serving = dispatch(conn, call) catch |e| {
                        std.debug.print("linyapsd: 处理 {s} 失败: {s} ({s})\n", .{ call.member, @errorName(e), dbus.lastError() });
                        dbus.done(ev);
                        dbus.closeConnection(conn);
                        return 1;
                    };
                    dbus.done(ev);
                    if (!keep_serving) break;
                },
                .name_owner_changed => |chg| {
                    // 只认"某个连接没了"：new_owner 为空就是这个名字不再有主。
                    // 换主人（old 和 new 都非空）不影响谁在用我们。
                    const gone = chg.new_owner.len == 0;
                    const was_ours = callers.indexOf(chg.name) != null;
                    const remaining = if (gone and was_ours) callers.remove(chg.name) else callers.len;
                    // chg 的字段都指向消息内部，上面用完了才能释放它
                    dbus.done(ev);

                    if (gone and was_ours and remaining == 0) {
                        // 曾经有人用过、现在都走了。进程继续待在总线上没有任何意义，
                        // 下次有人调用时 bus 会按服务文件重新拉起一个新的。
                        std.debug.print("linyapsd: 调用方已全部退出，本实例收工\n", .{});
                        break;
                    }
                },
            },
        }
    }

    dbus.closeConnection(conn);
    return 0;
}

/// 等第一个调用方时的轮询间隔。等到了就一直阻塞下去，不再空转。
const poll_ms: c_int = 1000;

/// 起来之后这么久还没有任何人来调用，就认为没人需要自己，收工。
/// 正常被激活时一醒来就该有人来 —— bus 是转发着调用方那个挂起的请求
/// 才把我们拉起来的；这条只兜"被 StartServiceByName 单独叫起来、
/// 调用方随后却没来"的空转，那种情况下没人会记得我们，也就没人会来划掉我们。
const idle_grace_ms: i64 = 30_000;

/// 同时可能有多少个调用方。这个表里放的是"当下有几个进程在用我们"，
/// 正常就是 1，给到 64 是留够余量。
const max_callers = 64;
/// 调用方的唯一名，形如 ":1.23"，由总线自己编号，不会长
const max_caller_name = 64;

/// 记下谁调用过我们，好在他们走光之后退出。
///
/// linyapsd 是被 bus 按需拉起来的，没人用的时候不该留在内存里。
/// 但"没人用"这件事总线不会主动告诉我们，只能自己盯：调用方的唯一名
/// 进这个表，等它的 NameOwnerChanged 报出来（连接没了）再划掉。
const CallerSet = struct {
    names: [max_callers][max_caller_name]u8 = undefined,
    lens: [max_callers]usize = undefined,
    len: usize = 0,

    fn indexOf(self: *const CallerSet, name: []const u8) ?usize {
        for (0..self.len) |i| {
            if (std.mem.eql(u8, self.names[i][0..self.lens[i]], name)) return i;
        }
        return null;
    }

    /// 记下一位调用方。记不下就报错 —— 悄悄丢掉的话，那位调用方走的时候
    /// 本进程不会知道，于是留下来占着总线名，而外面完全看不出来。
    fn add(self: *CallerSet, name: []const u8) error{CannotTrack}!void {
        if (name.len == 0 or name.len > max_caller_name) return error.CannotTrack;
        if (self.indexOf(name) != null) return;
        if (self.len >= max_callers) return error.CannotTrack;
        @memcpy(self.names[self.len][0..name.len], name);
        self.lens[self.len] = name.len;
        self.len += 1;
    }

    /// 划掉一位已经离开的调用方，返回还剩几个。
    fn remove(self: *CallerSet, name: []const u8) usize {
        if (self.indexOf(name)) |i| {
            const last = self.len - 1;
            self.names[i] = self.names[last];
            self.lens[i] = self.lens[last];
            self.len = last;
        }
        return self.len;
    }
};

/// 处理一条方法调用。返回值是"还要不要接着服务" ——
/// 只有 Quit 会说不，其余一律继续。
fn dispatch(conn: dbus.Connection, call: dbus.Incoming) dbus.Error!bool {
    const member = call.member;
    const iface = call.interface;

    // busctl / gdbus 探测存活时会调这个
    if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Peer") and
        std.mem.eql(u8, member, "Ping"))
    {
        var r = try dbus.newReply(call);
        defer r.discard();
        try dbus.sendReply(conn, &r);
        return true;
    }

    // 只认自己的接口；interface 留空时也当成我们的（有些客户端会省略）
    if (iface.len != 0 and !std.mem.eql(u8, iface, interface)) {
        try dbus.replyError(conn, call, "org.freedesktop.DBus.Error.UnknownInterface", "未知接口");
        return true;
    }

    if (std.mem.eql(u8, member, "Ping")) {
        try replyString(conn, call, "pong");
    } else if (std.mem.eql(u8, member, "Version")) {
        try replyString(conn, call, version_z);
    } else if (std.mem.eql(u8, member, "ReadStates")) {
        try handleReadStates(conn, call);
    } else if (std.mem.eql(u8, member, "ExecLlCli")) {
        try handleExecLlCli(conn, call);
    } else if (std.mem.eql(u8, member, "Quit")) {
        // 退出本实例。部署方换上新版本后靠它让旧进程让位：文件换了可旧进程
        // 还占着 bus name 的话，调用照旧由它响应，换了等于没换。
        // 下次调用时 bus 会重新拉起，届时跑的就是新的了。
        try replyString(conn, call, "bye");
        return false;
    } else {
        try dbus.replyError(conn, call, "org.freedesktop.DBus.Error.UnknownMethod", "未知方法");
    }
    return true;
}

fn replyString(conn: dbus.Connection, call: dbus.Incoming, value: [:0]const u8) dbus.Error!void {
    var r = try dbus.newReply(call);
    defer r.discard();
    try dbus.putString(&r, value);
    return dbus.sendReply(conn, &r);
}

/// 把宿主的 states.json 原文整份回给调用方。
fn handleReadStates(conn: dbus.Connection, call: dbus.Incoming) dbus.Error!void {
    // 走 std.c.open 而不是 c.open：glibc 把 fcntl.h 里的 open 做成了宏，
    // 展开后那串 __open_too_many_args 之类的桩函数 translate-c 翻不动。
    // states_path ++ "\x00" 本身就是指向 NUL 结尾字符串的指针，不能再取地址。
    const path_z = states_path ++ "\x00";
    const file = std.c.open(path_z, .{ .ACCMODE = .RDONLY });
    if (file < 0) {
        return dbus.replyError(conn, call, "org.freedesktop.DBus.Error.FileNotFound", "宿主上读不到 states.json");
    }
    defer _ = c.close(file);

    const size = c.lseek(file, 0, c.SEEK_END);
    if (size < 0) {
        return dbus.replyError(conn, call, "org.freedesktop.DBus.Error.FileNotFound", "无法确定 states.json 大小");
    }
    _ = c.lseek(file, 0, c.SEEK_SET);

    const len: usize = @intCast(size);
    if (len >= states_buf.len) {
        return dbus.replyError(conn, call, "org.freedesktop.DBus.Error.LimitsExceeded", "states.json 超出上限");
    }

    var got: usize = 0;
    while (got < len) {
        const n = c.read(file, states_buf[got..].ptr, len - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != len) {
        return dbus.replyError(conn, call, "org.freedesktop.DBus.Error.FileNotFound", "读取 states.json 不完整");
    }
    states_buf[len] = 0;

    var r = try dbus.newReply(call);
    defer r.discard();
    try dbus.putString(&r, states_buf[0..len :0]);
    return dbus.sendReply(conn, &r);
}

/// 跑一个白名单内的 ll-cli 子命令，回 (退出码, stdout, stderr)。
fn handleExecLlCli(conn: dbus.Connection, call: dbus.Incoming) dbus.Error!void {
    var parsed: dbus.ArgList = .{};
    // 参数表的问题分开说：畸形和超限是两回事，笼统回一句"解析失败"
    // 会让调用方看不出是自己发错了还是参数太长。
    dbus.readStringArray(call, &parsed) catch |e| return switch (e) {
        error.TooLarge => dbus.replyError(conn, call, "org.freedesktop.DBus.Error.InvalidArgs", "参数过多或过长"),
        else => dbus.replyError(conn, call, "org.freedesktop.DBus.Error.InvalidArgs", "参数表格式不合法"),
    };

    if (parsed.len == 0) {
        return dbus.replyError(conn, call, "org.freedesktop.DBus.Error.InvalidArgs", "参数个数不合法");
    }
    const args = parsed.slice();

    // 白名单只看第一个参数，也就是子命令本身
    var allowed = false;
    for (ll_allowed) |a| {
        if (std.mem.eql(u8, args[0], a)) allowed = true;
    }
    if (!allowed) {
        return dbus.replyError(conn, call, "org.freedesktop.DBus.Error.AccessDenied", "该子命令不在白名单内");
    }

    // 参数原样交给 execv，不经过 shell。storage 里已是 NUL 结尾。
    var argv: [dbus.max_args + 2]?[*:0]const u8 = undefined;
    argv[0] = ll_cli;
    for (0..args.len) |i| {
        argv[i + 1] = @ptrCast(&parsed.storage[i]);
    }
    argv[args.len + 1] = null;

    // 末尾那个 null 就是 argv 的 sentinel，runLlCli 靠它知道参数到哪儿为止
    const run = runLlCli(@ptrCast(&argv)) catch |e| return switch (e) {
        error.SpawnFailed => dbus.replyError(conn, call, "org.freedesktop.DBus.Error.Failed", "无法执行 ll-cli"),
        error.OutputTooLarge => dbus.replyError(conn, call, "org.freedesktop.DBus.Error.LimitsExceeded", "ll-cli 输出超出上限"),
    };

    out_buf[run.out_len] = 0;
    err_buf[run.err_len] = 0;

    var r = try dbus.newReply(call);
    defer r.discard();
    try dbus.putInt32(&r, run.code);
    try dbus.putString(&r, out_buf[0..run.out_len :0]);
    try dbus.putString(&r, err_buf[0..run.err_len :0]);
    return dbus.sendReply(conn, &r);
}

const RunResult = struct {
    code: i32,
    out_len: usize,
    err_len: usize,
};

const RunError = error{
    /// 管道/派生/执行失败，ll-cli 根本没跑起来
    SpawnFailed,
    /// 输出撑满了缓冲。宁可如实失败，也不把截断过的半截输出当成完整结果回给调用方
    OutputTooLarge,
};

/// argv 以 null 收尾，形参的 sentinel 就是这个 null —— 类型本身保证了
/// execv 要的那个结尾，不用再传一个容易算错的长度。
fn runLlCli(argv: [*:null]const ?[*:0]const u8) RunError!RunResult {
    var out_pipe: [2]c_int = undefined;
    var err_pipe: [2]c_int = undefined;
    if (c.pipe(&out_pipe) != 0) return error.SpawnFailed;
    if (c.pipe(&err_pipe) != 0) {
        _ = c.close(out_pipe[0]);
        _ = c.close(out_pipe[1]);
        return error.SpawnFailed;
    }

    const pid = c.fork();
    if (pid < 0) {
        // 还没到 errdefer 那一段（它是 fork 之后才装的），四个 fd 都还开着
        _ = c.close(out_pipe[0]);
        _ = c.close(out_pipe[1]);
        _ = c.close(err_pipe[0]);
        _ = c.close(err_pipe[1]);
        return error.SpawnFailed;
    }

    if (pid == 0) {
        _ = c.close(out_pipe[0]);
        _ = c.close(err_pipe[0]);
        _ = c.dup2(out_pipe[1], 1);
        _ = c.dup2(err_pipe[1], 2);
        _ = c.close(out_pipe[1]);
        _ = c.close(err_pipe[1]);
        // translate-c 把 execv 的形参翻成了 [*c]const [*c]u8，把我们的数组直接投过去
        const cargv: [*c]const [*c]u8 = @ptrCast(@constCast(argv));
        _ = c.execv(ll_cli, cargv);
        c._exit(127);
    }

    _ = c.close(out_pipe[1]);
    _ = c.close(err_pipe[1]);

    // 后面无论哪一步失败，子进程和两个管道都要收干净再往上抛。
    // errdefer 管的是失败路径，正常路径在函数末尾自己收。
    errdefer {
        _ = c.kill(pid, c.SIGKILL);
        _ = c.waitpid(pid, null, 0);
        _ = c.close(out_pipe[0]);
        _ = c.close(err_pipe[0]);
    }

    var out_len: usize = 0;
    var err_len: usize = 0;
    var out_open = true;
    var err_open = true;

    // 两个管道一起等，避免一边写满阻塞而另一边没人读。
    // 各留一字节给结尾的 NUL。
    while (out_open or err_open) {
        var fds = [2]posix.pollfd{
            .{ .fd = out_pipe[0], .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = err_pipe[0], .events = posix.POLL.IN, .revents = 0 },
        };
        // 连管道都等不了了，剩下多少读多少没有意义，如实报错
        _ = posix.poll(&fds, -1) catch return error.SpawnFailed;

        if (out_open and (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
            const dst = out_buf[out_len .. out_buf.len - 1];
            if (dst.len == 0) return error.OutputTooLarge;
            const n = c.read(out_pipe[0], dst.ptr, dst.len);
            if (n > 0) out_len += @intCast(n) else out_open = false;
        }
        if (err_open and (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
            const dst = err_buf[err_len .. err_buf.len - 1];
            if (dst.len == 0) return error.OutputTooLarge;
            const n = c.read(err_pipe[0], dst.ptr, dst.len);
            if (n > 0) err_len += @intCast(n) else err_open = false;
        }
    }
    _ = c.close(out_pipe[0]);
    _ = c.close(err_pipe[0]);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);

    var code: i32 = -1;
    if (c.WIFEXITED(status)) {
        code = c.WEXITSTATUS(status);
    } else if (c.WIFSIGNALED(status)) {
        code = -c.WTERMSIG(status);
    }

    return .{ .code = code, .out_len = out_len, .err_len = err_len };
}
