const std = @import("std");

/// 从 build.zig.zon 里读 .version。
///
/// 版本号只写在这一处，源码里那份由它注入 —— 两边各写各的话，
/// 迟早会出现 `--version` 报的号和包上标的不一致，而调用方
/// （host_bridge.dart）正是拿这个号决定要不要覆盖宿主上已装的那份。
fn readZonVersion(b: *std.Build) []const u8 {
    const Zon = struct { version: []const u8 };

    const source = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .limited(64 * 1024),
    ) catch @panic("读不到 build.zig.zon");
    defer b.allocator.free(source);

    // zon 解析要的是 [:0]const u8
    const source_z = b.allocator.dupeZ(u8, source) catch @panic("内存不足");
    defer b.allocator.free(source_z);

    // zon 里还有 name/fingerprint/paths 等字段，这里只关心 version
    const zon = std.zon.parse.fromSliceAlloc(
        Zon,
        b.allocator,
        source_z,
        null,
        .{ .ignore_unknown_fields = true },
    ) catch @panic("build.zig.zon 解析失败");

    if (zon.version.len == 0) @panic("build.zig.zon 的 .version 是空的");
    return zon.version;
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // 默认按 musl 编，不跟宿主的 glibc 走。
    //
    // 静态链 glibc 也能得到「不依赖宿主任何 .so」的产物，但 glibc 会把
    // NSS、locale、gconv、getaddrinfo 那一整套一并链进来 —— 现在一个都不
    // 调，所以看不出问题；等哪天代码里多一次 getpwuid() 或 setlocale()，
    // 就会在别人机器上运行时静默失败（NSS 模块 dlopen 不到、locale 读不到），
    // 而开发机上永远复现不了。musl 没有这层包袱。
    //
    // 显式传 -Dtarget=... 时仍以传进来的为准，这里只管默认值。
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = .musl },
    });

    // libdbus 和它的依赖 expat 都是随包静态带上的，见 tools/build-deps.sh。
    // 用源码而不是系统的 libdbus-1.so，是为了让产物不依赖宿主的任何共享库。
    const dbus_static = b.path("vendor/build-dbus/dbus/libdbus-1.a");
    const expat_static = b.path("vendor/prefix/lib/libexpat.a");

    const exe = b.addExecutable(.{
        .name = "linyapsd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // 交付给用户的产物不需要调试符号
            .strip = optimize != .Debug,
        }),
    });

    // 把 build.zig.zon 里的版本号注进源码（src/main.zig 的 @import("build_options")）
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", readZonVersion(b));
    exe.root_module.addOptions("build_options", opts);

    // 源码树里的 dbus/dbus.h 和构建目录里生成的 dbus-arch-deps.h 都要能找到。
    // 路径里的版本号不是随手写的：它必须和 tools/build-deps.sh 的 DBUS_VER 一致，
    // 换版本时两处一起改。
    exe.root_module.addIncludePath(b.path("vendor/src/dbus-dbus-1.16.2"));
    exe.root_module.addIncludePath(b.path("vendor/build-dbus"));

    exe.root_module.addObjectFile(dbus_static);
    exe.root_module.addObjectFile(expat_static);

    // 静态链接 libc：产物不带任何 .so 依赖，也不挑宿主的 libc
    exe.linkage = .static;

    b.installArtifact(exe);

    const run_step = b.step("run", "前台跑起 linyapsd（会占用 session bus 上的服务名）");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);
}
