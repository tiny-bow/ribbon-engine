const assets = @This();

const std = @import("std");
const log = std.log.scoped(.assets);
const builtin = @import("builtin");
const HostApi = @import("HostApi");
const G = HostApi;
const rlfw = @import("rlfw");
const zimalloc = @import("zimalloc");
const rgl = @import("rgl");
const roml = @import("roml");

pub const ShutdownStyle = enum { soft, hard };

pub const watch = Watcher.watch;
pub const discover = Discovery.discover;
pub const analyze = Graph.analyze;

pub var dir_path: []const u8 = "assets";

pub const PartialAsset = struct {
    type: Name,
    binding: ?Binding = null,
    data: ?[]const u8 = null,

    pub fn deinit(self: *PartialAsset, api: *HostApi) void {
        if (self.binding) |*binding| {
            binding.deinit(api);
        }
    }
};

pub const Discovery = struct {
    assets: std.StringArrayHashMapUnmanaged(PartialAsset) = .empty,
    dirs: std.StringArrayHashMapUnmanaged(std.fs.Dir) = .empty,
    mods: std.StringArrayHashMapUnmanaged(BindingTable) = .empty,

    pub fn deinit(self: *Discovery, api: *HostApi) void {
        var asset_it = self.assets.iterator();
        while (asset_it.next()) |entry| {
            entry.value_ptr.deinit(api);
        }

        var dir_it = self.dirs.iterator();
        while (dir_it.next()) |entry| {
            entry.value_ptr.close();
        }
        self.dirs.deinit(api.allocator.collection);

        var mod_it = self.mods.iterator();
        while (mod_it.next()) |entry| {
            for (entry.value_ptr.values()) |*value_ptr| {
                value_ptr.deinit(api);
            }
            entry.value_ptr.deinit(api.allocator.collection);
        }
        self.mods.deinit(api.allocator.collection);
    }

    // TODO: create an id interner so we don't have to compare names everywhere
    pub fn discover(api: *HostApi) !Discovery {
        log.info("discovering assets ...", .{});

        var asset_dir = api.cwd.openDir(dir_path, .{ .iterate = true }) catch |err| {
            log.err("failed to open assets directory: {}", .{err});
            return error.InvalidAssetDirectory;
        };
        defer asset_dir.close();

        var self = Discovery {};
        errdefer self.deinit(api);

        var it = asset_dir.iterate();
        while (it.next() catch |err| {
            log.err("failed to iterate assets directory [{s}]: {}", .{dir_path, err});
            return error.InvalidAssetDirectory;
        }) |entry| {
            switch (entry.kind) {
                .directory => {
                    log.info("found directory [{s}]", .{entry.name});

                    var dir = asset_dir.openDir(entry.name, .{ .iterate = true }) catch |err| {
                        log.err("failed to open module sub-directory [{s}]: {}", .{entry.name, err});
                        return error.InvalidAssetDirectory;
                    };
                    errdefer dir.close();

                    if (self.mods.getKey(entry.name)) |module_name| {
                        try self.dirs.put(api.allocator.collection, module_name, dir);
                    } else {
                        const module_name = try api.allocator.long_term.dupe(u8, entry.name);
                        try self.dirs.put(api.allocator.collection, module_name, dir);
                    }
                },

                .file => {
                    if (std.mem.endsWith(u8, entry.name, ".mod")) {
                        log.info("found module file [{s}]", .{entry.name});
                    } else {
                        log.warn("ignoring unknown file in root asset directory [{s}]", .{entry.name});
                        continue;
                    }

                    const text = asset_dir.readFileAlloc(api.allocator.temp, entry.name, std.math.maxInt(usize)) catch |err| {
                        log.err("failed to read module file [{s}]: {}", .{entry.name, err});
                        return error.InvalidAssetFile;
                    };
                    defer api.allocator.temp.free(text);

                    const parsed = parseToml(api, text) catch |err| {
                        log.err("failed to parse module file [{s}]: {}", .{entry.name, err});
                        return error.InvalidAssetFile;
                    };

                    const stem = std.fs.path.stem(entry.name);

                    const module_name = if (self.dirs.getKey(stem)) |n| n else try api.allocator.long_term.dupe(u8, stem);

                    if (parsed != .value) {
                        log.err("invalid top-level asset data [{s}]: got type `{s}`, expected a module `value`", .{module_name, @tagName(parsed)});
                        return error.InvalidAsset;
                    }

                    if (parsed.value != .table) {
                        log.err("invalid top-level asset data [{s}]: got type `{s}`, expected a module `table`", .{module_name, @tagName(parsed.value)});
                        return error.InvalidAsset;
                    }

                    const getOrPut = try self.mods.getOrPut(api.allocator.collection, module_name);
                    if (getOrPut.found_existing) {
                        log.err("module [{s}] already exists in bindings", .{module_name});
                        return error.InvalidAssetFile;
                    }

                    getOrPut.value_ptr.* = parsed.value.table;
                },

                else => {
                    log.warn("ignoring unknown file in root asset directory [{s}]", .{entry.name});
                    continue;
                }
            }
        }

        return self;
    }
};

