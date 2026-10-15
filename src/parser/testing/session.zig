const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;

// document ownership stays independent of the grammar state of each program parser
test "document arena shares storage while program parsers keep independent state" {
    const source = "const a = 1; {outer + inner} const b = 2;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = ast.Tree.initInArena(arena.allocator(), source);
    tree.lang = .tsx;
    const options: parser.Options = .{ .lang = .tsx, .tokens = true };
    var body: parser.Parser = undefined;
    try body.initInTree(&tree, options, .{ .start = 0, .end = 0 });
    defer if (body.initialized) body.deinit();

    var first_parser: parser.Parser = undefined;
    try first_parser.initInTree(&tree, options, .{ .start = 0, .end = 12 });
    const first = try first_parser.parseProgramNode();
    _ = try first_parser.finish(first);
    first_parser.deinit();
    try std.testing.expect(tree.arena == null);
    try std.testing.expectEqual(arena.allocator().ptr, tree.allocator().ptr);
    try std.testing.expectEqual(&tree, body.tree);

    const expression_state = try body.enterRange(.{
        .start = 14,
        .end = @intCast(source.len),
    }, options);
    const enclosing_token = body.current_token;
    var second_parser: parser.Parser = undefined;
    try second_parser.initInTree(&tree, .{
        .lang = .ts,
        .tokens = true,
        .allow_return_outside_function = true,
    }, .{ .start = 28, .end = @intCast(source.len) });
    const second = try second_parser.parseProgramNode();
    const second_view = try second_parser.finish(second);
    try std.testing.expectEqual(second, second_view.root);
    try std.testing.expectEqual(.ts, second_view.lang);
    try std.testing.expectEqual(.null, tree.root);
    second_parser.deinit();
    try std.testing.expectEqualDeep(enclosing_token, body.current_token);
    try std.testing.expectEqual(.tsx, body.lang);
    try std.testing.expectEqual(.tsx, tree.lang);
    try std.testing.expect(!body.context.@"return");
    const expression = try body.parseDelimitedExpression(&.{
        .start = 14,
        .terminator = .right_brace,
    });
    body.leaveRange(&expression_state);
    _ = try body.finish(.null);
    body.deinit();
    tree.deinit();

    // releasing borrowed handles leaves their results alive until the document arena ends
    try std.testing.expect(!tree.hasErrors());
    try std.testing.expect(first != second);
    try std.testing.expectEqual(.program, std.meta.activeTag(tree.data(first)));
    try std.testing.expectEqual(.program, std.meta.activeTag(tree.data(second)));
    try std.testing.expectEqual(.binary_expression, std.meta.activeTag(tree.data(expression)));
    try std.testing.expectEqual(@as(u32, 14), tree.span(expression).start);
}

// parser failure must leave caller-owned allocations alive and preserve earlier nodes
test "borrowed parser allocation failures release only the document arena" {
    var completed = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena.deinit();
        var tree = ast.Tree.initInArena(arena.allocator(), "/*region*/ const a = 1;");
        const retained = tree.addNode(.{ .identifier_reference = .{ .name = .empty } }, .{
            .start = 0,
            .end = 0,
        }) catch continue;
        var program: parser.Parser = undefined;
        program.initInTree(&tree, .{ .tokens = true }, .{
            .start = 0,
            .end = @intCast(tree.source.len),
        }) catch {
            try std.testing.expectEqual(
                .identifier_reference,
                std.meta.activeTag(tree.data(retained)),
            );
            continue;
        };
        defer program.deinit();
        const root = program.parseProgramNode() catch {
            try std.testing.expectEqual(
                .identifier_reference,
                std.meta.activeTag(tree.data(retained)),
            );
            continue;
        };
        _ = program.finish(root) catch continue;
        try std.testing.expectEqual(.identifier_reference, std.meta.activeTag(tree.data(retained)));
        if (!failing.has_induced_failure) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
}

