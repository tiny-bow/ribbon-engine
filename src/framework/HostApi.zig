const HostApi = @This();

const std = @import("std");

pub const Signal = enum(i8) {
    panic = -1,
    okay = 0,
};

log: std.io.AnyWriter,
allocator: AllocatorSet,
heap: *Heap,
shutdown: std.atomic.Value(bool) = .init(false),

pub const AllocatorSet = struct {
    temp: std.mem.Allocator,
    last_frame: std.mem.Allocator,
    frame: std.mem.Allocator,
    object: std.mem.Allocator,
    long_term: std.mem.Allocator,
    static: std.mem.Allocator,

    pub fn fromHeap(heap: *Heap) AllocatorSet {
        return AllocatorSet{
            .object = heap.object,
            .temp = heap.temp.allocator(),
            .last_frame = heap.last_frame.allocator(),
            .frame = heap.frame.allocator(),
            .long_term = heap.long_term.allocator(),
            .static = heap.static.allocator(),
        };
    }
};

pub const Heap = struct {
    object: std.mem.Allocator = std.heap.page_allocator,
    temp: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    last_frame: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    frame: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    long_term: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    static: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
};
