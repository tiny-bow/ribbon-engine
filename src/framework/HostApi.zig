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
    collection: std.mem.Allocator,
    temp: std.mem.Allocator,
    last_frame: std.mem.Allocator,
    frame: std.mem.Allocator,
    long_term: std.mem.Allocator,
    static: std.mem.Allocator,

    pub fn fromHeap(heap: *Heap) AllocatorSet {
        return AllocatorSet{
            .collection = heap.collection.allocator(),
            .temp = heap.temp.allocator(),
            .last_frame = heap.last_frame.allocator(),
            .frame = heap.frame.allocator(),
            .long_term = heap.long_term.allocator(),
            .static = heap.static.allocator(),
        };
    }
};

pub const CollectionAllocator = @import("zimalloc").Allocator(.{});

pub const Heap = struct {
    collection: CollectionAllocator = CollectionAllocator.init(std.heap.page_allocator) catch @panic("OOM creating initial heap"),
    temp: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    last_frame: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    frame: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    long_term: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    static: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

    pub fn reset(self: *Heap, mode: enum {soft, hard}) void {
        self.collection.deinit();
        self.collection = .init(std.heap.page_allocator);
        self.temp.reset(.retain_capacity);
        self.last_frame.reset(.retain_capacity);
        self.frame.reset(.retain_capacity);
        self.long_term.reset(.retain_capacity);

        if (mode == .hard) {
            self.static.reset(.retain_capacity);
        }
    }
};