// speculative region parsing must roll back every shared result without touching other state
test "a body checkpoint rolls back an independent program's shared metadata" {
    const source = "name}/*nested*/ const x=1;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = ast.Tree.initInArena(arena.allocator(), source);
    var body: parser.Parser = undefined;
    const options: parser.Options = .{ .tokens = true };
    try body.initInTree(&tree, options, .{ .start = 0, .end = @intCast(source.len) });
    const checkpoint = body.checkpoint();
    var program: parser.Parser = undefined;
    try program.initInTree(&tree, options, .{ .start = 5, .end = @intCast(source.len) });
    const root = try program.parseProgramNode();
    const view = try program.finish(root);
    program.deinit();
    try std.testing.expectEqual(root, view.root);
    try std.testing.expectEqual(.null, tree.root);
    try std.testing.expectEqual(@as(usize, 1), tree.comments.len);
    try std.testing.expect(tree.tokens.len > 0);
    body.rewind(checkpoint);
    try std.testing.expectEqual(@as(u32, 0), tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), tree.comments.len);
    try std.testing.expectEqual(@as(usize, 0), tree.tokens.len);
    const expression = try body.parseDelimitedExpression(&.{ .terminator = .right_brace });
    _ = try body.finish(.null);
    try std.testing.expect(!tree.hasErrors());
    try std.testing.expectEqual(.identifier_reference, std.meta.activeTag(tree.data(expression)));
}

// verify the real expression root and delimiter without validating foreign trailing text
test "expression parse retains source offsets and leaves the delimiter unconsumed" {
    const source = "prefix { /*before*/ name + 1 /*after*/ } <div @bad='unterminated>";
    var result = try parser.parseExpression(std.testing.allocator, source, .{
        .options = .{ .lang = .tsx, .tokens = true, .comments = .both },
        .start = 8,
        .terminator = .right_brace,
    });
    defer result.tree.deinit();

    try std.testing.expect(!result.tree.hasErrors());
    try std.testing.expectEqual(.binary_expression, std.meta.activeTag(
        result.tree.data(result.tree.root),
    ));
    const span = result.tree.span(result.tree.root);
    try std.testing.expectEqualStrings("name + 1", source[span.start..span.end]);
    try std.testing.expectEqual(span.end, result.end);
    try std.testing.expectEqual(.right_brace, result.next.tag);
    try std.testing.expectEqual(@as(u32, 39), result.next.span.start);
    try std.testing.expectEqual(@as(usize, 2), result.tree.comments.len);
    try std.testing.expectEqual(@as(usize, 3), result.tree.tokens.len);
    for (result.tree.tokens) |token| {
        try std.testing.expect(token.span.end <= result.end);
        try std.testing.expect(token.tag != .right_brace);
    }
    try std.testing.expectEqual(
        result.tree.nodes.len + 1,
        result.tree.attached_comment_offsets.len,
    );
}

// exercise JS lexical contexts that a delimiter counter cannot distinguish
test "expression parse handles regex division templates TS and TSX" {
    const cases = [_]struct { source: []const u8, lang: ast.Lang }{
        .{ .source = "/[}]/.test(value)}<foreign>", .lang = .js },
        .{ .source = "a / b / c}<foreign>", .lang = .js },
        .{ .source = "`a${`b${({ x: '}' }).x}`}c`}<foreign>", .lang = .js },
        .{ .source = "({ x: 1 } satisfies { x: number }).x}<foreign>", .lang = .ts },
        .{ .source = "<T,>(value: T): T => value}<foreign>", .lang = .tsx },
        .{ .source = "items.map(x => <b>{x}</b>)}<foreign>", .lang = .tsx },
        .{ .source = "await load()}<foreign>", .lang = .ts },
    };
    for (cases) |case| {
        var result = try parser.parseExpression(std.testing.allocator, case.source, .{
            .options = .{ .lang = case.lang, .source_type = .module },
            .terminator = .right_brace,
        });
        defer result.tree.deinit();
        try std.testing.expect(!result.tree.hasErrors());
        try std.testing.expect(result.tree.root != .null);
        try std.testing.expectEqual(.right_brace, result.next.tag);
        try std.testing.expectEqualStrings("}<foreign>", case.source[result.next.span.start..]);
        try std.testing.expect(result.end <= result.next.span.start);
    }
}

