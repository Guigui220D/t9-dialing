const std = @import("std");

const Word = struct {
    ascii: []const u8,
    rank: usize,

    pub fn compRanks(_: void, lhs: Word, rhs: Word) bool {
        return lhs.rank < rhs.rank;
    }
};

const NumDict = struct {
    sub_tree: ?*[8]NumDict = null,
    words: std.ArrayListUnmanaged(Word) = std.ArrayListUnmanaged(Word).initBuffer(&.{}),
    best_rank: usize = std.math.maxInt(usize),
    search_order: [8]u8 = [8]u8{ 0, 1, 2, 3, 4, 5, 6, 7 },

    pub fn create(alloc: std.mem.Allocator, line_iterator: anytype) !NumDict {
        // Return value
        var ret: NumDict = .{};
        errdefer ret.destroy(alloc);

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

            try ret.addWord(alloc, word);
        }

        return ret;
    }

    fn addWord(self: *NumDict, alloc: std.mem.Allocator, word: Word) !void {
        // Get the numbers string to find the tree position
        const numbers = try asciiToNumbers(alloc, word.ascii);
        defer alloc.free(numbers);

        // Find the correct branch to put the word on by iteration
        var current: *NumDict = self;
        // Update the best rank field for the optimization
        if (word.rank < current.best_rank)
            current.best_rank = word.rank;

        for (numbers) |n| {
            if (current.sub_tree == null) {
                // Create the sub_tree if it doesn't exist yet
                current.sub_tree = try alloc.create([8]NumDict);
                for (current.sub_tree.?) |*tree|
                    tree.* = .{};
            }
            // Move the pointer for iterative descent
            current = &current.sub_tree.?[n - '2'];
            // Update the best rank field for the optimization
            if (word.rank < current.best_rank)
                current.best_rank = word.rank;
        }

        // Add the word to the words of the branch
        try current.words.append(alloc, word);
    }

    pub fn destroy(self: *NumDict, alloc: std.mem.Allocator) void {
        if (self.sub_tree) |tree| {
            for (tree) |*sub_t| {
                sub_t.destroy(alloc);
            }
            alloc.destroy(self.sub_tree.?);
        }
        self.words.deinit(alloc);
    }

    pub fn findAndCollect(self: NumDict, alloc: std.mem.Allocator, n: usize, numbers: []const u8) ![]const []const u8 {
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

    pub fn findAndCollectWithRanks(self: NumDict, buf: []Word, numbers: []const u8) ![]const Word {
        var list = std.ArrayListUnmanaged(Word).initBuffer(buf);

        try self.findAndCollectInternal(&list, numbers);
        sortByRank(list.items);

        return list.items;
    }

    fn findAndCollectInternal(self: NumDict, list: *std.ArrayListUnmanaged(Word), numbers: []const u8) !void {
        if (numbers.len == 0) {
            // This variable is for keeping track of the worst item in list
            // Allowing skipping entire branches when they don't have better than the worst
            var worst_rank: usize = std.math.maxInt(usize);
            var full: bool = false;
            // We give all the available results
            self.collectRecursive(list, &worst_rank, &full);
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
    // pub fn findAndCollectWithRanksStrict(self: NumDict, numbers: []const u8) ![]const Word {
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

    fn collectRecursive(self: NumDict, list: *std.ArrayListUnmanaged(Word), worst_rank: *usize, full: *bool) void {
        // Call recursively on sub trees
        if (self.sub_tree) |tree| {
            // Follow the optimal seach order for it
            for (self.search_order) |i| {
                const sub_t = &tree[i];
                // Collect only if the branch has a better thing to offer
                if (sub_t.best_rank < worst_rank.* or !full.*)
                    sub_t.collectRecursive(list, worst_rank, full);
            }
        }

        var capa = list.unusedCapacitySlice().len;

        // Add all words of this branch
        for (self.words.items) |word| {
            if (capa > 0) {
                capa -= 1;
                // In the initial phase where we fill the buffer of words, we can't exclude anything
                // Since any option is welcome. Therefore we build up the worst_rank value
                // Which will then be reduced when replacing elements
                list.appendAssumeCapacity(word);
                if (word.rank > worst_rank.*)
                    worst_rank.* = word.rank;
            } else {
                if (insertBasedOnRank(word, list.items)) |new_worst|
                    worst_rank.* = new_worst;
            }
        }

        // When there is no more space in the list, we can start excluding branches
        if (capa == 0)
            full.* = true;
    }

    fn sortByRank(words: []Word) void {
        std.sort.insertion(Word, words, {}, Word.compRanks);
    }

    /// word will be placed in words if theres an element with a worst rank
    /// If thats the case, the rank of the next worst element will be returned
    fn insertBasedOnRank(word: Word, words: []Word) ?usize {
        if (words.len == 0)
            return null;

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
            return max_rank;
        }
        return null;
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

    var begin = std.time.nanoTimestamp();
    var dict = try NumDict.create(alloc, &lines);
    defer dict.destroy(alloc);
    var delta = std.time.nanoTimestamp() - begin;

    std.debug.print("Done! ({} ms)\n", .{@divFloor(delta, 1000000)});

    var buf: [32]u8 = undefined;

    std.debug.print("2:abc 3:def 4:ghi 5:jkl 6:mno 7:pqrs 8:tuv 9:wxyz\n", .{});
    std.debug.print("Enter some numbers:\n", .{});
    var input = (try stdin.readUntilDelimiterOrEof(&buf, '\n')).?;
    input = input[0 .. input.len - 1];

    const result_count = 1;

    begin = std.time.nanoTimestamp();
    for (0..999) |_| {
        const w = try dict.findAndCollect(alloc, result_count, input);
        alloc.free(w);
    }
    const words = try dict.findAndCollect(alloc, result_count, input);
    delta = std.time.nanoTimestamp() - begin;

    defer alloc.free(words);
    std.debug.print("Results ({} us per call):\n", .{@divFloor(delta, 1000000)});
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