pub const AssetType = struct {
    name: Name,
    vtable: *const VTable,

    pub const VTable = struct {
        analyze: Analyzer,

        pub const Analyzer = union(enum) {
            none: void,
            data: void,
            custom_handler: CustomHandler,

            pub const CustomHandler = struct {
                callback: *const Callback,
                input: Input = .toml,
                pub const Input = enum { none, file, bytes, toml };
                pub const Callback = fn (asset_type: *AssetType, api: *HostApi, graph: *Graph, module_name: *const Name, in: *anyopaque, out: *?[]const u8) callconv(.c) G.Signal;
            };

            pub fn custom(input: CustomHandler.Input, callback: *const CustomHandler.Callback) @This() {
                return .{
                    .custom_handler = .{
                        .callback = callback,
                        .input = input,
                    },
                };
            }

            pub fn autoToml(comptime Asset: type, comptime name: Name) @This() {
                const field_names = comptime std.meta.fieldNames(Asset);
                return AssetType.VTable.Analyzer.custom(.toml, struct {
                    pub fn generated_custom_toml_analyzer(_: *AssetType, api: *HostApi, graph: *Graph, module_name: *const Name, in: *anyopaque, _: *?[]const u8) callconv(.c) G.Signal {
                        if (field_names.len == 0) {
                            log.info("[{s}] {s} asset has no fields", .{module_name.*, name});
                        }

                        const table: *BindingTable = @alignCast(@ptrCast(in));

                        var n: usize = 0;

                        inline for (field_names) |field_name| {
                            const T: type = comptime @FieldType(Asset, field_name);
                            const asset_type_name, const is_required = if (comptime extractAssetRefInfo(T)) |info| info else continue;

                            if (table.getPtr(field_name)) |binding| {
                                graph.analyzeBinding(api, module_name.*, asset_type_name, binding) catch return G.Signal.panic;
                                n += 1;
                            } else if (is_required) {
                                log.err("[{s}] {s} asset missing required binding `{s}`", .{module_name.*, name, field_name});
                                return G.Signal.panic;
                            }
                        }

                        if (table.count() > n) {
                            log.warn("[{s}] {s} asset has invalid bindings; only the following are analyzed:", .{module_name.*, name});
                            inline for (field_names) |field_name_2| {
                                const T2: type = comptime @FieldType(Asset, field_name_2);
                                const asset_type_name_2, _ = if (comptime extractAssetRefInfo(T2)) |info| info else continue;
                                std.debug.print("  {s}: {s}\n", .{field_name_2, asset_type_name_2});
                            }
                            log.warn("[{s}] extra bindings found:", .{module_name.*});
                            var it = table.iterator();
                            extra: while (it.next()) |entry| {
                                inline for (field_names) |field_name_3| {
                                    if (std.mem.eql(u8, entry.key_ptr.*, field_name_3)) {
                                        continue :extra;
                                    }
                                }

                                std.debug.print("  {s}: ", .{entry.key_ptr.*});
                                std.debug.print("{s}", .{@tagName(entry.value_ptr.*)});
                                switch (entry.value_ptr.*) {
                                    .ref => std.debug.print(" [{s}]\n", .{entry.value_ptr.ref}),
                                    .override => std.debug.print(" [{s}] -> [{s}]\n", .{entry.value_ptr.override.old, entry.value_ptr.override.new}),
                                    .value => |v| std.debug.print(" {s}\n", .{@tagName(v)}),
                                }
                            }
                        }

                        return G.Signal.okay;
                    }
                }.generated_custom_toml_analyzer);
            }
        };
    };
};