// compare empty containers, missing delimiters and failed expressions through the same API
test "expression diagnostics distinguish empty invalid and missing delimiters" {
    var empty = try parser.parseExpression(std.testing.allocator, " /*empty*/ }", .{
        .options = .{ .comments = .both },
        .terminator = .right_brace,
        .allow_empty = true,
    });
    defer empty.tree.deinit();
    try std.testing.expect(!empty.tree.hasErrors());
    try std.testing.expectEqual(.null, empty.tree.root);
    try std.testing.expectEqual(@as(u32, 0), empty.end);
    try std.testing.expectEqual(@as(usize, 1), empty.tree.comments.len);

    for ([_][]const u8{ "a + }", "", "a", "a b}", "'bad}" }) |source| {
        var invalid = try parser.parseExpression(std.testing.allocator, source, .{
            .options = .{ .comments = .both },
            .terminator = .right_brace,
            .allow_empty = true,
        });
        defer invalid.tree.deinit();
        try std.testing.expect(invalid.tree.hasErrors());
        for (invalid.tree.diagnostics.items) |diagnostic| {
            try std.testing.expect(diagnostic.span.end <= source.len);
        }
    }
    var disallowed = try parser.parseExpression(std.testing.allocator, "}", .{
        .terminator = .right_brace,
        .allow_empty = false,
    });
    defer disallowed.tree.deinit();
    try std.testing.expect(disallowed.tree.hasErrors());
}

// prove caller context and precedence control the stopping token rather than adding wrappers
test "expression context and minimum precedence are honored" {
    var await_expression = try parser.parseExpression(std.testing.allocator, "await load()}", .{
        .options = .{ .source_type = .script },
        .context = .{ .await = true },
        .terminator = .right_brace,
    });
    defer await_expression.tree.deinit();
    try std.testing.expect(!await_expression.tree.hasErrors());
    try std.testing.expectEqual(.await_expression, std.meta.activeTag(
        await_expression.tree.data(await_expression.tree.root),
    ));
    var yield_expression = try parser.parseExpression(std.testing.allocator, "yield value}", .{
        .context = .{ .yield = true },
        .terminator = .right_brace,
    });
    defer yield_expression.tree.deinit();
    try std.testing.expect(!yield_expression.tree.hasErrors());
    try std.testing.expectEqual(.yield_expression, std.meta.activeTag(
        yield_expression.tree.data(yield_expression.tree.root),
    ));
    var no_in = try parser.parseExpression(std.testing.allocator, "value in object}", .{
        .context = .{ .in = false },
        .terminator = .in,
    });
    defer no_in.tree.deinit();
    try std.testing.expect(!no_in.tree.hasErrors());
    try std.testing.expectEqual(.identifier_reference, std.meta.activeTag(
        no_in.tree.data(no_in.tree.root),
    ));
    try std.testing.expectEqual(@as(u32, 5), no_in.end);
    var assignment = try parser.parseExpression(std.testing.allocator, "a = b, c}", .{
        .min_precedence = parser.Precedence.Assignment,
        .terminator = .comma,
    });
    defer assignment.tree.deinit();
    try std.testing.expect(!assignment.tree.hasErrors());
    try std.testing.expectEqual(.assignment_expression, std.meta.activeTag(
        assignment.tree.data(assignment.tree.root),
    ));
    try std.testing.expectEqual(.comma, assignment.next.tag);
}

// compare a permitted nesting depth with the first rejected level and a large hostile input
test "expression nesting is bounded before stack exhaustion" {
    const cases = [_]struct { source: []const u8, valid: bool }{
        .{ .source = "[[[0]]]}", .valid = true },
        .{ .source = "[[[[0]]]]}", .valid = false },
    };
    for (cases) |case| {
        var result = try parser.parseExpression(std.testing.allocator, case.source, .{
            .options = .{ .expression_depth_max = 4 },
            .terminator = .right_brace,
        });
        defer result.tree.deinit();
        try std.testing.expectEqual(!case.valid, result.tree.hasErrors());
        if (!case.valid) {
            try std.testing.expectEqualStrings(
                "Expression nesting exceeds parser limit",
                result.tree.diagnostics.items[0].message,
            );
        }
    }
    var source: [4098]u8 = undefined;
    @memset(source[0..2048], '[');
    source[2048] = '0';
    @memset(source[2049..4097], ']');
    source[4097] = '}';
    var result = try parser.parseExpression(std.testing.allocator, &source, .{
        .terminator = .right_brace,
    });
    defer result.tree.deinit();
    try std.testing.expect(result.tree.hasErrors());
    try std.testing.expectEqualStrings(
        "Expression nesting exceeds parser limit",
        result.tree.diagnostics.items[0].message,
    );
}

