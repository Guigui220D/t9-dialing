const std = @import("std");

const Word = struct {
    ascii: []const u8,
    rank: usize,

    pub fn compRanks(_: void, lhs: Word, rhs: Word) bool {
        return lhs.rank < rhs.rank;
    }
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

    pub fn findAndCollect(self: NumTree, alloc: std.mem.Allocator, n: usize, numbers: []const u8) ![]const []const u8 {
        const words = try alloc.alloc(Word, n);
        defer alloc.free(words);
        const asciis = try alloc.alloc([]const u8, n);
        errdefer alloc.free(asciis);

        const results = try self.findAndCollectWithRanks(words, numbers);
        for (results, asciis[0..results.len]) |word, *ascii| {
            ascii.* = word.ascii;
        }

        // Shrink the allocated asciis to only the size of the results
        // TODO: surely there has to be a better way to do this?
        if (alloc.resize(asciis, results.len)) {
            return asciis[0..results.len];
        } else {
            const ret = try alloc.dupe([]const u8, asciis);
            errdefer alloc.free(ret);
            alloc.free(asciis);
            return ret;
        }
    }

    pub fn findAndCollectWithRanks(self: NumTree, buf: []Word, numbers: []const u8) ![]const Word {
        var list = std.ArrayListUnmanaged(Word).initBuffer(buf);

        try self.findAndCollectInternal(&list, numbers);
        sortByRank(list.items);

        return list.items;
    }

    fn findAndCollectInternal(self: NumTree, list: *std.ArrayListUnmanaged(Word), numbers: []const u8) !void {
        if (numbers.len == 0) {
            // We give all the available results
            self.collectRecursive(list);
        } else {
            const num = numbers[0];
            if (num < '2' or num > '9')
                return error.InvalidNumber;

            if (self.sub_tree) |tree| {
                // Do the find and collect on the right sub tree
                return tree[num - '2'].findAndCollectInternal(list, numbers[1..]);
            }
        }
    }

    // TODO: fix to use the limit and the rank sorting
    // pub fn findAndCollectWithRanksStrict(self: NumTree, numbers: []const u8) ![]const Word {
    //     if (numbers.len == 0) {
    //         // We give all the available results
    //         if (self.words) |words| {
    //             return words.items;
    //         } else return &.{};
    //     } else {
    //         const n = numbers[0];
    //         if (n < '2' or n > '9')
    //             return error.InvalidNumber;

    //         if (self.sub_tree) |tree| {
    //             // Do the find and collect on the right sub tree
    //             return tree[n - '2'].findAndCollectWithRanksStrict(numbers[1..]);
    //         } else {
    //             // No results
    //             return &.{};
    //         }
    //     }
    // }

    fn collectRecursive(self: NumTree, list: *std.ArrayListUnmanaged(Word)) void {
        // Call recursively on sub trees
        if (self.sub_tree) |tree| {
            for (tree) |sub_t| {
                sub_t.collectRecursive(list);
            }
        }
        // Add all words of this branch
        if (self.words) |words| {
            for (words.items) |word| {
                if (list.unusedCapacitySlice().len > 0) {
                    list.appendAssumeCapacity(word);
                } else {
                    _ = insertBasedOnRank(word, list.items);
                }
            }
        }
    }

    fn sortByRank(words: []Word) void {
        std.sort.insertion(Word, words, {}, Word.compRanks);
    }

    fn insertBasedOnRank(word: Word, words: []Word) bool {
        if (words.len == 0)
            return false;

        // Find the element in words with the worst rank
        var max_rank: usize = 0;
        var max_i: usize = undefined;
        for (words, 0..) |w, i| {
            if (w.rank >= max_rank) {
                max_rank = w.rank;
                max_i = i;
            }
        }

        // Replace it or not
        if (word.rank < max_rank) {
            words[max_i] = word;
            return true;
        }
        return false;
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
    var input = (try stdin.readUntilDelimiterOrEof(&buf, '\n')).?;
    input = input[0 .. input.len - 1];

    const words = try dict.findAndCollect(alloc, 4, input);
    defer alloc.free(words);
    std.debug.print("Results:\n", .{});
    for (words) |word| {
        std.debug.print("{s}\n", .{word});
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

test "ascii to numbers comptime" {
    try std.testing.expectEqualStrings("484552863", comptime asciiToNumbersComptime("Guillaume"));
    try std.testing.expectEqualStrings("43556096753", comptime asciiToNumbersComptime("Hello World"));
}
