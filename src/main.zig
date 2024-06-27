const std = @import("std");

/// Tree structure for a word dictionary based on numbers
/// Contains pointers to it recursively
const NumDict = struct {
    /// The 8 sub trees if there are any (for the numbers 2 through 9)
    sub_tree: ?*[8]NumDict = null,
    /// The slice of words that match the coordinates of this branch exactly
    words: std.ArrayListUnmanaged(Word) = std.ArrayListUnmanaged(Word).initBuffer(&.{}),
    /// The best rank of all the words in this words
    best_rank: usize = std.math.maxInt(usize),
    /// Indices of the branches in the order they should be searched for rank optimizations
    search_order: [8]u8 = [8]u8{ 0, 1, 2, 3, 4, 5, 6, 7 },

    /// Word entry of the dictionary
    const Word = struct {
        ascii: []const u8,
        rank: usize,

        pub fn compRanks(_: void, lhs: Word, rhs: Word) bool {
            return lhs.rank < rhs.rank;
        }
    };

    /// Creates a new dictionary based on an interator of lines
    /// line_iterator must have the next() function and provide []const u8 (ascii lines)
    /// This must be deallocated with destroy()
    pub fn create(alloc: std.mem.Allocator, line_iterator: anytype) !NumDict {
        // Return value
        var ret: NumDict = .{};
        errdefer ret.destroy(alloc);

        // TODO: make sure all of the defer paths in there are valid in case of allocator error

        var next_rank: usize = 0;
        while (line_iterator.next()) |line| {
            // Create the word to put in the tree somewhere
            const word = Word{
                .ascii = line,
                .rank = next_rank,
            };
            next_rank += 1;

            try ret.addWord(alloc, word);
        }

        // Optimize the search order
        updateOptimalSearches(&ret);

        return ret;
    }

    /// Adds a word to the tree in the right place
    /// Works on a blank NumDict (NumDict{}), as an alternative to create
    /// But then the dict has to be destroyed later
    /// Dupes the word's ascii
    pub fn addWord(self: *NumDict, alloc: std.mem.Allocator, word: Word) !void {
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

        // Dupe the word to own it
        const allocated_word = Word{
            .ascii = try alloc.dupe(u8, word.ascii),
            .rank = word.rank,
        };
        errdefer alloc.free(allocated_word.ascii);

        // Add the word to the words of the branch
        try current.words.append(alloc, allocated_word);
    }

    /// Sets the search order based on the content of the branches
    /// Is called by create after adding all the words, or manually if only addWord is called()
    pub fn updateOptimalSearches(self: *NumDict) void {
        // Call recursively
        if (self.sub_tree) |tree| {
            // Sort the indices based on the best rank of the branch associated
            std.sort.insertion(u8, &self.search_order, self, NumDict.compRanks);
            for (tree) |*sub_t|
                updateOptimalSearches(sub_t);
        }
    }

    /// Deallocs this buffer and its contents
    pub fn destroy(self: *NumDict, alloc: std.mem.Allocator) void {
        // Call destroy on subtrees
        if (self.sub_tree) |tree| {
            for (tree) |*sub_t| {
                sub_t.destroy(alloc);
            }
            alloc.destroy(self.sub_tree.?);
        }

        // Destroy words
        for (self.words.items) |word| {
            alloc.free(word.ascii);
        }
        self.words.deinit(alloc);
    }

    /// Collects n words from the tree that match (start with) numbers
    /// The result buffer is allocated and the caller owns it (must free it)
    pub fn findAndCollect(self: NumDict, alloc: std.mem.Allocator, n: usize, numbers: []const u8) ![]const []const u8 {
        const words = try alloc.alloc(Word, n);
        defer alloc.free(words);
        const asciis = try alloc.alloc([]const u8, n);
        errdefer alloc.free(asciis);

        // Collect with ranks
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

    /// Collects words from the tree that match (start with) numbers into a user provided buffer
    /// The slice returned is from the passed buffer, to know how many results there are
    pub fn findAndCollectWithRanks(self: NumDict, buf: []Word, numbers: []const u8) ![]const Word {
        var list = std.ArrayListUnmanaged(Word).initBuffer(buf);

        // Check the numbers
        if (!isNumbers(numbers))
            return error.badNumbers;

        // Call the recursive version
        self.findAndCollectInternal(&list, numbers);
        // Sort the results
        std.sort.insertion(Word, list.items, {}, Word.compRanks);

        return list.items;
    }

    /// Find words that match (start with) numbers
    /// The amount of results is determined by the length of list
    /// The results are sorted by rank
    /// Numbers must be valid
    fn findAndCollectInternal(self: NumDict, list: *std.ArrayListUnmanaged(Word), numbers: []const u8) void {
        // In here the ArrayListUnmanaged is used to wait for https://github.com/ziglang/zig/pull/18361 to be accepted
        // As a hybrid between ArrayList and BoundedArray that doesn't try to alloc but doesn't own the buffer
        if (numbers.len == 0) {
            // This variable is for keeping track of the worst item in list
            // Allowing skipping entire branches when they don't have better than the worst
            var context = CollectContext{};
            // We give all the available results
            self.collectRecursive(list, &context);
        } else {
            const num = numbers[0];
            std.debug.assert(num >= '2' and num <= '9');

            if (self.sub_tree) |tree| {
                // Do the find and collect on the right sub tree
                return tree[num - '2'].findAndCollectInternal(list, numbers[1..]);
            }
        }
    }

    /// Context for collectRecursive(), allows the rank based optimizations
    const CollectContext = struct {
        /// the worst word accepted in the result list as of now
        worst_rank: usize = std.math.maxInt(usize),
        /// whether or not the accepted list has been filled
        full: bool = false,
    };

    /// Collect words in this tree and its sub-trees
    /// Pass an unmanaged array to fill, defining the amount of words found
    /// The n best results are kept (based on rank)
    /// This function call itself recursively
    /// The caller can pass a default context, it is meant to be passed recursively
    fn collectRecursive(self: NumDict, list: *std.ArrayListUnmanaged(Word), context: *CollectContext) void {
        // Call recursively on sub trees
        if (self.sub_tree) |tree| {
            // Follow the optimal seach order for it
            for (self.search_order) |i| {
                const sub_t = &tree[i];
                // Collect only if the branch has a better thing to offer
                if (sub_t.best_rank < context.worst_rank or !context.full)
                    sub_t.collectRecursive(list, context);
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
                if (word.rank > context.worst_rank)
                    context.worst_rank = word.rank;
            } else {
                if (insertBasedOnRank(word, list.items)) |new_worst|
                    context.worst_rank = new_worst;
            }
        }

        // When there is no more space in the list, we can start excluding branches
        if (capa == 0)
            context.full = true;
    }

    /// word will be placed in words if theres an element with a worst rank
    /// If thats the case, the rank of the new worst element will be returned
    /// If the word isn't inserted, null is returned
    fn insertBasedOnRank(word: Word, words: []Word) ?usize {
        if (words.len == 0)
            return null;

        // Find the element in words with the worst rank
        var max_rank: usize = 0;
        var snd_max: usize = 0;
        var max_i: usize = undefined;
        for (words, 0..) |w, i| {
            if (w.rank >= max_rank) {
                snd_max = max_rank;
                max_rank = w.rank;
                max_i = i;
            }
        }

        // Replace it or not
        if (word.rank < max_rank) {
            words[max_i] = word;
            return @max(word.rank, snd_max);
        }
        return null;
    }

    /// Functin for sorting the search_order based on the best rank of each branch
    /// Must be called only if there is a sub tree (because of .?)
    pub fn compRanks(context: *NumDict, lhs: u8, rhs: u8) bool {
        return context.sub_tree.?[lhs].best_rank < context.sub_tree.?[rhs].best_rank;
    }

    /// Count the number of words in this dictionary recursively
    pub fn countWords(self: NumDict) usize {
        var ret: usize = self.words.items.len;

        if (self.sub_tree) |trees| {
            for (trees) |sub_t| {
                ret += sub_t.countWords();
            }
        }

        return ret;
    }

    /// Format function for printing a branch and getting some info on it
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print("Tree branch, best score: {}, search order: {any}", .{
            self.best_rank,
            self.search_order,
        });
    }
};