// truncate before invalid foreign bytes and check source positions are never rebased
test "bounded expression and program ranges retain original source positions" {
    const expression_source = "Astro: (a + 1) 'unterminated";
    var expression = try parser.parseExpression(std.testing.allocator, expression_source, .{
        .options = .{ .preserve_parens = false },
        .start = 7,
        .end = 14,
    });
    defer expression.tree.deinit();
    try std.testing.expect(!expression.tree.hasErrors());
    try std.testing.expectEqual(.binary_expression, std.meta.activeTag(
        expression.tree.data(expression.tree.root),
    ));
    try std.testing.expectEqual(@as(u32, 8), expression.tree.span(expression.tree.root).start);
    try std.testing.expectEqual(@as(u32, 14), expression.end);
    try std.testing.expectEqual(.eof, expression.next.tag);

    const source = "---\nimport x from 'x';\n" ++
        "const a: number = await x();\nreturn a;\n---\n<style>{";
    const end = @as(u32, @intCast(std.mem.findPos(u8, source, 4, "---").?));
    var program = try parser.parseProgramRange(std.testing.allocator, source, .{
        .source_type = .module,
        .lang = .ts,
        .allow_return_outside_function = true,
        .tokens = true,
    }, .{ .start = 4, .end = end });
    defer program.deinit();
    try std.testing.expect(!program.hasErrors());
    try std.testing.expectEqual(.module, program.source_type);
    try std.testing.expectEqual(ast.Span{ .start = 4, .end = end }, program.span(program.root));
    const body = program.extra(program.data(program.root).program.body);
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expectEqual(@as(u32, 4), program.span(body[0]).start);
    try std.testing.expectEqual(.eof, program.tokens[program.tokens.len - 1].tag);
    try std.testing.expectEqual(end, program.tokens[program.tokens.len - 1].span.end);
}

// allow return independently of module semantics while preserving upstream defaults
test "module top level return is opt in and commonjs retains its default" {
    var rejected = try parser.parse(std.testing.allocator, "return 1;", .{
        .source_type = .module,
    });
    defer rejected.deinit();
    try std.testing.expect(rejected.hasErrors());
    var module = try parser.parse(
        std.testing.allocator,
        "import x from 'x'; export const a = await x(); return a;",
        .{ .source_type = .module, .allow_return_outside_function = true },
    );
    defer module.deinit();
    try std.testing.expect(!module.hasErrors());
    try std.testing.expectEqual(.module, module.data(module.root).program.source_type);
    var commonjs = try parser.parse(std.testing.allocator, "return 1;", .{
        .source_type = .commonjs,
    });
    defer commonjs.deinit();
    try std.testing.expect(!commonjs.hasErrors());
}

const ReaderState = struct {
    nodes: u32 = 0,
    captures: u32 = 0,
    rewinds: u32 = 0,

    fn markup(self: *ReaderState) parser.MarkupHandler {
        return .{
            .context = self,
            .parse = readMarkup,
            .checkpoint = capture,
            .rewind = restore,
        };
    }

    fn readMarkup(context: *anyopaque, session: *parser.Parser) error{OutOfMemory}!?ast.NodeIndex {
        const self: *ReaderState = @ptrCast(@alignCast(context));
        std.debug.assert(session.current_token.tag == .less_than);
        const start = session.current_token.span.start;
        const remaining = session.source[start..session.lexer.source.len];
        if (!std.mem.startsWith(u8, remaining, "<raw>")) return null;
        const closing = std.mem.find(u8, remaining, "</raw>").?;
        const end = start + @as(u32, @intCast(closing + "</raw>".len));
        std.debug.assert(end <= session.lexer.source.len);
        self.nodes += 1;
        const node = try session.tree.addNode(.{
            .identifier_reference = .{ .name = try session.tree.addString("__foreign") },
        }, .{ .start = start, .end = end });
        _ = try session.resumeAt(end, .normal);
        return node;
    }

    fn capture(context: *anyopaque) u32 {
        const self: *ReaderState = @ptrCast(@alignCast(context));
        std.debug.assert(self.nodes < 100);
        self.captures += 1;
        std.debug.assert(self.captures > 0);
        return self.nodes;
    }

    fn restore(context: *anyopaque, marker: u32) void {
        const self: *ReaderState = @ptrCast(@alignCast(context));
        std.debug.assert(marker <= self.nodes);
        self.nodes = marker;
        self.rewinds += 1;
        std.debug.assert(self.rewinds > 0);
    }
};

