//! libdbus 的薄封装。
//!
//! 这里原先是一套手写的 D-Bus 协议栈（SASL 握手、头字段编解码全自己来），
//! 目的是不依赖任何库好静态链接。但那套东西在会话总线的*激活*路径上
//! 栽了跟头：手工启动一切正常，由 bus 拉起来时挂起的调用却永远不投递。
//! 规范里没写死、实现却必须照做的细节太多（凭证字节、字段顺序、broker
//! 把连接认领回 unit 的方式……），重造一遍不值当，改用 libdbus。

const std = @import("std");

const c = @cImport({
    @cInclude("dbus/dbus.h");
});

pub const Error = error{
    ConnectFailed,
    NameError,
    IoFailed,
    TooLarge,
    Malformed,
};

/// ll-cli 参数个数上限，main.zig 要按它开缓冲区
pub const max_args = 16;
/// 单个参数长度上限
const max_arg_len = 512;

/// translate-c 一碰到 DBusError 里的位域就把整个结构体退化成了 opaque，
/// 只能照 C 的 ABI 自己摆一份：两个指针 + 一个塞了 5 个位域的 unsigned int
/// + 一个补齐的 void*。传进 libdbus 时再 @ptrCast 回 *c.DBusError。
const DBusError = extern struct {
    name: [*c]const u8 = null,
    message: [*c]const u8 = null,
    dummy: c_uint = 0,
    padding1: ?*anyopaque = null,
};

var err: DBusError = .{};

fn errPtr() *c.DBusError {
    return @ptrCast(&err);
}

/// 最近一次 libdbus 错误的文本，供调用方打印。
pub fn lastError() []const u8 {
    if (err.message != null) return span(err.message);
    return "(未设置)";
}

