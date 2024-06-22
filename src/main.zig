const std = @import("std");

const Word = struct {
    ascii: []const u8,
    rank: usize,
};

const NumTree = struct {
    sub_tree: ?*[8]NumTree = null,
    words: ?std.ArrayList(Word) = null,

    pub fn create(alloc: std.mem.Allocator, line_iterator: anytype) !NumTree {
        // Return value
        var root: NumTree = .{};
        errdefer root.destroy(alloc);

        // TODO: make sure all of the defer paths in there are valid in case of allocator error

        var next_rank: usize = 0;
        while (line_iterator.next()) |line| {
            // Create the word to put in the tree somewhere
            const word = Word{
                .ascii = try alloc.dupe(u8, line),
                .rank = next_rank,
            };
            errdefer alloc.free(word.ascii);
            next_rank += 1;

            // Get the numbers string to find the tree position
            const numbers = try asciiToNumbers(alloc, word.ascii);
            defer alloc.free(numbers);

            // Find the correct branch to put the word on by iteration
            var current: *NumTree = &root;
            for (numbers) |n| {
                if (current.sub_tree == null) {
                    current.sub_tree = try alloc.create([8]NumTree);
                    for (current.sub_tree.?) |*tree|
                        tree.* = .{};
                }
                current = &current.sub_tree.?[n - '2'];
            }

            // Add the word to the words of the branch
            if (current.words == null)
                current.words = std.ArrayList(Word).init(alloc);
            try current.words.?.append(word);
        }

        return root;
    }

    pub fn destroy(self: *NumTree, alloc: std.mem.Allocator) void {
        if (self.sub_tree) |tree| {
            for (tree) |*sub_t| {
                sub_t.destroy(alloc);
            }
            alloc.destroy(self.sub_tree.?);
        }
        if (self.words) |words|
            words.deinit();
    }

    pub fn findAndCollectWithRanks(self: NumTree, alloc: std.mem.Allocator, numbers: []const u8) ![]const Word {
        if (numbers.len == 0) {
            // We give all the available results
            var arr = std.ArrayList(Word).init(alloc);
            errdefer arr.deinit();

            try self.collectRecursive(&arr);

            return try arr.toOwnedSlice();
        } else {
            const n = numbers[0];
            if (n < '2' or n > '9')
                return error.InvalidNumber;

            if (self.sub_tree) |tree| {
                // Do the find and collect on the right sub tree
                return tree[n - '2'].findAndCollectWithRanks(alloc, numbers[1..]);
            } else {
                // No results
                return &.{};
            }
        }
    }

    fn collectRecursive(self: NumTree, list: *std.ArrayList(Word)) !void {
        // TODO: add a way to limit the list size (but still keep the best scores)
        if (self.sub_tree) |tree| {
            for (tree) |sub_t| {
                try sub_t.collectRecursive(list);
            }
        }
        if (self.words) |words|
            try list.appendSlice(words.items);
    }
};

pub fn charToNumber(ascii: u8) !u8 {
    return switch (std.ascii.toLower(ascii)) {
        'a', 'b', 'c' => '2',
        'd', 'e', 'f' => '3',
        'g', 'h', 'i' => '4',
        'j', 'k', 'l' => '5',
        'm', 'n', 'o' => '6',
        'p', 'q', 'r', 's' => '7',
        't', 'u', 'v' => '8',
        'w', 'x', 'y', 'z' => '9',
        ' ' => '0',
        else => return error.notAlphabetic,
    };
}

pub const NumberDict = struct {
    ascii: []const []const u8,
    numbers: []const []const u8,
};

pub fn asciiToNumbers(alloc: std.mem.Allocator, ascii: []const u8) ![]const u8 {
    const ret = try alloc.alloc(u8, ascii.len);
    errdefer alloc.free(ret);

    for (ascii, ret) |c, *r| {
        r.* = try charToNumber(c);
    }

    return ret;
}

fn asciiToNumbersComptime(ascii: []const u8) []const u8 {
    var ret: []const u8 = "";

    for (ascii) |c| {
        const added = [_]u8{charToNumber(c) catch @compileError("Encountered non alphabetic character " ++ &.{c})};
        ret = ret ++ added;
    }

    return ret;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const alloc = gpa.allocator();

    const stdin = std.io.getStdIn().reader();

    var lines = std.mem.tokenize(u8, @embedFile("google-10000-english-usa.txt"), "\r\n");

    std.debug.print("Preparing the dict...\n", .{});

    var dict = try NumTree.create(alloc, &lines);
    defer dict.destroy(alloc);

    std.debug.print("Done!\n", .{});

    var buf: [32]u8 = undefined;

    std.debug.print("2:abc 3:def 4:ghi 5:jkl 6:mno 7:pqrs 8:tuv 9:wxyz\n", .{});
    std.debug.print("Enter some numbers:\n", .{});
    const input = (try stdin.readUntilDelimiterOrEof(&buf, '\n')).?;

    const words = try dict.findAndCollectWithRanks(alloc, input[0 .. input.len - 1]);
    defer alloc.free(words);

    for (words) |word| {
        std.debug.print("{s}\n", .{word.ascii});
    }
}

test "ascii to numbers" {
    const talloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(talloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expectEqualStrings("484552863", try asciiToNumbers(alloc, "Guillaume"));
    try std.testing.expectEqualStrings("43556096753", try asciiToNumbers(alloc, "Hello World"));
    try std.testing.expectError(error.notAlphabetic, asciiToNumbers(alloc, "Hi!"));
}