// an invalid JS raw body proves the callback prevents JS tokenization at nested depths
test "foreign markup reader works inside functions conditionals and template interpolations" {
    var state: ReaderState = .{};
    const source = "items.map(x => x ? <raw>/* } ' @bad</raw> : `${<raw>{bad</raw>}`)}";
    var result = try parser.parseExpression(std.testing.allocator, source, .{
        .options = .{ .lang = .tsx, .markup = state.markup(), .tokens = true },
        .terminator = .right_brace,
    });
    defer result.tree.deinit();
    try std.testing.expect(!result.tree.hasErrors());
    try std.testing.expectEqual(@as(u32, 2), state.nodes);
    try std.testing.expectEqual(.right_brace, result.next.tag);
    for (result.tree.tokens) |token| {
        try std.testing.expect(token.tag != .less_than);
    }

    const program_source = "export function view() { return <raw>unclosed ' {} @</raw>; }";
    var program = try parser.parse(std.testing.allocator, program_source, .{
        .lang = .tsx,
        .markup = state.markup(),
    });
    defer program.deinit();
    try std.testing.expect(!program.hasErrors());
    try std.testing.expectEqual(@as(u32, 3), state.nodes);
}

// a declined markup reader preserves ordinary JSX and generic-arrow discrimination
test "foreign markup reader declines JSX and does not consume TS generic arrows" {
    var state: ReaderState = .{};
    for ([_][]const u8{ "<div/>}", "<T,>(x: T) => x}" }) |source| {
        var result = try parser.parseExpression(std.testing.allocator, source, .{
            .options = .{ .lang = .tsx, .markup = state.markup() },
            .terminator = .right_brace,
        });
        defer result.tree.deinit();
        try std.testing.expect(!result.tree.hasErrors());
        try std.testing.expectEqual(@as(u32, 0), state.nodes);
        try std.testing.expectEqual(.right_brace, result.next.tag);
    }
}

// capture both parser storage and external nodes across a raw-reader rewind
test "session checkpoint restores tokens comments context and external markup state" {
    var state: ReaderState = .{};
    var session: parser.Parser = undefined;
    const source = "<raw>/* invalid ' @ {</raw> /*after*/ + 1}";
    try session.initSession(std.testing.allocator, source, .{
        .lang = .tsx,
        .markup = state.markup(),
        .tokens = true,
    }, .{ .start = 0, .end = @intCast(source.len) });
    defer session.deinit();
    const checkpoint = session.checkpoint();
    _ = try session.parseExpressionNode(parser.Precedence.Lowest);
    try std.testing.expectEqual(@as(u32, 1), state.nodes);
    try std.testing.expectEqual(.right_brace, session.current_token.tag);
    session.context.await = false;
    session.rewind(checkpoint);
    try std.testing.expectEqual(@as(u32, 0), state.nodes);
    try std.testing.expect(state.rewinds > 0);
    try std.testing.expect(session.context.await);
    try std.testing.expectEqual(.less_than, session.current_token.tag);
    try std.testing.expectEqual(@as(usize, 0), session.tokens.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.lexer.comments.items.len);
    _ = try session.parseExpressionNode(parser.Precedence.Lowest);
    try std.testing.expectEqual(@as(u32, 1), state.nodes);
    try std.testing.expectEqual(@as(usize, 1), session.lexer.comments.items.len);
}

// an invalid token after raw markup must stay invalid so program recovery can make progress
test "raw resume reports lexical errors and keeps recovery inside the bounded range" {
    const source = "prefix raw \\bad\nsuffix";
    var session: parser.Parser = undefined;
    try session.initSession(std.testing.allocator, source, .{}, .{ .start = 7, .end = 16 });
    defer session.deinit();
    const checkpoint = session.checkpoint();
    try std.testing.expectEqual(@as(?void, null), try session.resumeAt(11, .normal));
    try std.testing.expectEqual(.invalid, session.current_token.tag);
    try std.testing.expect(session.diagnostics.items.len > 0);
    for (session.diagnostics.items) |diagnostic| {
        try std.testing.expect(diagnostic.span.start >= 7);
        try std.testing.expect(diagnostic.span.end <= 16);
    }
    session.rewind(checkpoint);
    try std.testing.expectEqual(@as(usize, 0), session.diagnostics.items.len);
    try std.testing.expectEqual(.identifier, session.current_token.tag);
    try std.testing.expectEqual(@as(u32, 7), session.current_token.span.start);
}