pub const CacheVersion = enum(u64) {
    none = 0,
    _,

    pub fn increment(self: *CacheVersion) void {
        // if you're still holding onto a ref by the time this wraps, congrats on immortality
        self.* = @enumFromInt(@intFromEnum(self.*) +% 1);
    }
};

pub fn PossibleCacheHit(comptime T: type, comptime kind: enum { slice, pointer }, comptime mutability: enum { mutable, immutable }) type {
    return struct {
        version: CacheVersion,
        data: Data,

        pub fn get(self: *PossibleCacheHit, cache_version: CacheVersion) ?Data {
            // NOTE: this should just be a cmov, and will likely get inlined into other logic, so I've avoided branch hinting here
            return if (self.version == cache_version) self.data else null;
        }

        pub const Data = switch (kind) {
            .slice => switch(mutability) {
                .mutable => []T,
                .immutable => []const T,
            },
            .pointer => switch(mutability) {
                .mutable => *T,
                .immutable => *const T,
            },
        };
    };
}

pub fn AssetRef(comptime T: type) type {
    return union(enum) {
        unlinked: Name,
        linked: PossibleCacheHit(T, .pointer, .immutable),

        pub const AssetType = T;
    };
}

pub fn extractAssetRefInfo(comptime T: type) ?struct { Name, bool } {
    comptime {
        switch (@typeInfo(T)) {
            .optional => |info| {
                if (@typeInfo(info.child) == .@"union"
                and @hasDecl(info.child, "AssetType")) {
                    return .{ info.child.AssetType.asset_type.name, false };
                }
            },
            .@"union" => {
                if (@hasDecl(T, "AssetType")) {
                    return .{ T.AssetType.asset_type.name, true };
                }
            },
            else => {},
        }

        return null;
    }
}

pub const ShaderProgram = struct {
    gpu: ?rgl.Program = null,
    vert: ?AssetRef(Shader) = null,
    frag: ?AssetRef(Shader) = null,

    pub const asset_type = AssetType {
        .name = "shader_program",
        .vtable = &struct {
            pub const vtable = AssetType.VTable {
                .analyze = AssetType.VTable.Analyzer.autoToml(ShaderProgram, "shader_program"),
            };
        }.vtable,
    };
};

pub const Shader = struct {
    gpu: ?rgl.Shader,
    src: LazyBytes,

    pub const asset_type = AssetType {
        .name = "shader",
        .vtable = &struct {
            pub const vtable = AssetType.VTable {
                .analyze = .none,
            };
        }.vtable,
    };
};

pub const LazyBytes = LazyData(u8);

pub fn LazyData(comptime T: type) type {
    return union(enum) {
        unlinked: Name,
        dynamic: PossibleCacheHit(T, .slice, .mutable),
        linked: PossibleCacheHit(T, .slice, .immutable),
    };
}