/// Checks if the numbers given is valid for a word
/// i.e. contains numbers 2 through 9 only
pub fn isNumbers(numbers: []const u8) bool {
    for (numbers) |n| {
        if (n < '2' or n > '9')
            return false;
    } else return true;
}

/// Convert a single ascii letter to its matching t9 number
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

/// Convert an ascii string to its matching t9 numbers
pub fn asciiToNumbers(alloc: std.mem.Allocator, ascii: []const u8) ![]const u8 {
    const ret = try alloc.alloc(u8, ascii.len);
    errdefer alloc.free(ret);

    for (ascii, ret) |c, *r| {
        r.* = try charToNumber(c);
    }

    return ret;
}

/// Convert an ascii string to its matching t9 numbers (at comptime, without an allocator)
inline fn asciiToNumbersComptime(comptime ascii: []const u8) []const u8 {
    comptime {
        var ret: []const u8 = "";

        for (ascii) |c| {
            const added = [_]u8{charToNumber(c) catch @compileError("Encountered non alphabetic character " ++ &.{c})};
            ret = ret ++ added;
        }

        return ret;
    }
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

    std.debug.print("{}\n", .{dict});

    var buf: [32]u8 = undefined;

    std.debug.print("2:abc 3:def 4:ghi 5:jkl 6:mno 7:pqrs 8:tuv 9:wxyz\n", .{});
    std.debug.print("Enter some numbers:\n", .{});
    var input = (try stdin.readUntilDelimiterOrEof(&buf, '\n')).?;
    input = input[0 .. input.len - 1];

    const result_count = 1;

    begin = std.time.nanoTimestamp();
    for (0..99999) |_| {
        const w = try dict.findAndCollect(alloc, result_count, input);
        alloc.free(w);
    }
    const words = try dict.findAndCollect(alloc, result_count, input);
    delta = std.time.nanoTimestamp() - begin;

    defer alloc.free(words);
    std.debug.print("Results ({} us per call):\n", .{@divFloor(delta, 100000000)});
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
    try std.testing.expectEqualStrings("484552863", asciiToNumbersComptime("Guillaume"));
    try std.testing.expectEqualStrings("43556096753", asciiToNumbersComptime("Hello World"));
}