/// [*c]u8 -> []const u8，顺带处理 NULL。
fn span(p: [*c]const u8) []const u8 {
    if (p == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

/// 把 slice 抄成 NUL 结尾的 C 字符串，借调用方的 buffer 存放。
fn toZ(buf: []u8, s: []const u8) ?[*:0]const u8 {
    if (s.len + 1 > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

// ------------------------------------------------------------------ 连接

/// 连接句柄。main.zig 只 import 本模块，拿不到 dbus.h 的那些类型。
pub const Connection = *c.DBusConnection;

/// 连上 session bus，自己完成 Hello 和 SASL 握手。
///
/// 地址听总线环境的：bus 激活我们时会把 DBUS_SESSION_BUS_ADDRESS
/// （容器里玲珑设成宿主 bus 的 socket）放在环境里，libdbus 自己会读。
///
/// 但别指望变量缺失时会在这儿失败 —— libdbus 不报错，它回退到默认的
/// unix:path=$XDG_RUNTIME_DIR/bus，也就是一条"本机自己的"总线，而不是
/// 调用方所在的那条。那条上多半没有我们要服务的人，连接却可能是通的，
/// 于是失败被推给调用方，表现为一个空结果。环境对不对最终得靠部署方把
/// 变量设对，这里拦不住。
pub fn connectSessionBus() Error!*c.DBusConnection {
    c.dbus_error_init(errPtr());
    const conn = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, errPtr()) orelse
        return Error.ConnectFailed;
    // bus 断开时别让 libdbus 直接 exit()，我们自己退出循环收摊
    c.dbus_connection_set_exit_on_disconnect(conn, 0);
    return conn;
}

pub fn closeConnection(conn: *c.DBusConnection) void {
    c.dbus_connection_close(conn);
    c.dbus_connection_unref(conn);
}

/// 抢 bus name。返回 DBUS_REQUEST_NAME_REPLY_* ，1 表示拿到主所有者。
pub fn requestName(conn: *c.DBusConnection, name: []const u8) Error!u32 {
    var buf: [256]u8 = undefined;
    const name_z = toZ(&buf, name) orelse return Error.NameError;
    c.dbus_error_init(errPtr());
    const r = c.dbus_bus_request_name(conn, name_z, 0, errPtr());
    if (c.dbus_error_is_set(errPtr()) != 0) return Error.NameError;
    return @intCast(r);
}

// ------------------------------------------------------------------ 收消息

/// 一条进来的方法调用。slice 指向 libdbus 内部的数据，
/// 在 done() 之前一直有效。
pub const Incoming = struct {
    msg: *c.DBusMessage,
    member: []const u8,
    interface: []const u8,
    /// 调用方的唯一名（":1.23" 这种）。谁在用我们，靠它认 ——
    /// 匿名连接不占总线名，这是它唯一能被指认的标识。
    sender: []const u8,
};

/// 总线上某个名字换了主人。调用方退出时，bus 会用它把该连接的
/// 唯一名以 new_owner 为空串的形式报出来。
/// 三个字段都指向消息内部，同样只在 done() 之前有效。
pub const NameOwnerChanged = struct {
    msg: *c.DBusMessage,
    name: []const u8,
    old_owner: []const u8,
    new_owner: []const u8,
};

/// 我们关心的两类消息。其余（NameAcquired、别家的 signal……）
/// 在 nextEvent 里就丢掉了。
pub const Event = union(enum) {
    call: Incoming,
    name_owner_changed: NameOwnerChanged,
};

/// 释放事件占着的消息。两种事件处理完都得调一次 ——
/// 忘了调，libdbus 的引用计数只涨不落。
pub fn done(ev: Event) void {
    c.dbus_message_unref(switch (ev) {
        .call => |x| x.msg,
        .name_owner_changed => |x| x.msg,
    });
}

/// 订阅 NameOwnerChanged：此后总线上任何连接的出现与消失都会推一条过来。
/// 这是"还有谁在用我们"唯一的消息来源。
///
/// 过滤条件只能开到这么宽：调用方是普通的匿名连接（":1.23"），
/// 它们并不占一个有名字的总线名，没法靠名字只筛出它们。
pub fn watchNameOwnerChanged(conn: *c.DBusConnection) Error!void {
    const rule: [:0]const u8 =
        "type='signal',sender='org.freedesktop.DBus'," ++
        "interface='org.freedesktop.DBus',member='NameOwnerChanged'," ++
        "path='/org/freedesktop/DBus'";
    c.dbus_error_init(errPtr());
    c.dbus_bus_add_match(conn, rule.ptr, errPtr());
    if (c.dbus_error_is_set(errPtr()) != 0) return Error.IoFailed;
}

/// 等一次消息的结果。
pub const Next = union(enum) {
    event: Event,
    /// 等满 timeout 也没有消息进来。
    ///
    /// 注意它**不**代表队列是空的：read_write 期间到达的消息要等下一轮 pop
    /// 才拿得到，所以拿到 idle 之后接着调就对了，别当成"真的没动静"。
    idle,
    /// 连接已经不能用了，收不到也发不出去
    closed,
};

/// 等下一条关心的事件。
///
/// timeout_ms 为 -1 表示一直等下去，否则最多等这么久。调用方靠它做
/// 「起来之后多久没人来就收工」这类判断（见 main.zig）。
pub fn nextEvent(conn: *c.DBusConnection, timeout_ms: c_int) Next {
    // 先把已经排队的消息取干净，再回到 socket 上等新的。
    // 反过来（先 read_write 再 pop）不行：队列里明明有消息时
    // read_write 照样会阻塞到超时，白等一整个 timeout。
    while (c.dbus_connection_pop_message(conn)) |msg| {
        if (c.dbus_message_is_signal(msg, c.DBUS_INTERFACE_DBUS, "NameOwnerChanged") != 0) {
            var chg = NameOwnerChanged{
                .msg = msg,
                .name = "",
                .old_owner = "",
                .new_owner = "",
            };
            readNameOwnerChanged(msg, &chg) catch {
                // 参数对不上三个字符串，这条不是我们认得的 NameOwnerChanged。
                // 丢掉，也**不**当成"有人退出了" —— 宁可放过一次、让进程多留一会儿，
                // 也不能凭一条没读懂的消息就断定调用方已经走光
                c.dbus_message_unref(msg);
                continue;
            };
            return .{ .event = .{ .name_owner_changed = chg } };
        }

        if (c.dbus_message_get_type(msg) == c.DBUS_MESSAGE_TYPE_METHOD_CALL) {
            return .{ .event = .{ .call = .{
                .msg = msg,
                .member = span(c.dbus_message_get_member(msg)),
                .interface = span(c.dbus_message_get_interface(msg)),
                .sender = span(c.dbus_message_get_sender(msg)),
            } } };
        }

        c.dbus_message_unref(msg);
    }

    if (c.dbus_connection_read_write(conn, timeout_ms) == 0) return .closed;
    return .idle;
}

/// 读 NameOwnerChanged 的三个字符串参数（name, old_owner, new_owner）。
/// 少一个、类型不对，都算畸形，交给调用方决定怎么处置。
fn readNameOwnerChanged(msg: *c.DBusMessage, out: *NameOwnerChanged) Error!void {
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(msg, &it) == 0) return Error.Malformed;
    inline for (.{ "name", "old_owner", "new_owner" }) |field| {
        if (c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_STRING) return Error.Malformed;
        var p: [*c]const u8 = undefined;
        c.dbus_message_iter_get_basic(&it, @ptrCast(&p));
        @field(out.*, field) = span(p);
        _ = c.dbus_message_iter_next(&it);
    }
}

// ------------------------------------------------------------------ 发回复

/// 追加用的迭代器句柄。所有追加都经过它，Reply 里存的就是根那一个。
///
/// 它只在调用方开好的变量里存在，一路传指针、不复制：libdbus 的迭代器
/// 里存着"下一次追加落在哪"，复制一份再往副本里追加，原件的位置就停在旧处，
/// 之后由原件继续装数据会装错地方。
pub const Iter = struct {
    c_it: c.DBusMessageIter,
};

/// 边构造边追加的实现句柄。
pub const Reply = struct {
    msg: *c.DBusMessage,
    it: Iter,

    pub fn discard(self: *Reply) void {
        c.dbus_message_unref(self.msg);
    }
};

pub fn newReply(call: Incoming) Error!Reply {
    const msg = c.dbus_message_new_method_return(call.msg) orelse return Error.IoFailed;
    var it: Iter = .{ .c_it = undefined };
    c.dbus_message_iter_init_append(msg, &it.c_it);
    return .{ .msg = msg, .it = it };
}

/// 取 Reply 的根迭代器，用来往外开容器（数组套结构体这种）。
/// 返回的是 Reply 里那一个本身，不复制 —— 复制的后果见 Iter 的说明。
pub fn root(r: *Reply) *Iter {
    return &r.it;
}

/// 追加一个字符串。libdbus 靠 strlen 定长，所以必须是 NUL 结尾的。
pub fn putString(r: *Reply, s: [:0]const u8) Error!void {
    return putStringI(&r.it, s);
}

pub fn putInt32(r: *Reply, value: i32) Error!void {
    var v: c.dbus_int32_t = value;
    if (c.dbus_message_iter_append_basic(&r.it.c_it, c.DBUS_TYPE_INT32, @ptrCast(&v)) == 0) {
        return Error.TooLarge;
    }
}

/// 往指定迭代器里追加一个字符串，容器内部用它。
pub fn putStringI(it: *Iter, s: [:0]const u8) Error!void {
    var p: [*c]const u8 = s.ptr;
    if (c.dbus_message_iter_append_basic(&it.c_it, c.DBUS_TYPE_STRING, @ptrCast(&p)) == 0) {
        return Error.TooLarge;
    }
}

/// 往指定迭代器里追加一个字节数组（签名 y），也就是一个 ay 容器的内容。
/// 必须已经用 openArray(it, &sub, "y") 开好了那个容器，子迭代器传进来。
///
/// 注意第三个参数要的是**指针变量的地址**，不是数据本身的地址：
/// libdbus 收下后会按 `const unsigned char *const *` 再解一层
/// （_dbus_marshal_write_fixed_multi 里就是 *u8_pp）。
/// 直接把数据地址传进去，它就把头几个字节当成指针去 memmove —— 当场段错误，
/// 而且崩在库里，从调用点完全看不出是这里传错了。所以先放进一个局部变量再取址。
pub fn putBytes(it: *Iter, bytes: []const u8) Error!void {
    var p: [*c]const u8 = bytes.ptr;
    if (c.dbus_message_iter_append_fixed_array(
        &it.c_it,
        c.DBUS_TYPE_BYTE,
        @ptrCast(&p),
        @intCast(bytes.len),
    ) == 0) {
        return Error.TooLarge;
    }
}

/// 在 parent 上开一个数组容器，子迭代器写进 child。
/// elem_sig 是元素的签名（"s"、"(ssay)" 这种）。
pub fn openArray(parent: *Iter, child: *Iter, elem_sig: [*:0]const u8) Error!void {
    if (c.dbus_message_iter_open_container(
        &parent.c_it,
        c.DBUS_TYPE_ARRAY,
        elem_sig,
        &child.c_it,
    ) == 0) {
        return Error.TooLarge;
    }
}

/// 在 parent 上开一个结构体容器。签名由里面装了什么决定，这里不写。
pub fn openStruct(parent: *Iter, child: *Iter) Error!void {
    if (c.dbus_message_iter_open_container(
        &parent.c_it,
        c.DBUS_TYPE_STRUCT,
        null,
        &child.c_it,
    ) == 0) {
        return Error.TooLarge;
    }
}

/// 关掉 child 那个容器，回到 parent。
/// 容器必须严格嵌套着开合 —— libdbus 靠这个把长度和补齐写进消息头。
pub fn closeContainer(parent: *Iter, child: *Iter) Error!void {
    if (c.dbus_message_iter_close_container(&parent.c_it, &child.c_it) == 0) {
        return Error.TooLarge;
    }
}

/// 把回复发出去。**不**释放 Reply —— 引用仍归调用方，
/// 由 Reply.discard() 收尾（两边都 unref 会触发 libdbus 的断言）。
pub fn sendReply(conn: *c.DBusConnection, r: *Reply) Error!void {
    var serial: c.dbus_uint32_t = 0;
    if (c.dbus_connection_send(conn, r.msg, &serial) == 0) return Error.IoFailed;
    _ = c.dbus_connection_flush(conn);
}

/// 回一个 D-Bus 错误。error_name 必须是 org.example.Error.Foo 这种规范名字。
///
/// 出错就向上抛，不吞：名字或说明超长属于本程序的编程错误，
/// 悄悄不发会让调用方干等到超时，比直接失败难查得多。
pub fn replyError(
    conn: *c.DBusConnection,
    call: Incoming,
    error_name: []const u8,
    text: []const u8,
) Error!void {
    var name_buf: [256]u8 = undefined;
    var text_buf: [1024]u8 = undefined;
    const name_z = toZ(&name_buf, error_name) orelse return Error.TooLarge;
    const text_z = toZ(&text_buf, text) orelse return Error.TooLarge;

    const msg = c.dbus_message_new_error(call.msg, name_z, text_z) orelse return Error.IoFailed;
    defer c.dbus_message_unref(msg);

    var serial: c.dbus_uint32_t = 0;
    if (c.dbus_connection_send(conn, msg, &serial) == 0) return Error.IoFailed;
    _ = c.dbus_connection_flush(conn);
}

// ------------------------------------------------------------------ 读参数

/// ExecLlCli 收到的 as 参数，内容拷进自己的存储，脱离 libdbus 的缓冲。
pub const ArgList = struct {
    storage: [max_args][max_arg_len]u8 = undefined,
    args: [max_args][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const ArgList) []const []const u8 {
        return self.args[0..self.len];
    }
};

pub fn readStringArray(call: Incoming, out: *ArgList) Error!void {
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(call.msg, &it) == 0) return Error.Malformed;
    if (c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_ARRAY) return Error.Malformed;

    var sub: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&it, &sub);
    while (c.dbus_message_iter_get_arg_type(&sub) != c.DBUS_TYPE_INVALID) {
        // 参数只接受字符串数组。别的元素类型一律当畸形输入拒掉，
        // 不做"跳过看不懂的部分、能读多少算多少"这种宽容处理 ——
        // 那样会把一个残缺的参数表当成完整的交给 ll-cli。
        if (c.dbus_message_iter_get_arg_type(&sub) != c.DBUS_TYPE_STRING) return Error.Malformed;
        if (out.len >= max_args) return Error.TooLarge;

        var p: [*c]const u8 = undefined;
        c.dbus_message_iter_get_basic(&sub, @ptrCast(&p));
        const s = span(p);
        if (s.len >= max_arg_len) return Error.TooLarge;

        @memcpy(out.storage[out.len][0..s.len], s);
        out.storage[out.len][s.len] = 0;
        out.args[out.len] = out.storage[out.len][0..s.len];
        out.len += 1;

        // next 返回 0 表示数组已经到头
        if (c.dbus_message_iter_next(&sub) == 0) break;
    }
}