pub const Graph = struct {
    discovery: Discovery,
    traversed_asset_cache: std.StringHashMapUnmanaged(Name) = .empty,
    asset_types: std.StringHashMapUnmanaged(AssetType) = .empty,
    edges: std.StringArrayHashMapUnmanaged(NameSet) = .empty,

    pub fn deinit(self: *Graph, api: *HostApi) void {
        for (self.edges.values()) |*value_ptr| {
            value_ptr.deinit(api.allocator.collection);
        }

        self.edges.deinit(api.allocator.collection);
    }

    pub fn analyze(api: *HostApi, discovery: Discovery) error{AssetTypeMismatch, InvalidAssetFile}!Graph {
        log.info("analyzing assets ...", .{});

        var self: Graph = .{ .discovery = discovery };
        errdefer self.deinit(api);

        self.asset_types.put(api.allocator.collection, ShaderProgram.asset_type.name, ShaderProgram.asset_type) catch @panic("OOM in collection allocator");
        self.asset_types.put(api.allocator.collection, Shader.asset_type.name, Shader.asset_type) catch @panic("OOM in collection allocator");

        var it = self.discovery.mods.iterator();
        while (it.next()) |entry| {
            const module_name = entry.key_ptr.*;
            const module_table: *BindingTable = entry.value_ptr;

            log.info("analyzing module [{s}] ...", .{module_name});
            try self.analyzeModule(api, module_name, module_table);
            log.info("... analyzed module [{s}]", .{module_name});
        }

        log.info("... analyzed all referenced assets", .{});

        return self;
    }

    pub fn addEdge(self: *Graph, api: *HostApi, module_a: Name, module_b: Name) void {
        log.info("adding edge [{s}] -> [{s}]", .{module_a, module_b});

        if (std.mem.eql(u8, module_a, module_b)) {
            return;
        }

        const getOrPut = self.edges.getOrPut(api.allocator.collection, module_a) catch @panic("OOM in collection allocator");
        const outbound_edges = if (getOrPut.found_existing) getOrPut.value_ptr else init: {
            getOrPut.value_ptr.* = NameSet.empty;
            break :init getOrPut.value_ptr;
        };

        outbound_edges.put(api.allocator.collection, module_b, {}) catch @panic("OOM in collection allocator");
    }

    pub fn hasEdge(self: *Graph, module_a: Name, module_b: Name) bool {
        const outbound_edges = self.edges.get(module_a) orelse return false;
        return outbound_edges.contains(module_b);
    }

    pub fn analyzeModule(self: *Graph, api: *HostApi, module_name: Name, table: *BindingTable) error{AssetTypeMismatch, InvalidAssetFile}!void {
        log.info("[{s}] analyzing module table ...", .{module_name});

        var it = table.iterator();
        while (it.next()) |entry| {
            const asset_type_name = entry.key_ptr.*;
            const binding = entry.value_ptr;

            try self.analyzeBinding(api, module_name, asset_type_name, binding);
        }
    }

    pub fn analyzeBinding(self: *Graph, api: *HostApi, module_name: Name, asset_type_name: Name, binding: *Binding) error{AssetTypeMismatch, InvalidAssetFile}!void {
        log.info("[{s}] analyzing `{s}` asset {s} binding ...", .{module_name, asset_type_name, @tagName(binding.*)});

        switch (binding.*) {
            .ref => |asset_name| try self.analyzeAssetByName(api, module_name, asset_type_name, asset_name),
            .override => |override| {
                try self.analyzeAssetByName(api, module_name, asset_type_name, override.old);
                try self.analyzeAssetByName(api, module_name, asset_type_name, override.new);
            },
            .value => |*inline_value| try self.analyzeAssetByValue(api, module_name, asset_type_name, inline_value),
        }
    }

    pub fn analyzeAssetByName(self: *Graph, api: *HostApi, module_name: Name, asset_type_name: Name, asset_name: []const u8) error{AssetTypeMismatch, InvalidAssetFile}!void {
        const exists = if (self.traversed_asset_cache.get(asset_name)) |existing_asset_type_name| exists: {
            log.info("[{s}] {s} asset `{s}` already traversed", .{module_name, asset_type_name, asset_name});
            if (!std.mem.eql(u8, existing_asset_type_name, asset_type_name)) {
                log.err("[{s}] {s} asset `{s}` already traversed with different type `{s}`", .{module_name, asset_type_name, asset_name, existing_asset_type_name});
                return error.AssetTypeMismatch;
            }
            break :exists true;
        } else false;

        if (!exists) self.traversed_asset_cache.put(api.allocator.collection, asset_name, asset_type_name) catch @panic("OOM in collection allocator");

        var it = std.fs.path.componentIterator(asset_name) catch |err| {
            log.err("[{s}] failed to iterate asset name as path [{s}]: {}", .{module_name, asset_name, err});
            return error.InvalidAssetFile;
        };

        if (it.root() != null) {
            log.err("[{s}] asset name [{s}] has a root path component; all paths must be relative", .{module_name, asset_name});
            return error.InvalidAssetFile;
        }

        const asset_module_name = (it.next() orelse {
            log.err("[{s}] empty/un-parsable asset name as path [{s}]", .{module_name, asset_name});
            return error.InvalidAssetFile;
        }).name;

        if (it.next() == null) {
            log.err("[{s}] cannot import module [{s}] as asset", .{module_name, asset_module_name});
            return error.InvalidAssetFile;
        }

        self.addEdge(api, module_name, asset_module_name);

        if (exists) {
            log.info("[{s}] asset [{s}] already traversed, edge added, exiting", .{module_name, asset_name});
            return;
        }

        const module_dir = self.discovery.dirs.get(asset_module_name) orelse {
            log.err("[{s}] module [{s}] not found resolving asset [{s}]", .{module_name, asset_module_name, asset_name});
            return error.InvalidAssetFile;
        };

        try self.analyzeAssetData(api, asset_module_name, asset_type_name, asset_name, asset_name[asset_module_name.len + 1..], module_dir);
    }

    pub fn analyzeAssetData(self: *Graph, api: *HostApi, module_name: Name, asset_type_name: Name, full_asset_name: Name, local_asset_name: Name, dir: std.fs.Dir) error{AssetTypeMismatch, InvalidAssetFile}!void {
        log.info("[{s}] analyzing {s} asset data [{s}]", .{module_name, asset_type_name, full_asset_name});

        const asset_type = self.asset_types.getPtr(asset_type_name) orelse {
            log.warn("[{s}] no analyzer for {s} asset type, dependencies will not be graphed", .{module_name, asset_type_name});
            return;
        };

        switch (asset_type.vtable.analyze) {
            .none => log.info("[{s}] analyzer for asset type [{s}] indicates no dependencies are possible", .{module_name, asset_type_name}),
            .data => {
                const data = dir.readFileAlloc(api.allocator.temp, local_asset_name, std.math.maxInt(usize)) catch |err| {
                    log.err("[{s}] failed to open {s} toml asset [{s}]: {}", .{module_name, asset_type_name, full_asset_name, err});
                    return error.InvalidAssetFile;
                };

                const binding: *Binding = binding: {
                    var b = parseToml(api, data) catch |err| {
                        log.err("[{s}] failed to parse {s} toml asset [{s}]: {}", .{module_name, asset_type_name, full_asset_name, err});
                        return error.InvalidAssetFile;
                    };
                    errdefer b.deinit(api);

                    if (b != .value) {
                        log.err("[{s}] invalid {s} toml asset [{s}]: got type `{s}`, expected `value`", .{module_name, asset_type_name, full_asset_name, @tagName(b)});
                        return error.InvalidAssetFile;
                    }

                    if (b.value != .table) {
                        log.err("[{s}] invalid {s} toml asset [{s}]: got type `{s}`, expected `table`", .{module_name, asset_type_name, full_asset_name, @tagName(b.value)});
                        return error.InvalidAssetFile;
                    }

                    const getOrPut = self.discovery.assets.getOrPut(api.allocator.collection, full_asset_name) catch @panic("OOM in collection allocator");
                    if (getOrPut.found_existing) {
                        log.err("[{s}] asset [{s}] already exists in bindings", .{module_name, full_asset_name});
                        return error.InvalidAssetFile;
                    }

                    getOrPut.value_ptr.* = .{ .type = asset_type_name, .binding = b };

                    break :binding &getOrPut.value_ptr.binding.?;
                };

                try self.analyzeAssetByValue(api, module_name, asset_type_name, &binding.value);
            },
            .custom_handler => |handler| {
                var file_slot: std.fs.File = undefined;
                var bytes_slot: []const u8 = undefined;
                var binding_slot: Binding = undefined;

                const data: *anyopaque = data: switch (handler.input) {
                    .none => undefined,
                    .file => {
                        file_slot = dir.openFile(local_asset_name, .{ .lock = .shared, .mode = .read_only }) catch |err| {
                            log.err("[{s}] failed to open {s} asset [{s}]: {}", .{module_name, asset_type_name, full_asset_name, err});
                            return error.InvalidAssetFile;
                        };

                        break :data @ptrCast(&file_slot);
                    },
                    .bytes => {
                        bytes_slot = dir.readFileAlloc(api.allocator.temp, local_asset_name, std.math.maxInt(usize)) catch |err| {
                            log.err("[{s}] failed to open {s} asset [{s}]: {}", .{module_name, asset_type_name, full_asset_name, err});
                            return error.InvalidAssetFile;
                        };

                        break :data @ptrCast(&bytes_slot);
                    },
                    .toml => {
                        bytes_slot = dir.readFileAlloc(api.allocator.temp, local_asset_name, std.math.maxInt(usize)) catch |err| {
                            log.err("[{s}] failed to open {s} asset [{s}]: {}", .{module_name, asset_type_name, full_asset_name, err});
                            return error.InvalidAssetFile;
                        };

                        binding_slot = parseToml(api, bytes_slot) catch |err| {
                            log.err("[{s}] failed to parse {s} asset [{s}]: {}", .{module_name, asset_type_name, full_asset_name, err});
                            return error.InvalidAssetFile;
                        };

                        break :data @ptrCast(&binding_slot);
                    },
                };


                defer switch (handler.input) {
                    .none, .bytes, .toml => {},
                    .file => file_slot.close(),
                };

                errdefer switch (handler.input) {
                    .none, .bytes, .file => {},
                    .toml => binding_slot.deinit(api),
                };

                log.info("[{s}] calling custom analyzer for asset [{s}]", .{module_name, asset_type_name});


                var out: ?[]const u8 = null;

                switch (handler.callback(asset_type, api, self, &module_name, data, &out)) {
                    .okay => {
                        self.discovery.assets.put(api.allocator.collection, full_asset_name, .{ .type = asset_type_name, .data = out }) catch @panic("OOM in collection allocator");
                    },
                    .panic => {
                        log.err("[{s}] custom analyzer for {s} asset [{s}] panicked", .{module_name, asset_type_name, full_asset_name});
                        return error.InvalidAssetFile;
                    },
                }
            }
        }
    }

    pub fn analyzeAssetByValue(self: *Graph, api: *HostApi, module_name: Name, asset_type_name: Name, asset_value: *BindingValue) error{AssetTypeMismatch, InvalidAssetFile}!void {
        switch (asset_value.*) {
            .int, .float, .boolean, .string => {
                log.info("[{s}] {s} leaf `{s}`", .{module_name, asset_type_name, @tagName(asset_value.*)});
            },
            .array => |array| {
                log.info("[{s}] {s} inline array", .{module_name, asset_type_name});

                for (array.items) |*item| {
                    try self.analyzeBinding(api, module_name, asset_type_name, item);
                }
            },
            .table => |table| {
                log.info("[{s}] {s} inline table", .{module_name, asset_type_name});

                for (table.values()) |*binding| {
                    try self.analyzeBinding(api, module_name, asset_type_name, binding);
                }
            },
        }
    }

    pub fn dump(self: *const Graph) void {
        log.info("dumping graph ...", .{});
        var mod_it = self.discovery.mods.iterator();
        while (mod_it.next()) |entry| {
            const module_name = entry.key_ptr.*;

            std.debug.print("[{s}] =>", .{module_name});

            if (self.edges.get(module_name)) |outbound_edges| {
                var edge_it = outbound_edges.keyIterator();
                while (edge_it.next()) |item| {
                    std.debug.print(" {s}", .{item.*});
                }
                std.debug.print("\n", .{});
            } else {
                std.debug.print(" (no edges)\n", .{});
            }
        }
        std.debug.print("  partial assets:\n", .{});
        var asset_it = self.discovery.assets.iterator();
        while (asset_it.next()) |entry| {
            const asset_name = entry.key_ptr.*;
            const asset = entry.value_ptr.*;

            std.debug.print("    {s}: {s}\n", .{asset_name, asset.type});
        }
        log.info("... finished dumping graph", .{});
    }
};


