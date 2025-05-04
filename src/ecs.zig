const std = @import("std");
const log = std.log.scoped(.ecs);
const HostApi = @import("HostApi");
const SlotMap = @import("SlotMap");


pub const EntityId = packed struct {
    ref: SlotMap.Ref,
};

pub const ComponentId = enum(u64){_};
pub const ArchetypeId = enum(u64){_};
pub const FlagId = packed struct {
    entity: EntityId,
    local: usize,
};


pub const EntityData = struct {
    flag_map: std.StringArrayHashMapUnmanaged(usize),
    flags: std.bit_set.DynamicBitSetUnmanaged,

    pub const empty = EntityData{
        .flag_map = .empty,
        .flags = .{},
    };

    fn deinit(self: *EntityData, allocator: std.mem.Allocator) void {
        self.flag_map.deinit(allocator);
        self.flags.deinit(allocator);
    }
};

pub const Component = struct {
    size: usize,

    fn makeBuffer(self: Component, allocator: std.mem.Allocator) !ComponentBuffer {
        return .init(self.size, allocator);
    }
};

pub const ComponentBuffer = struct {
    size: usize,
    bytes: std.ArrayListUnmanaged(u8),

    fn init(size: usize, allocator: std.mem.Allocator) !ComponentBuffer {
        return ComponentBuffer{
            .size = size,
            .bytes = try .initCapacity(allocator, 1024 * size),
        };
    }

    fn deinit(self: *ComponentBuffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    fn addOne(self: *ComponentBuffer, allocator: std.mem.Allocator) ![]u8 {
        return self.bytes.addManyAsSlice(allocator, self.size);
    }

    fn destroy(self: *ComponentBuffer, index: usize) void {
        const replace = self.get(index);
        const swap_from = self.bytes.items[self.bytes.len - self.size..];

        if (replace.ptr != swap_from.ptr) @memcpy(replace, swap_from);

        self.bytes.shrinkRetainingCapacity(self.bytes.len - self.size);
    }

    fn getComponent(self: *const ComponentBuffer, index: usize) []u8 {
        return self.bytes.items[index * self.size..(index + 1) * self.size];
    }
};

pub const ArchetypeData = struct {
    entity_data: std.ArrayListUnmanaged(EntityData),
    component_buffers: []ComponentBuffer,

    fn addOne(self: *ArchetypeData, allocator: std.mem.Allocator) !struct { usize, *EntityData } {
        const index = self.entity_data.items.len;
        const entity_data = try self.entity_data.addOne(allocator);

        entity_data.* = .empty;

        for (self.component_buffers) |*buffer| {
            _ = try buffer.addOne(allocator);
        }

        return .{ index, entity_data };
    }

    fn destroy(self: *ArchetypeData, index: usize) void {
        for (self.component_buffers) |*buffer| {
            buffer.destroy(index);
        }

        _ = self.entity_data.swapRemove(index);
    }

    fn getData(self: *const ArchetypeData, index: usize) *EntityData {
        return &self.entity_data.items[index];
    }

    fn getBuffer(self: *const ArchetypeData, index: usize) *ComponentBuffer {
        return &self.component_buffers[index];
    }

    fn getComponent(self: *const ArchetypeData, buffer_index: usize, entity_index: usize) []u8 {
        return self.getBuffer(buffer_index).getComponent(entity_index);
    }
};

pub const Entity = struct {
    archetype: usize,
    local: usize,
};

pub const TypeId = [*:0]const u8;
pub const EntityMap = SlotMap.new(Entity);
pub const ComponentMap = std.AutoArrayHashMapUnmanaged(TypeId, Component);

pub const ArchetypeMap = std.ArrayHashMapUnmanaged([]const ComponentId, usize, struct {
    pub fn hash(_: @This(), k: []const ComponentId) u32 {
        var hasher = std.hash.Fnv1a_32.init();
        hasher.update(std.mem.sliceAsBytes(k));
        return hasher.final();
    }

    pub fn eql(_: @This(), a: []const ComponentId, b: []const ComponentId, _: usize) bool {
        return std.mem.eql(ComponentId, a, b);
    }
}, true);

pub const Universe = struct {
    components: ComponentMap,
    archetype_map: ArchetypeMap,
    archetype_data: std.ArrayListUnmanaged(ArchetypeData),
    entities: EntityMap,

    pub const empty = Universe{
        .components = .empty,
        .archetype_map = .empty,
        .archetype_data = .empty,
        .entities = .empty,
    };

    pub fn deinit(self: *Universe, api: *HostApi) void {
        self.components.deinit(api.allocator.collection);

        for (self.archetype_map.keys()) |id_set| {
            api.allocator.long_term.free(id_set);
        }

        self.archetype_map.deinit(api.allocator.collection);

        for (self.archetype_data.items) |*archetype_data| {
            for (archetype_data.entity_data.items) |*entity_data| {
                entity_data.deinit(api.allocator.collection);
            }

            for (archetype_data.component_buffers) |*buffer| {
                buffer.deinit(api.allocator.collection);
            }

            archetype_data.entity_data.deinit(api.allocator.collection);
            api.allocator.long_term.free(archetype_data.component_buffers);
        }

        self.archetype_data.deinit(api.allocator.collection);
        self.entities.deinit(api.allocator.collection);
    }

    pub fn getComponentIdByValue(self: *Universe, api: *HostApi, type_id: TypeId, size: usize) ComponentId {
        const gop = self.components.getOrPut(api.allocator.collection, type_id) catch @panic("OOM in collection allocator");
        if (!gop.found_existing) {
            gop.value_ptr.* = Component {
                .size = size,
            };
        }

        return @enumFromInt(gop.index);
    }

    pub fn getArchetypeIdFromIdSet(self: *Universe, api: *HostApi, component_ids: []const ComponentId) ArchetypeId {
        const id_buf = api.allocator.temp.dupe(ComponentId, component_ids) catch @panic("OOM in temp allocator");

        var max: usize = 0;
        std.mem.sort(ComponentId, id_buf, &max, struct {
            pub fn sort_ids(max_ptr: *usize, a: ComponentId, b: ComponentId) bool {
                const x = @intFromEnum(a);
                const y = @intFromEnum(b);
                max_ptr.* = @max(max_ptr.*, x, y);
                return x < y;
            }
        }.sort_ids);

        const gop = self.archetype_map.getOrPut(api.allocator.collection, id_buf) catch @panic("OOM in collection allocator");

        if (!gop.found_existing) {
            gop.key_ptr.* = api.allocator.long_term.dupe(ComponentId, id_buf) catch @panic("OOM in long_term allocator");
            gop.value_ptr.* = self.archetype_data.items.len;

            const new_archetype = self.archetype_data.addOne(api.allocator.long_term) catch @panic("OOM in long_term allocator");
            const component_buffers = api.allocator.long_term.alloc(ComponentBuffer, id_buf.len) catch @panic("OOM in long_term allocator");

            for (component_buffers, 0..) |*buffer, i| {
                const def = self.components.values()[i];

                buffer.* = ComponentBuffer.init(def.size, api.allocator.collection) catch @panic("OOM in collection allocator");
            }

            new_archetype.* = ArchetypeData {
                .entity_data = std.ArrayListUnmanaged(EntityData).initCapacity(api.allocator.collection, 1024) catch @panic("OOM in collection allocator"),
                .component_buffers = component_buffers,
            };
        }

        return @enumFromInt(gop.index);
    }

    pub fn getComponentIdByType(self: *Universe, api: *HostApi, comptime T: type) ComponentId {
        return self.getComponentIdByValue(api, @typeName(T), @sizeOf(T));
    }

    pub fn componentIdSetFromPrototype(self: *Universe, api: *HostApi, comptime A: type, out: *[@typeInfo(A).@"struct".fields.len]ComponentId) void {
        const a_info = comptime @typeInfo(A).@"struct";

        if (comptime !a_info.is_tuple) {
            @compileError("Expected a tuple for archetype proto, got " ++ @typeName(A));
        }

        inline for (a_info.fields, 0..) |field, i| {
            out[i] = self.getComponentIdByType(api, field.type);
        }
    }

    pub fn getArchetypeIdFromPrototype(self: *Universe, api: *HostApi, comptime A: type) ArchetypeId {
        var id_set: [@typeInfo(A).@"struct".fields.len]ComponentId = undefined;
        self.componentIdSetFromPrototype(api, A, &id_set);

        return self.getArchetypeIdFromIdSet(api, &id_set);
    }

    pub fn createEntityFlag(self: *Universe, api: *HostApi, entity: EntityId, name: []const u8, initial_value: bool) !FlagId {
        if (name.len == 0) return error.InvalidFlagName;

        const entity_ptr = self.entities.get(entity.ref) orelse return error.InvalidEntityId;
        const archetype_data = &self.archetype_data.items[entity_ptr.archetype];
        const entity_data = archetype_data.getData(entity_ptr.local);

        const gop = entity_data.flag_map.getOrPut(api.allocator.collection, name) catch @panic("OOM in collection allocator");

        if (gop.found_existing) return error.FlagAlreadyExists;

        const flag_index = entity_data.flags.bit_length;
        entity_data.flags.resize(api.allocator.collection, flag_index + 1, initial_value) catch @panic("OOM in collection allocator");

        gop.key_ptr.* = api.allocator.long_term.dupe(u8, name) catch @panic("OOM in long_term allocator");
        gop.value_ptr.* = flag_index;

        return .{ .entity = entity, .local = flag_index };
    }

    pub fn getEntityFlag(self: *Universe, flag: FlagId) bool {
        const entity_ptr = self.entities.get(flag.entity.ref) orelse return null;
        const archetype_data = &self.archetype_data.items[entity_ptr.archetype];
        const entity_data = archetype_data.getData(entity_ptr.local);

        if (flag.local >= entity_data.flags.bit_length) return false;

        return entity_data.flags.isSet(flag.local);
    }

    pub fn setEntityFlag(self: *Universe, flag: FlagId, value: bool) void {
        const entity_ptr = self.entities.get(flag.entity.ref) orelse return;
        const archetype_data = &self.archetype_data.items[entity_ptr.archetype];
        const entity_data = archetype_data.getData(entity_ptr.local);

        if (flag.local >= entity_data.flags.bit_length) return;

        entity_data.flags.set(flag.local, value);
    }


    pub fn createEntityFromPrototype(self: *Universe, api: *HostApi, prototype: anytype) EntityId {
        const F = @TypeOf(prototype.flags);
        const A = @TypeOf(prototype.components);
        const f_info = comptime @typeInfo(F).@"struct";
        const a_info = comptime @typeInfo(A).@"struct";

        const archetype_id = self.getArchetypeIdFromPrototype(api, A);
        const archetype_data = &self.archetype_data.items[@intFromEnum(archetype_id)];

        const entity_index, const entity_data = archetype_data.addOne(api.allocator.collection) catch @panic("OOM in collection allocator");

        entity_data.* = .empty;

        const entity_ref, const entity_ptr = self.entities.create(api.allocator.collection) catch @panic("OOM in collection allocator");

        entity_ptr.* = Entity {
            .archetype = @intFromEnum(archetype_id),
            .local = entity_index,
        };

        const archetype_components = self.archetype_map.keys()[entity_ptr.archetype];

        const entity_id = EntityId { .ref = entity_ref };

        inline for (f_info.fields) |field| {
            if (comptime field.type != bool) {
                @compileLog("Expected a bool for flag " ++ field.name ++ " in prototype" ++ @typeName(F) ++ ", got " ++ @typeName(field.type));
            }

            const gop = entity_data.flag_map.getOrPut(api.allocator.collection, field.name) catch @panic("OOM in collection allocator");

            if (gop.found_existing) return error.FlagAlreadyExists;

            const flag_index = entity_data.flags.bit_length;
            entity_data.flags.resize(api.allocator.collection, flag_index + 1, @field(prototype.flags, field.name)) catch @panic("OOM in collection allocator");

            gop.key_ptr.* = api.allocator.long_term.dupe(u8, field.name) catch @panic("OOM in long_term allocator");
            gop.value_ptr.* = flag_index;
        }

        inline for (a_info.fields) |field| {
            const component_id = self.getComponentIdByType(api, field.type);
            const component_index = std.mem.indexOfScalar(ComponentId, archetype_components, component_id) orelse unreachable;

            const component_ptr = archetype_data.getComponent(component_index, entity_index);

            const not_comptime = @field(prototype.components, field.name); // avoid zig comptime value errors
            @memcpy(component_ptr, std.mem.asBytes(&not_comptime));
        }

        return entity_id;
    }

    pub fn createEntityWithArchetypeId(self: *Universe, api: *HostApi, archetype: ArchetypeId) EntityId {
        const archetype_data = &self.archetype_data.items[@intFromEnum(archetype)];

        const index, const entity_data = archetype_data.addOne(api.allocator.collection) catch @panic("OOM in collection allocator");

        entity_data.* = .empty;

        const ref, const entity_ptr = self.entities.create(api.allocator.collection) catch @panic("OOM in collection allocator");

        entity_ptr.* = Entity {
            .archetype = @intFromEnum(archetype),
            .local = index,
        };

        return .{ .ref = ref };
    }

    pub fn destroyEntity(self: *Universe, entity: EntityId) void {
        const entity_ptr = self.entities.get(entity.ref) orelse return;

        const archetype_data = &self.archetype_data.items[entity_ptr.archetype];

        archetype_data.destroy(entity_ptr.local);

        self.entities.destroy(entity.ref);
    }

    pub fn getComponentIndexById(self: *const Universe, entity: EntityId, component: ComponentId) ?usize {
        const entity_ptr = self.entities.get(entity.ref) orelse return null;

        const archetype_components = self.archetype_map.keys()[entity_ptr.archetype];

        return std.mem.indexOfScalar(ComponentId, archetype_components, component);
    }

    pub fn getComponentBufferByIndex(self: *const Universe, entity: EntityId, component_index: usize) *ComponentBuffer {
        const entity_ptr = self.entities.get(entity.ref) orelse return null;

        const archetype_data = &self.archetype_data.items[entity_ptr.archetype];

        return archetype_data.getBuffer(component_index);
    }

    pub fn getComponentById(self: *const Universe, entity: EntityId, component: ComponentId) ?[]u8 {
        const entity_ptr = self.entities.get(entity.ref) orelse return null;

        const archetype_data = &self.archetype_data.items[entity_ptr.archetype];
        const archetype_components = self.archetype_map.keys()[entity_ptr.archetype];

        const component_index = std.mem.indexOfScalar(ComponentId, archetype_components, component) orelse return null;

        return archetype_data.getBuffer(component_index).getComponent(entity_ptr.local);
    }

    pub fn getComponent(self: *Universe, api: *HostApi, entity: EntityId, comptime C: type) ?*C {
        const entity_ptr = self.entities.get(entity.ref) orelse return null;

        const archetype_data = &self.archetype_data.items[entity_ptr.archetype];
        const archetype_components = self.archetype_map.keys()[entity_ptr.archetype];

        const component_id = self.getComponentIdByType(api, C);
        const component_index = std.mem.indexOfScalar(ComponentId, archetype_components, component_id) orelse return null;

        return @alignCast(@ptrCast(archetype_data.getBuffer(component_index).getComponent(entity_ptr.local).ptr));
    }

    pub fn queryArchetypesWithIdSet(self: *const Universe, components: []const ComponentId) ArchetypeIterator {
        return .{
            .universe = self,
            .query = components,
            .archetype_index = 0,
        };
    }
};

pub const ArchetypeIterator = struct {
    universe: *const Universe,
    query: []const ComponentId,
    archetype_index: usize,

    pub fn next(self: *ArchetypeIterator) ?ArchetypeId {
        const archetype_component_sets = self.universe.archetype_map.keys();

        while (self.archetype_index < self.universe.archetype_data.items.len) {
            if (subset(archetype_component_sets[self.archetype_index], self.query)) {
                self.archetype_index += 1;
                return @enumFromInt(self.archetype_index);
            }

            self.archetype_index += 1;
        }

        return null;
    }
};

pub const EntityDataIterator = struct {
    archetype_data: *const ArchetypeData,
    index: usize,
};

pub fn subset(a: []const ComponentId, b: []const ComponentId) bool {
    for (b) |x| {
        if (!std.mem.indexOfScalar(ComponentId, a, x)) {
            return false;
        }
    }

    return true;
}
