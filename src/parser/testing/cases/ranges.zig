const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;

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

    try std.testing.expect(!tree.hasErrors());
    try std.testing.expect(first != second);
    try std.testing.expectEqual(.program, std.meta.activeTag(tree.data(first)));
    try std.testing.expectEqual(.program, std.meta.activeTag(tree.data(second)));
    try std.testing.expectEqual(.binary_expression, std.meta.activeTag(tree.data(expression)));
    try std.testing.expectEqual(@as(u32, 14), tree.span(expression).start);
}

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

test "expression parse retains source offsets and leaves the delimiter unconsumed" {
    const source = "prefix { /*before*/ name + 1 /*after*/ } <div @bad='unterminated>";
    var result = try parser.parseExpression(std.testing.allocator, source, &.{
        .options = .{ .lang = .tsx, .tokens = true, .comments = .attach },
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
    try std.testing.expectEqual(@as(usize, 4), result.tree.tokens.len);
    try std.testing.expectEqual(.eof, result.tree.tokens[3].tag);
    for (result.tree.tokens[0..3]) |token| {
        try std.testing.expect(token.span.end <= result.end);
        try std.testing.expect(token.tag != .right_brace);
    }
    var attached = result.tree.commentsOf(result.tree.root);
    try std.testing.expect(attached.next() != null);
}

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
        var result = try parser.parseExpression(std.testing.allocator, case.source, &.{
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

test "expression diagnostics distinguish empty invalid and missing delimiters" {
    var empty = try parser.parseExpression(std.testing.allocator, " /*empty*/ }", &.{
        .options = .{ .comments = .attach },
        .terminator = .right_brace,
        .allow_empty = true,
    });
    defer empty.tree.deinit();
    try std.testing.expect(!empty.tree.hasErrors());
    try std.testing.expectEqual(.null, empty.tree.root);
    try std.testing.expectEqual(@as(u32, 0), empty.end);
    try std.testing.expectEqual(@as(usize, 1), empty.tree.comments.len);

    for ([_][]const u8{ "a + }", "", "a", "a b}", "'bad}" }) |source| {
        var invalid = try parser.parseExpression(std.testing.allocator, source, &.{
            .options = .{ .comments = .attach },
            .terminator = .right_brace,
            .allow_empty = true,
        });
        defer invalid.tree.deinit();
        try std.testing.expect(invalid.tree.hasErrors());
        for (invalid.tree.diagnostics.items) |diagnostic| {
            try std.testing.expect(diagnostic.span.end <= source.len);
        }
    }
    var disallowed = try parser.parseExpression(std.testing.allocator, "}", &.{
        .terminator = .right_brace,
        .allow_empty = false,
    });
    defer disallowed.tree.deinit();
    try std.testing.expect(disallowed.tree.hasErrors());
}

test "expression context and minimum precedence are honored" {
    var await_expression = try parser.parseExpression(std.testing.allocator, "await load()}", &.{
        .options = .{ .source_type = .script },
        .context = .{ .await = true },
        .terminator = .right_brace,
    });
    defer await_expression.tree.deinit();
    try std.testing.expect(!await_expression.tree.hasErrors());
    try std.testing.expectEqual(.await_expression, std.meta.activeTag(
        await_expression.tree.data(await_expression.tree.root),
    ));
    var yield_expression = try parser.parseExpression(std.testing.allocator, "yield value}", &.{
        .context = .{ .yield = true },
        .terminator = .right_brace,
    });
    defer yield_expression.tree.deinit();
    try std.testing.expect(!yield_expression.tree.hasErrors());
    try std.testing.expectEqual(.yield_expression, std.meta.activeTag(
        yield_expression.tree.data(yield_expression.tree.root),
    ));
    var no_in = try parser.parseExpression(std.testing.allocator, "value in object}", &.{
        .allow_in = false,
        .terminator = .in,
    });
    defer no_in.tree.deinit();
    try std.testing.expect(!no_in.tree.hasErrors());
    try std.testing.expectEqual(.identifier_reference, std.meta.activeTag(
        no_in.tree.data(no_in.tree.root),
    ));
    try std.testing.expectEqual(@as(u32, 5), no_in.end);
    var assignment = try parser.parseExpression(std.testing.allocator, "a = b, c}", &.{
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

test "bounded expression and program ranges retain original source positions" {
    const expression_source = "outer: (a + 1) 'unterminated";
    var expression = try parser.parseExpression(std.testing.allocator, expression_source, &.{
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

test "expression and ranged program allocation failures free their arenas" {
    const cases = [_][]const u8{ "/*leading*/ a + b}", "/*leading*/ 'unterminated" };
    for (cases) |source| {
        var succeeded = false;
        for (0..64) |fail_index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
                .fail_index = fail_index,
            });
            const result = parser.parseExpression(failing.allocator(), source, &.{
                .options = .{ .comments = .attach, .tokens = true },
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
            .comments = .attach,
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

test "range lexing excludes foreign prefixes suffixes and CRLF" {
    const source = "\u{1f600} \\ 'unterminated\r\n{value + 1}\r\n\"unterminated";
    const start: u32 = @intCast(std.mem.find(u8, source, "value").?);
    const end: u32 = @intCast(std.mem.find(u8, source, "}").?);
    for ([_]u32{ end, @intCast(source.len) }) |limit| {
        var expression = try parser.parseExpression(std.testing.allocator, source, &.{
            .options = .{ .tokens = true },
            .start = start,
            .end = limit,
            .terminator = if (limit == end) .eof else .right_brace,
        });
        defer expression.tree.deinit();
        try std.testing.expect(!expression.tree.hasErrors());
        try std.testing.expectEqual(
            ast.Span{ .start = start, .end = end },
            expression.tree.span(expression.tree.root),
        );
        try std.testing.expectEqualStrings("value + 1", source[start..expression.end]);
        try std.testing.expectEqual(@as(usize, 4), expression.tree.tokens.len);
        try std.testing.expectEqual(.eof, expression.tree.tokens[3].tag);
        for (expression.tree.tokens[0..3]) |token| {
            try std.testing.expect(token.span.start >= start);
            try std.testing.expect(token.span.end <= end);
        }
    }
}

test "range metadata and grammar state survive a failing nested parse" {
    const source = "one}/*inside*/ two + }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = ast.Tree.initInArena(arena.allocator(), source);
    try tree.addDiagnostic(.{ .span = .{ .start = 0, .end = 0 }, .message = "earlier" });
    var session: parser.Parser = undefined;
    const options: parser.Options = .{ .tokens = true, .lang = .tsx };
    try session.initInTree(&tree, options, .{ .start = 0, .end = @intCast(source.len) });
    defer session.deinit();
    const root = try session.parseDelimitedExpression(&.{ .terminator = .right_brace });
    const before = session.checkpoint();
    const outer_metadata = session.metadata();
    try std.testing.expectEqual(@as(u32, 1), outer_metadata.diagnostics.start);
    try std.testing.expectEqual(@as(u32, 0), outer_metadata.diagnostics.len);
    const saved = try session.enterRange(.{ .start = 4, .end = @intCast(source.len) }, options);
    const rejected = try session.parseDelimitedExpression(&.{
        .start = 4,
        .terminator = .right_brace,
    });
    try std.testing.expectEqual(.null, rejected);
    const nested_metadata = session.metadata();
    try std.testing.expectEqual(@as(u32, 1), nested_metadata.diagnostics.start);
    try std.testing.expectEqual(@as(u32, 1), nested_metadata.diagnostics.len);
    try std.testing.expectEqual(@as(u32, 1), nested_metadata.comments.len);
    try std.testing.expectEqual(@as(u32, 1), nested_metadata.tokens.start);
    session.leaveRange(&saved);
    try std.testing.expectEqualDeep(before.current_token, session.current_token);
    try std.testing.expectEqual(before.prev_token_end, session.prev_token_end);
    try std.testing.expectEqualDeep(before.context, session.context);
    try std.testing.expectEqualDeep(before.ts_context, session.ts_context);
    session.rewind(before);
    try std.testing.expectEqualDeep(outer_metadata, session.metadata());
    try std.testing.expectEqual(@as(usize, 1), tree.diagnostics.items.len);
    try std.testing.expectEqual(.identifier_reference, std.meta.activeTag(tree.data(root)));
}

test "document finalization orders metadata and attaches comments to assembled roots" {
    const source = "/*first*/ alpha} /*second*/ beta}";
    const boundary: u32 = @intCast(std.mem.findScalar(u8, source, '}').?);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = ast.Tree.initInArena(arena.allocator(), source);
    var roots: [2]ast.NodeIndex = undefined;
    for ([_]u32{ boundary + 1, 0 }, 0..) |start, index| {
        var session: parser.Parser = undefined;
        try session.initInTree(&tree, .{ .tokens = true }, .{
            .start = start,
            .end = @intCast(source.len),
        });
        defer session.deinit();
        roots[1 - index] = try session.parseDelimitedExpression(&.{
            .start = start,
            .terminator = .right_brace,
        });
        _ = try session.finish(roots[1 - index]);
    }
    var statements: [2]ast.NodeIndex = undefined;
    for (roots, &statements) |root, *statement| {
        statement.* = try tree.addNode(
            .{ .expression_statement = .{ .expression = root } },
            tree.span(root),
        );
    }
    const program = try tree.addNode(.{ .program = .{
        .source_type = .module,
        .body = try tree.addExtra(&statements),
        .hashbang = null,
    } }, .{ .start = 0, .end = @intCast(source.len) });
    try tree.finalize(program, .{ .attach_comments = true });
    try std.testing.expect(!tree.hasErrors());
    try std.testing.expectEqualStrings("first", tree.string(tree.comments[0].value));
    try std.testing.expectEqualStrings("second", tree.string(tree.comments[1].value));
    try std.testing.expectEqualStrings("alpha", tree.tokens[0].text(source));
    try std.testing.expectEqualStrings("beta", tree.tokens[1].text(source));
    try std.testing.expect(tree.hasComments(statements[0]));
    try std.testing.expect(tree.hasComments(statements[1]));
    _ = try parser.semantic.analyze(&tree, .{ .check = true });
    try std.testing.expect(!tree.hasErrors());
}

test "nested source types preserve CommonJS return and restore module await" {
    const source = "await value}return value;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = ast.Tree.initInArena(arena.allocator(), source);
    var session: parser.Parser = undefined;
    try session.initInTree(&tree, .{}, .{ .start = 0, .end = @intCast(source.len) });
    defer session.deinit();
    try std.testing.expect(session.context.await);
    try std.testing.expect(!session.context.@"return");
    const saved = try session.enterRange(.{ .start = 12, .end = @intCast(source.len) }, .{
        .source_type = .commonjs,
    });
    try std.testing.expect(session.context.@"return");
    try std.testing.expect(!session.context.await);
    const program = try session.parseProgramNode();
    try std.testing.expectEqual(.script, tree.data(program).program.source_type);
    session.leaveRange(&saved);
    try std.testing.expect(session.context.await);
    try std.testing.expect(!session.context.@"return");
    try std.testing.expectEqual(.module, session.source_type);
    try std.testing.expectEqual(.module, session.lexer.source_type);
    const expression = try session.parseDelimitedExpression(&.{ .terminator = .right_brace });
    try std.testing.expectEqual(.await_expression, std.meta.activeTag(tree.data(expression)));
    try std.testing.expect(!tree.hasErrors());
}

test "public program ranges preserve the enclosing token and module bindings" {
    const source = "outer}import value from 'mod'; export const next = await value(); return next;";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = ast.Tree.initInArena(arena.allocator(), source);
    var session: parser.Parser = undefined;
    try session.initInTree(&tree, .{}, .{ .start = 0, .end = @intCast(source.len) });
    defer session.deinit();
    var facade: parser.dialect.Parser = .{ .inner = &session };
    const before = facade.token();
    var options = facade.parseOptions();
    options.allow_return_outside_function = true;
    const result = try facade.parseProgramRange(.{ .start = 6, .end = source.len }, options);
    try std.testing.expectEqualDeep(before, facade.token());
    try std.testing.expectEqual(.eof, result.next.tag);
    try std.testing.expectEqual(@as(u32, 0), result.metadata.diagnostics.len);
    try std.testing.expectEqual(.module, tree.data(result.root).program.source_type);
    const body = tree.extra(tree.data(result.root).program.body);
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expect(tree.data(body[0]) == .import_declaration);
    try std.testing.expect(tree.data(body[1]) == .export_named_declaration);
    try std.testing.expect(tree.data(body[2]) == .return_statement);
    _ = try session.finish(result.root);
    try tree.finalize(result.root, .{ .attach_comments = false });
    _ = try parser.semantic.analyze(&tree, .{ .check = true });
    try std.testing.expect(!tree.hasErrors());
}