pub const Name = []const u8;
pub const NameSet = std.StringHashMapUnmanaged(void);
pub const String = std.ArrayListUnmanaged(u8);

pub const BindingTable = std.StringArrayHashMapUnmanaged(Binding);
pub const BindingArray = std.ArrayListUnmanaged(Binding);


pub const Binding = union(enum) {
    ref: Name,
    override: BindingOverride,
    value: BindingValue,

    pub fn deinit(self: *Binding, api: *HostApi) void {
        switch (self.*) {
            .ref, .override => {}, // long term allocator
            .value => |*val| val.deinit(api),
        }
    }
};

pub const BindingOverride = struct {
    old: Name,
    new: Name,
};

pub const BindingValue = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: String,
    array: BindingArray,
    table: BindingTable,

    pub fn deinit(self: *BindingValue, api: *HostApi) void {
        switch (self.*) {
            .int, .float, .boolean => {},
            .string => |*str| str.deinit(api.allocator.collection),
            .array => |*ar| {
                for (ar.items) |*item| {
                    item.deinit(api);
                }
                ar.deinit(api.allocator.collection);
            },
            .table => |*table| {
                var it = table.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.deinit(api);
                }
                table.deinit(api.allocator.collection);
            },
        }
    }
};

pub fn parseToml(api: *HostApi, text: []const u8) !Binding {
    var parser = roml.Parser(roml.Value).init(api.allocator.temp);
    defer parser.deinit();

    const result = try parser.parseString(text);
    defer result.deinit();

    return parseTomlValue(api, result.value);
}