test "is numbers" {
    try std.testing.expect(isNumbers("2345"));
    try std.testing.expect(isNumbers("9"));
    try std.testing.expect(isNumbers(""));

    try std.testing.expect(!isNumbers("554a9"));
    try std.testing.expect(!isNumbers("1234"));
    try std.testing.expect(!isNumbers(&.{'9' + 1}));
}

test "small dict" {
    const alloc = std.testing.allocator;

    var dict = NumDict{};
    defer dict.destroy(alloc);

    try std.testing.expectEqual(0, dict.countWords());

    {
        const results = try dict.findAndCollect(alloc, 5, "");
        defer alloc.free(results);

        try std.testing.expectEqual(0, results.len);
    }

    try dict.addWord(alloc, NumDict.Word{ .ascii = "hello", .rank = 0 });
    try dict.addWord(alloc, NumDict.Word{ .ascii = "world", .rank = 1 });
    try dict.addWord(alloc, NumDict.Word{ .ascii = "hey", .rank = 2 });

    dict.updateOptimalSearches();

    try std.testing.expectEqual(3, dict.countWords());

    {
        const results = try dict.findAndCollect(alloc, 5, asciiToNumbersComptime("wor"));
        defer alloc.free(results);

        try std.testing.expectEqual(1, results.len);

        try std.testing.expectEqualSlices(u8, "world", results[0]);
    }

    {
        const results = try dict.findAndCollect(alloc, 2, asciiToNumbersComptime("he"));
        defer alloc.free(results);

        try std.testing.expectEqual(2, results.len);

        try std.testing.expectEqualSlices(u8, "hello", results[0]);
        try std.testing.expectEqualSlices(u8, "hey", results[1]);
    }

    {
        const results = try dict.findAndCollect(alloc, 1, asciiToNumbersComptime("he"));
        defer alloc.free(results);

        try std.testing.expectEqual(1, results.len);

        try std.testing.expectEqualSlices(u8, "hello", results[0]);
    }

    {
        const results = try dict.findAndCollect(alloc, 1, asciiToNumbersComptime("hehe"));
        defer alloc.free(results);

        try std.testing.expectEqual(0, results.len);
    }
}
