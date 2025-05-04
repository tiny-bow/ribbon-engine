const SlotMap = @This();

const std = @import("std");
const log = std.log.scoped(.slot_map);

pub const Ref = packed struct {
    index: usize,
    generation: Generation,

    pub const invalid = @This() {
        .index = 0,
        .generation = .invalid,
    };
};

pub const Generation = enum(u64) {
    invalid = 0,
    _,
};

pub fn new(comptime T: type) type {
    return struct {
        const Self = @This();

        const S = usize;
        const V = usize;

        const Data = struct {
            slot_to_value: V,
            value_to_slot: S,
            freelist_next: ?S,
            generation: Generation,
            value: T,
        };

        freelist_head: ?usize,
        data: std.MultiArrayList(Data),

        pub const empty = Self {
            .freelist_head = null,
            .data = std.MultiArrayList(Data).empty,
        };

        fn slotToValue(self: *const Self, slot_index: S) *V {
            return &self.data.items(.slot_to_value)[slot_index];
        }

        fn valueToSlot(self: *const Self, value_index: V) *S {
            return &self.data.items(.value_to_slot)[value_index];
        }

        fn freelistNext(self: *const Self, slot_index: S) *?S {
            return &self.data.items(.freelist_next)[slot_index];
        }

        fn generation(self: *const Self, value_index: V) *Generation {
            return &self.data.items(.generation)[value_index];
        }

        fn value(self: *const Self, value_index: V) *T {
            return &self.data.items(.value)[value_index];
        }

        fn popFreelist(self: *Self) ?S {
            if (self.freelist_head) |slot_index| {
                self.freelist_head = self.freelistNext(slot_index).*;
                return slot_index;
            } else {
                return null;
            }
        }

        fn pushFreelist(self: *Self, slot_index: S) void {
            self.freelistNext(slot_index).* = self.freelist_head;
            self.freelist_head = slot_index;
        }

        fn incrementGeneration(self: *Self, value_index: V) void {
            const g = self.generation(value_index);
            g.* = @enumFromInt(@intFromEnum(g.*) + 1);
        }

        fn addOne(self: *Self, allocator: std.mem.Allocator) !S {
            const slot_index = try self.data.addOne(allocator);

            self.slotToValue(slot_index).* = slot_index;
            self.valueToSlot(slot_index).* = slot_index;
            self.freelistNext(slot_index).* = null;
            self.generation(slot_index).* = @enumFromInt(1);

            return slot_index;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.data.deinit(allocator);
        }

        pub fn clear(self: *Self) void {
            self.freelist_head = null;
            self.data.clearRetainingCapacity();
        }

        pub fn create(self: *Self, allocator: std.mem.Allocator) !struct { Ref, *T } {
            const slot_index =
                if (self.popFreelist()) |free_slot| free_slot
                else try self.addOne(allocator);

            return .{
                .{ .index = slot_index, .generation = @enumFromInt(1) },
                self.value(self.slotToValue(slot_index).*),
            };
        }

        pub fn destroy(self: *Self, ref: Self.Ref) void {
            const destroyed_slot_index = ref.index;
            const destroyed_value_index = self.slotToValue(destroyed_slot_index).*;
            const generation_ptr = self.generation(destroyed_value_index);

            if (generation_ptr.* != ref.generation) {
                log.warn("double free of slot index {} in SlotMap of type {s}", .{destroyed_slot_index, @typeName(T)});
                return;
            }

            self.incrementGeneration(destroyed_value_index);

            const last_value_slot_index = self.valueToSlot(destroyed_value_index).*;

            if (last_value_slot_index != destroyed_slot_index) {
                const last_value_index = self.slotToValue(last_value_slot_index).*;

                self.value(destroyed_value_index).* = self.value(last_value_index).*;

                self.valueToSlot(last_value_index).* = destroyed_value_index;
                self.slotToValue(destroyed_slot_index).* = last_value_index;

                self.valueToSlot(destroyed_value_index).* = last_value_slot_index;
                self.slotToValue(last_value_slot_index).* = destroyed_slot_index;

                self.pushFreelist(last_value_slot_index);
            } else {
                self.pushFreelist(destroyed_slot_index);
            }
        }

        pub fn get(self: *Self, ref: Ref) ?*T {
            const slot_index = ref.index;
            const value_index_ptr = self.slotToValue(slot_index);
            const generation_ptr = self.generation(value_index_ptr.*);

            if (generation_ptr.* != ref.generation) {
                log.warn("invalid access of slot index {} in SlotMap of type {s}", .{slot_index, @typeName(T)});
                return null;
            }

            return self.value(value_index_ptr.*);
        }
    };
}