pub fn parseTomlValue(api: *HostApi, value: roml.Value) !Binding {
    switch (value) {
        .integer => |val| return .{ .value = .{ .int = val } },
        .float => |val| return .{ .value = .{ .float = val }},
        .boolean => |val| return .{ .value = .{ .boolean = val }},
        .string => |val| {
            var out = try String.initCapacity(api.allocator.collection, val.len);

            out.appendSliceAssumeCapacity(val);

            return .{ .value = .{ .string = out }};
        },
        .array => |unparsed_values| {
            var out = BindingArray.empty;
            errdefer {
                for (out.items) |*item| {
                    item.deinit(api);
                }

                out.deinit(api.allocator.collection);
            }

            for (unparsed_values.items) |unparsed_value| {
                const sub_value = try parseTomlValue(api, unparsed_value);

                try out.append(api.allocator.collection, sub_value);
            }

            return .{ .value = .{ .array = out } };
        },
        .table => |unparsed_table| {
            if (unparsed_table.count() == 1) {
                if (unparsed_table.get("ref")) |ref_value| {
                    if (ref_value != .string) {
                        log.err("invalid reference value type `{s}`, expected `string`", .{@tagName(ref_value)});
                        return error.InvalidReferenceValueType;
                    }

                    const ref_name = try api.allocator.long_term.dupe(u8, ref_value.string);
                    return .{ .ref = ref_name };
                }
            } else if (unparsed_table.count() == 2) override: {
                const a = unparsed_table.get("old") orelse break :override;
                const b = unparsed_table.get("new") orelse break :override;

                if (a != .string) {
                    log.err("invalid old value type `{s}` in asset override, expected `string`", .{@tagName(a)});
                    return error.InvalidReferenceValueType;
                }

                if (b != .string) {
                    log.err("invalid new value type `{s}` in asset override, expected `string`", .{@tagName(b)});
                    return error.InvalidReferenceValueType;
                }

                const old_name = try api.allocator.long_term.dupe(u8, a.string);
                const new_name = try api.allocator.long_term.dupe(u8, b.string);

                return .{ .override = .{ .old = old_name, .new = new_name } };
            }

            var out = BindingTable.empty;
            errdefer {
                var it = out.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.deinit(api);
                }
                out.deinit(api.allocator.collection);
            }

            var it = unparsed_table.iterator();
            while (it.next()) |entry| {
                const name = try api.allocator.long_term.dupe(u8, entry.key_ptr.*);

                const sub_value = try parseTomlValue(api, entry.value_ptr.*);

                try out.put(api.allocator.collection, name, sub_value);
            }

            return .{ .value = .{ .table = out } };
        },
        else => |val| {
            log.err("unsupported TOML value type `{s}`", .{@tagName(val)});

            return error.UnknownValueType;
        },
    }
}