// inject allocation failure at every arena allocation until each path succeeds
test "expression and ranged program allocation failures free their arenas" {
    const cases = [_][]const u8{ "/*leading*/ a + b}", "/*leading*/ 'unterminated" };
    for (cases) |source| {
        var succeeded = false;
        for (0..64) |fail_index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
                .fail_index = fail_index,
            });
            const result = parser.parseExpression(failing.allocator(), source, .{
                .options = .{ .comments = .both, .tokens = true },
                .terminator = .right_brace,
            }) catch continue;
            result.tree.deinit();
            if (!failing.has_induced_failure) {
                succeeded = true;
                break;
            }
        }
        try std.testing.expect(succeeded);
    }
    var succeeded = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const source = "prefix /*leading*/ const a: number = 1; suffix";
        const tree = parser.parseProgramRange(failing.allocator(), source, .{
            .lang = .ts,
            .comments = .both,
            .tokens = true,
        }, .{ .start = 7, .end = 38 }) catch continue;
        tree.deinit();
        if (!failing.has_induced_failure) {
            succeeded = true;
            break;
        }
    }
    try std.testing.expect(succeeded);
}

// compare escaped IdentifierStart and IdentifierPart with their decoded ECMAScript names
test "escaped identifiers accept ECMAScript dollar underscore and join controls" {
    const cases = [_]struct { source: []const u8, name: []const u8 }{
        .{ .source = "\\u005f\\u005fastro_native_0}", .name = "__astro_native_0" },
        .{ .source = "\\u{5f}value}", .name = "_value" },
        .{ .source = "\\u0024value}", .name = "$value" },
        .{ .source = "value\\u0024\\u005f\\u0030}", .name = "value$_0" },
        .{ .source = "a\\u200c\\u200d}", .name = "a\xe2\x80\x8c\xe2\x80\x8d" },
        .{ .source = "\\u03b1}", .name = "\xce\xb1" },
        .{ .source = "\\u{1d49c}}", .name = "\xf0\x9d\x92\x9c" },
    };
    for (cases) |case| {
        var result = try parser.parseExpression(std.testing.allocator, case.source, .{
            .options = .{ .tokens = true },
            .terminator = .right_brace,
        });
        defer result.tree.deinit();
        try std.testing.expect(!result.tree.hasErrors());
        const root = result.tree.data(result.tree.root);
        try std.testing.expectEqual(.identifier_reference, std.meta.activeTag(root));
        try std.testing.expectEqualStrings(
            case.name,
            result.tree.string(root.identifier_reference.name),
        );
        try std.testing.expect(result.tree.tokens[0].isEscaped());
        try std.testing.expectEqualStrings(
            case.source[0 .. case.source.len - 1],
            result.tree.tokens[0].text(case.source),
        );
    }
    var raw = try parser.parseExpression(std.testing.allocator, "a\xe2\x80\x8c\xe2\x80\x8d}", .{
        .terminator = .right_brace,
    });
    defer raw.tree.deinit();
    try std.testing.expect(!raw.tree.hasErrors());
    var program = try parser.parse(
        std.testing.allocator,
        "const \\u005f\\u005fastro_native_0 = 1; \\u005f\\u005fastro_native_0;",
        .{ .source_type = .module, .tokens = true },
    );
    defer program.deinit();
    try std.testing.expect(!program.hasErrors());
}

// keep invalid code points and escaped keywords rejected while allowing IdentifierName keys
test "escaped identifier fix preserves invalid escapes keyword and JSX restrictions" {
    const invalid = [_][]const u8{
        "\\u0030value}", "\\u002dvalue}", "\\u200cvalue}", "\\u200dvalue}",
        "value\\u002d}", "\\uD800value}", "\\u{110000}}",  "\\u{}}",
        "\\x61}",
    };
    for (invalid) |source| {
        var result = try parser.parseExpression(std.testing.allocator, source, .{
            .terminator = .right_brace,
        });
        defer result.tree.deinit();
        try std.testing.expect(result.tree.hasErrors());
    }
    for ([_][]const u8{
        "\\u0069f (true) {}", "const \\u0063lass = 1;", "var \\u0069f = 1;",
    }) |source| {
        var tree = try parser.parse(std.testing.allocator, source, .{
            .source_type = .module,
        });
        defer tree.deinit();
        try std.testing.expect(tree.hasErrors());
    }
    var property = try parser.parseExpression(
        std.testing.allocator,
        "({ \\u0069f: 1 }).\\u0069f}",
        .{ .terminator = .right_brace },
    );
    defer property.tree.deinit();
    try std.testing.expect(!property.tree.hasErrors());
    var jsx = try parser.parseExpression(std.testing.allocator, "<\\u0064iv/>}", .{
        .options = .{ .lang = .jsx },
        .terminator = .right_brace,
    });
    defer jsx.tree.deinit();
    try std.testing.expect(jsx.tree.hasErrors());
}