pub const Meta = struct {
    dyn_lib: std.DynLib,
    latest: i128,
    name: []const u8,
    state: State,
    pub const State = enum { init, started, stopped };
};

pub const Binary = extern struct {
    // these fields are set by the binary; on_start must be set by the dyn lib's initializer
    on_start: *const fn () callconv(.c) G.Signal,
    on_stop: ?*const fn () callconv(.c) G.Signal = null,
    on_step: ?*const fn () callconv(.c) G.Signal = null,

    // fields following this line are set by the binary system just before calling on_start

    host: *HostApi = undefined,

    // fields following this line are hidden from HostApi

    meta: *Meta = undefined,

    pub fn open(api: *HostApi, name: []const u8) !void {
        log.info("{p} opening Binary[{s}]", .{api, name});
    }

    pub fn close(self: *Binary) void {
        log.info("closing Binary[{s}]", .{self.meta.name});

        if (self.meta.state == .started and self.on_stop != null) {
            log.err("Binary[{s}] not stopped at close; good luck memory usage 🤞 ...", .{self.meta.name});
        }

        // _ = binaries.orderedRemove(self.meta.name);

        // name_heap.allocator().free(self.meta.name);
        // meta_heap.allocator().destroy(self.meta);

        self.meta.dyn_lib.close();

        log.info("Binary closed", .{});
    }


    pub fn lookup(self: *Binary, comptime T: type, name: [:0]const u8) error{MissingSymbol}!*T {
        return self.meta.dyn_lib.lookup(*T, name) orelse {
            log.err("failed to find Binary[{s}].{s}", .{ self.meta.name, name });
            return error.MissingSymbol;
        };
    }

    pub fn isDirty(self: *Binary) bool {
        _ = self;

        return false;
    }

    pub fn start(self: *Binary) !void {
        log.info("starting Binary[{s}]", .{self.meta.name});

        const signal = self.on_start();

        log.info("Binary[{s}] start callback returned: {s}", .{self.meta.name, @tagName(signal)});

        switch (signal) {
            .okay => {
                self.meta.state = .started;
            },
            .panic => {
                return error.StartBinaryFailed;
            },
        }
    }

    pub fn step(self: *Binary) error{ InvalidBinaryStateTransition, StepBinaryFailed }!void {
        const callback = if (self.on_step) |step_callback| step_callback else return;

        if (self.meta.state != .started) {
            log.err("cannot step Binary[{s}], it has not been started", .{self.meta.name});

            return error.InvalidBinaryStateTransition;
        }

        switch (callback()) {
            .okay => {
                log.debug("Binary[{s}] step successful", .{self.meta.name});
            },
            .panic => {
                log.err("Binary[{s}] step failed", .{self.meta.name});
                return error.StepBinaryFailed;
            },
        }
    }

    pub fn stop(self: *Binary) error{ InvalidBinaryStateTransition, StopBinaryFailed }!void {
        log.info("stopping Binary[{s}]", .{self.meta.name});

        if (self.meta.state != .started) {
            return error.InvalidBinaryStateTransition;
        }

        if (self.on_stop) |stop_callback| {
            switch (stop_callback()) {
                .okay => {
                    log.info("Binary[{s}] stopped successfully", .{self.meta.name});
                },
                .panic => {
                    log.err("Binary[{s}] stop failed", .{self.meta.name});
                    return error.StopBinaryFailed;
                },
            }
        } else {
            log.info("Binary[{s}] has no stop callback", .{self.meta.name});
        }

        self.meta.state = .stopped;
    }
};

pub const Watcher = struct {
    api: *HostApi,
    thread: std.Thread,

    pub var mutex = std.Thread.Mutex{};

    pub var sleep_time: u64 = 1 * std.time.ns_per_s;
    pub var dirty_sleep_multiplier: u64 = 2;

    pub fn watch(api: *HostApi) !Watcher {
        const watch_thread = try std.Thread.spawn(.{}, struct {
            pub fn watcher(host: *HostApi) void {
                log.info("starting Watcher ...", .{});

                while (!host.shutdown.load(.unordered)) {
                    log.debug("Watcher run ...", .{});
                    const dirty = false;
                    {
                        mutex.lock();
                        defer mutex.unlock();

                        // dirty_loop: {}

                        if (dirty) {
                            log.debug("binaries dirty, requesting reload ...", .{});
                            host.reload.store(.soft, .release);
                        } else {
                            log.debug("binaries clean, no reload needed", .{});
                        }
                    }

                    std.Thread.sleep(if (dirty) sleep_time * dirty_sleep_multiplier else sleep_time);
                }

                log.info("Watcher stopping ...", .{});
            }
        }.watcher, .{ api });

        return Watcher{
            .api = api,
            .thread = watch_thread,
        };
    }

    pub fn stop(self: Watcher) void {
        log.info("stopping Watcher ...", .{});
        self.api.shutdown.store(true, .release);
        self.thread.join();
        log.info("Watcher stopped", .{});
    }
};