test "mixed nullish logical operators retain recoverable expression and diagnostic" {
    var result = try parser.parseExpression(std.testing.allocator, "a && b || c ?? d}", .{
        .terminator = .right_brace,
    });
    defer result.tree.deinit();
    try std.testing.expect(result.tree.hasErrors());
    try std.testing.expect(result.tree.root != .null);
    const root = result.tree.data(result.tree.root);
    try std.testing.expectEqual(.logical_expression, std.meta.activeTag(root));
    try std.testing.expectEqual(@as(u32, 16), result.end);
    try std.testing.expectEqual(@as(u32, 0), result.tree.span(result.tree.root).start);
    try std.testing.expectEqual(@as(u32, 16), result.tree.span(result.tree.root).end);
}

test "computed enum member span includes opening bracket and trivia" {
    const source = "enum E { [ /*key*/ 'x' ] = 1 }";
    var tree = try parser.parse(std.testing.allocator, source, .{ .lang = .ts });
    defer tree.deinit();
    try std.testing.expect(!tree.hasErrors());
    const declaration = tree.extra(tree.data(tree.root).program.body)[0];
    const enum_body = tree.data(declaration).ts_enum_declaration.body;
    const member = tree.extra(tree.data(enum_body).ts_enum_body.members)[0];
    try std.testing.expect(tree.data(member).ts_enum_member.computed);
    const member_span = tree.span(member);
    try std.testing.expectEqualStrings(
        "[ /*key*/ 'x' ] = 1",
        source[member_span.start..member_span.end],
    );
    const name = tree.data(member).ts_enum_member.id;
    try std.testing.expectEqualStrings("'x'", source[tree.span(name).start..tree.span(name).end]);
}

test "enum computed literals preserve syntax restrictions" {
    for ([_][]const u8{ "enum E {['x']=1}", "enum E {[`x`]=1}" }) |source| {
        var tree = try parser.parse(std.testing.allocator, source, .{ .lang = .ts });
        defer tree.deinit();
        try std.testing.expect(!tree.hasErrors());
    }
    for ([_][]const u8{
        "enum E {`x`=1}", "enum E {[`x${v}`]=1}", "enum E {[x]=1}",
        "enum E {[1]=1}", "enum E {1=1}",
    }) |source| {
        var tree = try parser.parse(std.testing.allocator, source, .{ .lang = .ts });
        defer tree.deinit();
        try std.testing.expect(tree.hasErrors());
        try std.testing.expectEqual(@as(u32, 0), tree.data(tree.root).program.body.len);
        try std.testing.expectEqual(@as(usize, 1), tree.diagnostics.items.len);
    }
}

test "type argument session retains nested absolute spans and following fused token" {
    const source = "prefix<Foo<string>, [number, boolean?]>> foreign";
    var tree = blk: {
        var session: parser.Parser = undefined;
        try session.initSession(std.testing.allocator, source, .{ .lang = .ts }, .{
            .start = 6,
            .end = @intCast(source.len),
        });
        errdefer session.deinit();
        const root = try session.parseTypeArgumentsNode();
        try std.testing.expect(root != .null);
        try std.testing.expectEqual(.greater_than, session.current_token.tag);
        try std.testing.expectEqual(@as(u32, 39), session.current_token.span.start);
        break :blk try session.finish(root);
    };
    defer tree.deinit();
    const root = tree.root;
    try std.testing.expect(!tree.hasErrors());
    const root_span = tree.span(root);
    const text = source[root_span.start..root_span.end];
    try std.testing.expectEqualStrings("<Foo<string>, [number, boolean?]>", text);
    const params = tree.extra(tree.data(root).ts_type_parameter_instantiation.params);
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqual(.ts_type_reference, std.meta.activeTag(tree.data(params[0])));
    try std.testing.expectEqual(.ts_tuple_type, std.meta.activeTag(tree.data(params[1])));
}

test "type argument session does not lex foreign bytes beyond bounded range" {
    const source = "prefix<string> @foreign='unterminated";
    var tree = blk: {
        var session: parser.Parser = undefined;
        try session.initSession(std.testing.allocator, source, .{ .lang = .ts }, .{
            .start = 6,
            .end = 14,
        });
        errdefer session.deinit();
        const root = try session.parseTypeArgumentsNode();
        try std.testing.expect(root != .null);
        try std.testing.expectEqual(.eof, session.current_token.tag);
        break :blk try session.finish(root);
    };
    defer tree.deinit();
    const root = tree.root;
    try std.testing.expect(!tree.hasErrors());
    try std.testing.expectEqual(@as(u32, 6), tree.span(root).start);
    try std.testing.expectEqual(@as(u32, 14), tree.span(root).end);
}

test "TypeScript type recursion and prefixes stop before stack exhaustion" {
    const cases = [_]struct { open: []const u8, close: []const u8, count: u32, valid: bool }{
        .{ .open = "Foo<", .close = ">", .count = 63, .valid = true },
        .{ .open = "Foo<", .close = ">", .count = 64, .valid = false },
        .{ .open = "Foo<", .close = ">", .count = 1000, .valid = false },
        .{ .open = "keyof ", .close = "", .count = 1000, .valid = false },
        .{ .open = "X extends Y?Z:", .close = "", .count = 1000, .valid = false },
    };
    for (cases) |case| {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(std.testing.allocator);
        try source.appendSlice(std.testing.allocator, "type T=");
        for (0..case.count) |_| try source.appendSlice(std.testing.allocator, case.open);
        try source.appendSlice(std.testing.allocator, "X");
        for (0..case.count) |_| try source.appendSlice(std.testing.allocator, case.close);
        try source.appendSlice(std.testing.allocator, ";");
        var tree = try parser.parse(std.testing.allocator, source.items, .{ .lang = .ts });
        defer tree.deinit();
        try std.testing.expectEqual(!case.valid, tree.hasErrors());
        if (!case.valid) try std.testing.expectEqualStrings(
            "Type nesting exceeds parser limit",
            tree.diagnostics.items[0].message,
        );
    }
}

test "missing operand recovery is opt in and preserves delimiter and dummy spans" {
    const cases = [_]struct { source: []const u8, tag: std.meta.Tag(ast.NodeData), end: u32 }{
        .{ .source = "a + }tail", .tag = .binary_expression, .end = 3 },
        .{ .source = "a *}", .tag = .binary_expression, .end = 3 },
        .{ .source = "!}", .tag = .unary_expression, .end = 1 },
        .{ .source = "a ? b : }", .tag = .conditional_expression, .end = 7 },
        .{ .source = "a + b * }", .tag = .binary_expression, .end = 7 },
        .{ .source = "a && }", .tag = .logical_expression, .end = 4 },
    };
    for (cases) |case| {
        var strict = try parser.parseExpression(std.testing.allocator, case.source, .{
            .terminator = .right_brace,
        });
        defer strict.tree.deinit();
        try std.testing.expectEqual(.null, strict.tree.root);
        var recovered = try parser.parseExpression(std.testing.allocator, case.source, .{
            .terminator = .right_brace,
            .recover_missing_rhs = true,
        });
        defer recovered.tree.deinit();
        const root_data = recovered.tree.data(recovered.tree.root);
        try std.testing.expectEqual(case.tag, std.meta.activeTag(root_data));
        try std.testing.expectEqual(case.end, recovered.tree.span(recovered.tree.root).end);
        try std.testing.expectEqual(case.end, recovered.end);
        try std.testing.expectEqual(.right_brace, recovered.next.tag);
        try std.testing.expectEqual(@as(usize, 1), recovered.tree.diagnostics.items.len);
        var dummy_found = false;
        for (recovered.tree.nodes.items(.data), recovered.tree.nodes.items(.span)) |data, span| {
            if (data == .identifier_reference and
                data.identifier_reference.name.start == data.identifier_reference.name.end)
            {
                try std.testing.expectEqual(@as(u32, 0), span.start);
                try std.testing.expectEqual(@as(u32, 0), span.end);
                dummy_found = true;
            }
        }
        try std.testing.expect(dummy_found);
    }
    for ([_][]const u8{ "f(a + }", "[a + }", "x=>}", "a + (x=>})}" }) |source| {
        var failed = try parser.parseExpression(std.testing.allocator, source, .{
            .terminator = .right_brace,
            .recover_missing_rhs = true,
        });
        defer failed.tree.deinit();
        try std.testing.expectEqual(.null, failed.tree.root);
        try std.testing.expect(failed.tree.hasErrors());
    }
}
