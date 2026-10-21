const std = @import("std");
const Token = @import("token.zig").Token;
const TokenTag = @import("token.zig").TokenTag;
const flagMask = @import("token.zig").flagMask;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const util = @import("util");

const statements = @import("syntax/statements.zig");
const expressions = @import("syntax/expressions.zig");
const Precedence = @import("token.zig").Precedence;
const grammar = @import("grammar.zig");
const dialect = @import("dialect.zig");
const comments = @import("comments.zig");

/// How comments are collected and attached to their nodes.
pub const CommentMode = enum { none, collect, attach };

pub const Options = struct {
    /// How the source is parsed. `.commonjs` treats the top level as a function body.
    source_type: ast.SourceType = .module,
    /// Language variant that decides which syntax features are enabled.
    lang: ast.Lang = .js,
    /// Whether parenthesized expressions are kept as `ParenthesizedExpression` nodes.
    preserve_parens: bool = true,
    /// Whether comments are collected, and attached to their nodes.
    comments: CommentMode = .collect,
    /// Whether to keep every consumed token in `Tree.tokens`.
    tokens: bool = false,
    allow_return_outside_function: bool = false,
    /// Whether the dialect compiled into the parser reads this source.
    dialect: bool = false,
};

pub const ExpressionOptions = struct {
    options: Options = .{},
    start: u32 = 0,
    end: ?u32 = null,
    terminator: ?TokenTag = null,
    allow_empty: bool = false,
    allow_in: bool = true,
    min_precedence: u8 = Precedence.Lowest,
    context: ?Context = null,
};

pub const ExpressionResult = struct {
    tree: ast.Tree,
    end: u32,
    next: Token,
};

pub const Metadata = struct {
    diagnostics: ast.IndexRange,
    comments: ast.IndexRange,
    tokens: ast.IndexRange,
};

pub const RangeResult = struct {
    root: ast.NodeIndex,
    end: u32,
    next: Token,
    metadata: Metadata,
};

pub const Context = packed struct {
    /// `[Yield]`
    yield: bool = false,
    /// `[Await]`
    await: bool = false,
    /// `[Return]`
    @"return": bool = false,
    /// Body of `if`, `do`, `while`, `for`, `with`, or a labelled statement, where lexical
    /// declarations need a block.
    single_statement: bool = false,
    /// Inside a directive prologue.
    directive_prologue: bool = false,
};

pub const TsContext = packed struct {
    /// Inside a `declare`-prefixed declaration or a `.d.ts` file, where nested declarations
    /// inherit ambient rules.
    ambient: bool = false,
    /// A trailing `?` after a type does not start a new conditional.
    disallow_conditional_types: bool = false,
    /// Whether a speculatively parsed arrow may carry a return type. Cleared only while a
    /// conditional expression re-parses its consequent after a `(x): T => ...` arrow ate
    /// the ternary `:`.
    allow_arrow_return_type: bool = true,
};

const ParserState = struct {
    // `{ a = 1 }` defaults not yet part of a pattern, any left at the end are errors
    cover_init_names: u32 = 0,
    // `(a) = b` is legal, but the same node is a syntax error in binding position
    stripped_paren: ?ast.NodeIndex = null,
};

pub const RangeState = struct {
    source_end: u32,
    cursor: u32,
    lexer_state: lexer.LexerState,
    mode: lexer.LexerMode,
    hashbang: @FieldType(lexer.Lexer, "hashbang"),
    range_start: u32,
    range_depth: u16,
    source_type: ast.SourceType,
    metadata_start: Metadata,
    rejected_speculations: std.AutoHashMapUnmanaged(u32, void),
    current_token: Token,
    prev_token_end: u32,
    lang: ast.Lang,
    allow_return: bool,
    context: Context,
    ts_context: TsContext,
    state: ParserState,
};

pub const Error = error{OutOfMemory};

pub const Parser = struct {
    tree: *ast.Tree = undefined,
    owned_tree: ast.Tree = undefined,
    owns_tree: bool = false,
    source: []const u8,
    source_type: ast.SourceType,
    lang: ast.Lang,
    preserve_parens: bool,
    comment_mode: CommentMode,
    collect_tokens: bool,
    allow_return_outside_function: bool,
    initialized: bool = false,
    range_start: u32 = 0,
    has_ranges: bool = false,
    range_depth: u16 = 0,
    metadata_start: Metadata = .{
        .diagnostics = .empty,
        .comments = .empty,
        .tokens = .empty,
    },
    range_caches: std.ArrayList(std.AutoHashMapUnmanaged(u32, void)) = .empty,
    dialect: bool,
    lexer: lexer.Lexer,
    diagnostics: *std.ArrayList(ast.Diagnostic) = undefined,
    tokens: *std.ArrayList(Token) = undefined,

    current_token: Token,
    // spans must stop at a consumed delimiter, not at the next token past trivia
    prev_token_end: u32 = 0,

    scratch_statements: ScratchBuffer = .{},
    scratch_cover: ScratchBuffer = .{},
    scratch_decorators: ScratchBuffer = .{},

    scratch_a: ScratchBuffer = .{},
    scratch_b: ScratchBuffer = .{},

    context: Context = .{},
    ts_context: TsContext = .{},
    state: ParserState = .{},

    // token offsets whose speculation failed, so a rewinding ancestor never re-parses them
    ts_rejected_speculations: std.AutoHashMapUnmanaged(u32, void) = .empty,

    const range_depth_max: u16 = 128;

    pub fn init(
        self: *Parser,
        child_allocator: std.mem.Allocator,
        source: []const u8,
        options: Options,
    ) void {
        self.initOptions(source, options);
        self.owned_tree = ast.Tree.init(child_allocator, source);
        self.owned_tree.source_type = options.source_type;
        self.owned_tree.lang = options.lang;
        self.owns_tree = true;
        self.bindTree();
        std.debug.assert(self.tree == &self.owned_tree);
        std.debug.assert(self.owns_tree);
    }

    fn initOptions(self: *Parser, source: []const u8, options: Options) void {
        std.debug.assert(source.len <= std.math.maxInt(u32));
        if (options.dialect) std.debug.assert(dialect.bound);
        self.* = .{
            .source = source,
            .source_type = options.source_type,
            .lang = options.lang,
            .preserve_parens = options.preserve_parens,
            .comment_mode = options.comments,
            .collect_tokens = options.tokens,
            .allow_return_outside_function = options.allow_return_outside_function,
            .dialect = options.dialect,
            .lexer = undefined,
            .current_token = Token.eof(0),
        };
        std.debug.assert(!self.initialized);
    }

    fn bindTree(self: *Parser) void {
        if (self.owns_tree) self.tree = &self.owned_tree;
        self.diagnostics = &self.tree.diagnostics;
        self.tokens = &self.tree.token_buffer;
    }

    pub fn initInTree(
        self: *Parser,
        tree: *ast.Tree,
        options: Options,
        range: ast.Span,
    ) Error!void {
        std.debug.assert(tree.arena == null);
        std.debug.assert(tree.borrowed_allocator != null);
        std.debug.assert(range.start <= range.end);
        std.debug.assert(range.end <= tree.source.len);
        std.debug.assert(options.preserve_parens);
        std.debug.assert(options.comments != .attach);
        self.initOptions(tree.source, options);
        self.tree = tree;
        self.bindTree();
        try self.initialize(range, range.end - range.start);
    }

    pub inline fn isTs(self: *const Parser) bool {
        return self.lang == .ts or self.lang == .tsx or self.lang == .dts;
    }

    pub inline fn isJsx(self: *const Parser) bool {
        return self.lang == .jsx or self.lang == .tsx;
    }

    pub inline fn isModule(self: *const Parser) bool {
        return self.source_type == .module;
    }

    pub inline fn allocator(self: *Parser) std.mem.Allocator {
        return self.tree.allocator();
    }

    pub fn initSession(
        self: *Parser,
        child_allocator: std.mem.Allocator,
        source: []const u8,
        options: Options,
        range: ast.Span,
    ) Error!void {
        std.debug.assert(range.start <= range.end);
        std.debug.assert(range.end <= source.len);
        self.init(child_allocator, source, options);
        errdefer self.tree.deinit();
        try self.initialize(range, range.end - range.start);
        std.debug.assert(self.initialized);
        std.debug.assert(self.current_token.span.end <= range.end);
    }

    pub fn deinit(self: *Parser) void {
        if (self.owns_tree) self.tree.deinit();
        self.initialized = false;
    }

    fn initialize(self: *Parser, range: ast.Span, capacity_source_bytes: u32) Error!void {
        std.debug.assert(!self.initialized);
        std.debug.assert(range.start <= range.end);
        std.debug.assert(range.end <= self.source.len);
        std.debug.assert(capacity_source_bytes <= range.end - range.start);
        self.metadata_start = self.metadataStart();
        self.lexer = lexer.Lexer.init(
            self.source[0..if (range.start == 0) range.end else 0],
            self.allocator(),
            self.source_type,
            self.comment_mode != .none,
        );
        self.lexer.source = self.source[0..range.end];
        if (range.start > 0) {
            self.lexer.cursor = range.start;
            self.lexer.hashbang = null;
        }
        self.range_start = range.start;
        self.prev_token_end = range.start;
        self.current_token = Token.eof(range.start);
        self.context.yield = false;
        self.context.await = self.isModule();
        self.context.@"return" = self.source_type == .commonjs or
            self.allow_return_outside_function;
        self.ts_context.ambient = self.lang == .dts;

        try self.advance() orelse {
            self.current_token = try self.recoverNextToken();
        };
        try self.ensureCapacity(capacity_source_bytes);
        self.initialized = true;
        std.debug.assert(self.lexer.cursor <= range.end);
        std.debug.assert(self.current_token.span.end <= range.end);
    }

    pub fn parseExpressionNode(self: *Parser, min_precedence: u8) Error!?ast.NodeIndex {
        std.debug.assert(self.initialized);
        std.debug.assert(min_precedence <= Precedence.Grouping);
        return expressions.parseExpression(self, min_precedence, .{});
    }

    pub fn enterRange(self: *Parser, range: ast.Span, options: Options) Error!RangeState {
        std.debug.assert(self.initialized);
        std.debug.assert(range.start <= range.end);
        std.debug.assert(range.end <= self.source.len);
        std.debug.assert(self.range_depth < range_depth_max);
        std.debug.assert(options.preserve_parens == self.preserve_parens);
        std.debug.assert(options.comments == self.comment_mode);
        std.debug.assert(options.tokens == self.collect_tokens);
        std.debug.assert(options.dialect == self.dialect);
        if (self.range_caches.items.len == self.range_depth) {
            try self.range_caches.append(self.allocator(), .empty);
        }
        const saved: RangeState = .{
            .source_end = @intCast(self.lexer.source.len),
            .cursor = self.lexer.cursor,
            .lexer_state = self.lexer.state,
            .mode = self.lexer.mode,
            .hashbang = self.lexer.hashbang,
            .range_start = self.range_start,
            .range_depth = self.range_depth,
            .source_type = self.source_type,
            .metadata_start = self.metadata_start,
            .rejected_speculations = self.ts_rejected_speculations,
            .current_token = self.current_token,
            .prev_token_end = self.prev_token_end,
            .lang = self.lang,
            .allow_return = self.allow_return_outside_function,
            .context = self.context,
            .ts_context = self.ts_context,
            .state = self.state,
        };
        self.ts_rejected_speculations = self.range_caches.items[self.range_depth];
        self.range_caches.items[self.range_depth] = .empty;
        self.ts_rejected_speculations.clearRetainingCapacity();
        self.range_depth += 1;
        self.has_ranges = true;
        self.metadata_start = self.metadataStart();
        self.lexer.source = self.source[0..range.end];
        self.lexer.cursor = range.start;
        self.lexer.state = .{};
        self.lexer.mode = .normal;
        self.lexer.hashbang = null;
        self.lexer.source_type = options.source_type;
        self.range_start = range.start;
        self.prev_token_end = range.start;
        self.current_token = Token.eof(range.start);
        self.lang = options.lang;
        self.source_type = options.source_type;
        self.allow_return_outside_function = options.allow_return_outside_function;
        self.context = .{
            .await = self.isModule(),
            .@"return" = self.source_type == .commonjs or self.allow_return_outside_function,
        };
        self.ts_context = .{ .ambient = self.lang == .dts };
        self.state = .{};
        errdefer self.leaveRange(&saved);
        if (!try self.nextTokenInto(&self.current_token)) {
            self.current_token = try self.recoverNextToken();
        }
        std.debug.assert(self.current_token.span.end <= range.end);
        return saved;
    }

    pub fn leaveRange(self: *Parser, saved: *const RangeState) void {
        std.debug.assert(self.initialized);
        std.debug.assert(saved.source_end <= self.source.len);
        std.debug.assert(self.range_depth == saved.range_depth + 1);
        self.range_caches.items[saved.range_depth] = self.ts_rejected_speculations;
        self.ts_rejected_speculations = saved.rejected_speculations;
        self.range_depth = saved.range_depth;
        self.metadata_start = saved.metadata_start;
        self.source_type = saved.source_type;
        self.lexer.source = self.source[0..saved.source_end];
        self.lexer.cursor = saved.cursor;
        self.lexer.state = saved.lexer_state;
        self.lexer.mode = saved.mode;
        self.lexer.hashbang = saved.hashbang;
        self.lexer.source_type = saved.source_type;
        self.range_start = saved.range_start;
        self.current_token = saved.current_token;
        self.prev_token_end = saved.prev_token_end;
        self.lang = saved.lang;
        self.allow_return_outside_function = saved.allow_return;
        self.context = saved.context;
        self.ts_context = saved.ts_context;
        self.state = saved.state;
    }

    pub fn metadata(self: *const Parser) Metadata {
        const comments_len = if (self.initialized) self.lexer.comments.items.len else 0;
        std.debug.assert(self.metadata_start.diagnostics.start <= self.diagnostics.items.len);
        std.debug.assert(self.metadata_start.tokens.start <= self.tokens.items.len);
        return .{
            .diagnostics = metadataRange(
                self.metadata_start.diagnostics.start,
                self.diagnostics.items.len,
            ),
            .comments = metadataRange(self.metadata_start.comments.start, comments_len),
            .tokens = metadataRange(self.metadata_start.tokens.start, self.tokens.items.len),
        };
    }

    fn metadataStart(self: *const Parser) Metadata {
        const comments_len = if (self.initialized) self.lexer.comments.items.len else 0;
        std.debug.assert(self.diagnostics.items.len <= std.math.maxInt(u32));
        std.debug.assert(self.tokens.items.len <= std.math.maxInt(u32));
        return .{
            .diagnostics = metadataRange(
                @intCast(self.diagnostics.items.len),
                self.diagnostics.items.len,
            ),
            .comments = metadataRange(@intCast(comments_len), comments_len),
            .tokens = metadataRange(@intCast(self.tokens.items.len), self.tokens.items.len),
        };
    }

    pub fn parseProgramNode(self: *Parser) Error!ast.NodeIndex {
        std.debug.assert(self.initialized);
        const body = try self.parseBody(null, .program);
        if (self.state.cover_init_names > 0) try grammar.reportCoverInitializedNames(self);
        std.debug.assert(self.current_token.tag == .eof);
        if (self.collect_tokens) try self.tokens.append(self.allocator(), self.current_token);
        return self.tree.addNode(.{ .program = .{
            .source_type = if (self.source_type == .module) .module else .script,
            .body = body,
            .hashbang = if (self.lexer.hashbang) |hashbang| .{
                .value = self.tree.sourceSlice(hashbang.start, hashbang.start + hashbang.len),
            } else null,
        } }, .{ .start = self.range_start, .end = self.current_token.span.end });
    }

    pub fn parseDelimitedExpression(
        self: *Parser,
        options: *const ExpressionOptions,
    ) Error!ast.NodeIndex {
        std.debug.assert(self.initialized);
        std.debug.assert(options.start == self.range_start);
        if (options.end) |end| std.debug.assert(end == self.lexer.source.len);
        if (options.context) |context| self.context = context;
        var root: ast.NodeIndex = .null;
        if (self.current_token.tag != (options.terminator orelse .eof) or !options.allow_empty) {
            root = try expressions.parseExpression(self, options.min_precedence, .{
                .allow_in = options.allow_in,
            }) orelse .null;
        }
        if (self.state.cover_init_names > 0) try grammar.reportCoverInitializedNames(self);
        if (self.current_token.tag != (options.terminator orelse .eof)) {
            try self.reportExpected(self.current_token.span, "Expected expression delimiter", .{});
        }
        if (root != .null) std.debug.assert(@backingInt(root) < self.tree.nodes.len);
        return root;
    }

    pub fn finish(self: *Parser, root: ast.NodeIndex) Error!ast.Tree {
        std.debug.assert(self.initialized);
        if (root != .null) std.debug.assert(@backingInt(root) < self.tree.nodes.len);
        if (self.owns_tree) self.tree.root = root;
        if (!self.preserve_parens) stripParenthesizedNodes(self.tree);
        if (self.comment_mode != .none) {
            if (self.owns_tree) {
                self.tree.comments = self.lexer.comments.items;
            } else {
                try self.tree.flat_comments.appendSlice(
                    self.allocator(),
                    self.lexer.comments.items,
                );
                self.tree.comments = self.tree.flat_comments.items;
            }
        }
        if (self.collect_tokens) {
            if (self.tokens.items.len == 0 or
                self.tokens.items[self.tokens.items.len - 1].tag != .eof)
            {
                try self.tokens.append(self.allocator(), Token.eof(@intCast(self.lexer.source.len)));
            }
            self.tree.tokens = self.tokens.items;
        }
        if (self.owns_tree) {
            if (self.has_ranges) {
                try self.tree.finalize(root, .{ .attach_comments = false });
            }
        }
        if (self.comment_mode == .attach) {
            if (root != .null) try comments.attach(self.tree, self.lexer.comments.items);
        }
        self.initialized = false;
        var result = self.tree.*;
        result.root = root;
        result.lang = self.lang;
        result.source_type = self.source_type;
        self.owns_tree = false;
        return result;
    }

    pub fn parse(self: *Parser) Error!ast.Tree {
        return self.parseInner();
    }

    fn parseInner(self: *Parser) Error!ast.Tree {
        if (!self.initialized) self.bindTree();
        errdefer self.deinit();

        if (!self.initialized) {
            const source_len: u32 = @intCast(self.source.len);
            try self.initialize(.{ .start = 0, .end = source_len }, source_len);
        }

        const root = try self.parseProgramNode();
        return self.finish(root);
    }

    inline fn commitToken(self: *Parser, token: Token) Error!void {
        if (!self.collect_tokens) return;
        // the initial placeholder or an empty jsx text run
        if (token.span.start == token.span.end) return;
        if (self.tokens.items.len < self.tokens.capacity) {
            self.tokens.appendAssumeCapacity(token);
        } else {
            try self.tokens.append(self.allocator(), token);
        }
    }

    pub const BodyKind = enum { program, function, module_block, other };

    pub fn parseBody(self: *Parser, terminator: ?TokenTag, kind: BodyKind) Error!ast.IndexRange {
        self.context.directive_prologue = kind != .other;
        defer self.context.directive_prologue = false;

        const statements_checkpoint = self.scratch_statements.begin();
        defer self.scratch_statements.reset(statements_checkpoint);

        while (self.current_token.tag != .eof and self.current_token.tag != terminator) {
            if (try statements.parseStatement(self, .{ .body = kind })) |statement| {
                try self.scratch_statements.append(self.allocator(), statement);
            } else {
                try self.recover(terminator);
            }
        }

        return self.flushToExtras(&self.scratch_statements, statements_checkpoint);
    }

    /// Returns the resolved name of an identifier-like token, without a private `#` and
    /// with escapes decoded.
    pub inline fn identifierName(self: *Parser, token: Token) Error!ast.String {
        const is_private = token.tag == .private_identifier;
        const start = token.span.start + @as(u32, @intFromBool(is_private));
        if (token.isEscaped()) return self.decodeEscapedIdentifier(start, token.span.end);
        return self.tree.sourceSlice(start, token.span.end);
    }

    /// Returns the escape-decoded text of a string or template element, without its delimiters.
    pub inline fn stringValue(self: *Parser, token: Token, span: ast.Span) Error!ast.String {
        if (!token.isEscaped()) return self.tree.sourceSlice(span.start, span.end);
        return self.decode(util.Utf.decodeStringEscapes, span.start, span.end);
    }

    /// Returns the inside of a JSX attribute string with its entities decoded.
    pub inline fn jsxValue(self: *Parser, start: u32, end: u32) Error!ast.String {
        if (std.mem.findScalar(u8, self.source[start..end], '&') == null) {
            return self.tree.sourceSlice(start, end);
        }
        return self.decode(util.Utf.decodeJSXEntities, start, end);
    }

    fn decodeEscapedIdentifier(self: *Parser, start: u32, end: u32) Error!ast.String {
        @branchHint(.cold);
        var buf: [256]u8 = undefined;
        return try self.tree.addString(
            util.Utf.decodeIdentifierEscapes(self.source[start..end], &buf),
        );
    }

    fn decode(self: *Parser, comptime decoder: anytype, start: u32, end: u32) Error!ast.String {
        @branchHint(.cold);
        const alloc = self.allocator();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try decoder(alloc, self.source[start..end], &buf);
        return try self.tree.addString(buf.items);
    }

    pub inline fn describeToken(self: *Parser, token: Token) []const u8 {
        if (token.tag == .eof) return "end of file";
        return token.tag.toString() orelse token.text(self.source);
    }

    pub inline fn setLexerMode(self: *Parser, mode: lexer.LexerMode) void {
        self.lexer.mode = mode;
    }

    pub fn flushToExtras(
        self: *Parser,
        scratch: *ScratchBuffer,
        scratch_checkpoint: usize,
    ) Error!ast.IndexRange {
        return self.tree.addExtra(scratch.items.items[scratch_checkpoint..]);
    }

    pub inline fn spanText(self: *const Parser, span: ast.Span) []const u8 {
        return self.source[span.start..span.end];
    }

    inline fn nextTokenInto(self: *Parser, out: *Token) Error!bool {
        self.lexer.nextTokenInto(out) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            try self.reportLexicalError(@errorCast(e));
            return false;
        };
        return true;
    }

    pub noinline fn reportLexicalError(self: *Parser, lex_err: lexer.LexicalError) Error!void {
        @branchHint(.cold);
        const cursor = self.lexer.cursor;
        try self.report(
            .{ .start = cursor, .end = @min(cursor +| 1, self.lexer.source.len) },
            lexer.getLexicalErrorMessage(lex_err),
            .{ .help = lexer.getLexicalErrorHelp(lex_err) },
        );
    }

    /// Advances to the next token, reporting an escaped keyword consumed in keyword position.
    pub fn advance(self: *Parser) Error!?void {
        const token = self.current_token;
        if (token.isEscaped()) {
            if (token.tag.isKeyword()) try self.reportEscapedKeyword(token.span);
        }
        return self.advanceWithoutEscapeCheck();
    }

    /// Advances without the escaped-keyword check.
    pub inline fn advanceWithoutEscapeCheck(self: *Parser) Error!?void {
        const leaving = self.current_token;
        self.prev_token_end = leaving.span.end;
        if (!self.lexer.tryNextToken(&self.current_token)) {
            if (!try self.nextTokenInto(&self.current_token)) return null;
        }
        try self.commitToken(leaving);
    }

    pub noinline fn reportEscapedKeyword(self: *Parser, span: ast.Span) Error!void {
        @branchHint(.cold);
        try self.report(span, "Keywords cannot contain escape characters", .{
            .help = "Remove the escape characters",
        });
    }

    /// Reports an escaped-keyword error for a token consumed before its role was known.
    pub inline fn reportIfEscapedKeyword(self: *Parser, token: Token) Error!void {
        if (token.isEscaped()) try self.reportEscapedKeyword(token.span);
    }

    /// Peeks the token after `current_token` without advancing. Use `beginPeek` for
    /// multi-token lookahead.
    pub inline fn peekAhead(self: *Parser) Token {
        var peek = self.beginPeek();
        defer peek.end();
        return peek.next();
    }

    /// Captures a snapshot of parser state for `rewind`.
    pub fn checkpoint(self: *const Parser) Checkpoint {
        return .{
            .lexer_cursor = self.lexer.cursor,
            .lexer_state = self.lexer.state,
            .lexer_mode = self.lexer.mode,
            .lexer_comments_len = self.lexer.comments.items.len,
            .flat_comments_len = self.tree.flat_comments.items.len,
            .current_token = self.current_token,
            .prev_token_end = self.prev_token_end,
            .nodes_len = self.tree.nodes.len,
            .extras_len = self.tree.extras.items.len,
            .diagnostics_len = self.diagnostics.items.len,
            .tokens_len = self.tokens.items.len,
            .context = self.context,
            .ts_context = self.ts_context,
            .state = self.state,
        };
    }

    /// Restores parser state captured by `checkpoint`.
    pub fn rewind(self: *Parser, cp: Checkpoint) void {
        std.debug.assert(cp.nodes_len <= self.tree.nodes.len);
        std.debug.assert(cp.extras_len <= self.tree.extras.items.len);
        self.lexer.cursor = cp.lexer_cursor;
        self.lexer.state = cp.lexer_state;
        self.lexer.mode = cp.lexer_mode;
        self.lexer.comments.shrinkRetainingCapacity(cp.lexer_comments_len);
        self.tree.flat_comments.shrinkRetainingCapacity(cp.flat_comments_len);
        self.current_token = cp.current_token;
        self.prev_token_end = cp.prev_token_end;
        self.tree.nodes.shrinkRetainingCapacity(cp.nodes_len);
        self.tree.extras.shrinkRetainingCapacity(cp.extras_len);
        self.diagnostics.shrinkRetainingCapacity(cp.diagnostics_len);
        self.tokens.shrinkRetainingCapacity(cp.tokens_len);
        if (!self.owns_tree) {
            self.tree.comments = self.tree.flat_comments.items;
            self.tree.tokens = self.tokens.items;
        }
        self.context = cp.context;
        self.ts_context = cp.ts_context;
        self.state = cp.state;
    }

    pub const Peek = struct {
        parser: *Parser,
        state: lexer.LexerState,
        cursor: u32,
        comments_len: usize,

        pub inline fn next(self: *Peek) Token {
            var token: Token = undefined;
            if (self.parser.lexer.tryNextToken(&token)) return token;
            return self.parser.lexer.nextToken() catch Token.invalid(self.parser.lexer.cursor);
        }

        pub inline fn end(self: Peek) void {
            self.parser.lexer.state = self.state;
            self.parser.lexer.cursor = self.cursor;
            self.parser.lexer.comments.shrinkRetainingCapacity(self.comments_len);
        }
    };

    pub inline fn beginPeek(self: *Parser) Peek {
        return .{
            .parser = self,
            .state = self.lexer.state,
            .cursor = self.lexer.cursor,
            .comments_len = self.lexer.comments.items.len,
        };
    }

    /// Replaces the current token with a re-scanned one and advances past it.
    pub inline fn advanceWithRescannedToken(self: *Parser, token: Token) Error!?void {
        var rescanned = token;
        // a rescan past the current token completes it, one inside it supersedes it
        if (token.span.start >= self.current_token.span.end) {
            try self.commitToken(self.current_token);
        } else {
            rescanned.flags |= newlineFlag(self.current_token);
        }
        self.current_token = rescanned;
        return self.advance();
    }

    /// Re-tokenizes the current token in the current lexer mode.
    pub inline fn reScanCurrent(self: *Parser) Error!?void {
        const replaced = self.current_token;
        self.lexer.rewindTo(replaced.span.start);
        if (!try self.nextTokenInto(&self.current_token)) return null;
        self.current_token.flags |= newlineFlag(replaced);
    }

    // a rescan starts at the token it replaces, past the trivia that set the flag
    inline fn newlineFlag(token: Token) u8 {
        return token.flags & flagMask(.line_terminator_before);
    }

    pub fn expect(
        self: *Parser,
        comptime tag: TokenTag,
        message: []const u8,
        help: ?[]const u8,
    ) Error!bool {
        if (self.current_token.tag == tag) {
            try self.advance() orelse return false;
            return true;
        }
        try self.reportExpected(self.current_token.span, message, .{ .help = help });
        return false;
    }

    pub fn eatSemicolon(self: *Parser, end: u32) Error!?u32 {
        if (self.current_token.tag == .semicolon) {
            const semicolon_end = self.current_token.span.end;
            try self.advance() orelse return null;
            return semicolon_end;
        }
        if (self.canInsertImplicitSemicolon(self.current_token)) return end;
        try self.reportExpected(
            self.current_token.span,
            "Expected a semicolon or an implicit semicolon after a statement",
            .{ .help = "Try inserting a semicolon here" },
        );
        return null;
    }

    /// https://tc39.es/ecma262/#sec-rules-of-automatic-semicolon-insertion
    pub inline fn canInsertImplicitSemicolon(_: *Parser, token: Token) bool {
        return token.tag == .eof or token.hasLineTerminatorBefore() or token.tag == .right_brace;
    }

    fn stripParenthesizedNodes(tree: *ast.Tree) void {
        const datas = tree.nodes.items(.data);
        const spans = tree.nodes.items(.span);
        for (0..datas.len) |i| {
            var inner: u32 = @intCast(i);
            while (true) {
                inner = switch (datas[inner]) {
                    .parenthesized_expression => |p| @backingInt(p.expression),
                    .ts_parenthesized_type => |p| @backingInt(p.type_annotation),
                    else => break,
                };
            }
            if (inner == i) continue;
            datas[i] = datas[inner];
            spans[i] = spans[inner];
        }
    }

    pub const ReportOptions = struct {
        severity: ast.Severity = .@"error",
        help: ?[]const u8 = null,
        labels: []const ast.Label = &.{},
    };

    pub fn report(
        self: *Parser,
        span: ast.Span,
        message: []const u8,
        opts: ReportOptions,
    ) Error!void {
        try self.diagnostics.append(self.allocator(), .{
            .severity = opts.severity,
            .message = message,
            .span = span,
            .help = opts.help,
            .labels = opts.labels,
        });
    }

    pub fn reportExpected(
        self: *Parser,
        span: ast.Span,
        message: []const u8,
        opts: ReportOptions,
    ) Error!void {
        const expected_message = try self.fmt("{s}, but found '{s}'", .{
            message,
            self.describeToken(self.current_token),
        });
        try self.report(span, expected_message, opts);
    }

    pub fn label(_: *Parser, span: ast.Span, message: []const u8) ast.Label {
        return .{ .span = span, .message = message };
    }

    pub fn labels(self: *Parser, items: []const ast.Label) Error![]const ast.Label {
        return try self.allocator().dupe(ast.Label, items);
    }

    pub fn fmt(self: *Parser, comptime format: []const u8, args: anytype) Error![]u8 {
        return self.allocator().print(format, args);
    }

    pub fn recover(self: *Parser, terminator: ?TokenTag) Error!void {
        while (self.current_token.tag != .eof) {
            // a failed rescan leaves the lexer inside the current token, which is then stale
            if (self.current_token.span.end <= self.lexer.cursor) {
                try self.commitToken(self.current_token);
            }
            self.current_token = try self.recoverNextToken();
            if (self.current_token.tag == terminator) break;
            if (self.current_token.hasLineTerminatorBefore() and
                self.current_token.tag.isKeyword()) break;
        }
    }

    fn recoverNextToken(self: *Parser) Error!Token {
        while (true) {
            return self.lexer.nextToken() catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                if (self.lexer.cursor < self.lexer.source.len) {
                    self.lexer.cursor += 1;
                } else {
                    return Token.eof(@intCast(self.lexer.source.len));
                }
                continue;
            };
        }
    }

    fn ensureCapacity(self: *Parser, source_bytes: u32) Error!void {
        const alloc = self.allocator();
        const source_len: usize = source_bytes;

        const estimated_nodes = if (source_len < 512_000)
            @max(256, source_len / 2)
        else
            source_len / 4;

        const estimated_extra = if (source_len < 512_000)
            source_len / 6
        else
            source_len / 12;

        const nodes_unused = @min(estimated_nodes, std.math.maxInt(u32) - self.tree.nodes.len);
        const extras_unused = @min(
            estimated_extra,
            std.math.maxInt(u32) - self.tree.extras.items.len,
        );
        try self.tree.nodes.ensureTotalCapacity(alloc, self.tree.nodes.len + nodes_unused);
        try self.tree.extras.ensureTotalCapacity(alloc, self.tree.extras.items.len + extras_unused);
        try self.scratch_cover.items.ensureTotalCapacity(alloc, 256);
        try self.scratch_statements.items.ensureTotalCapacity(alloc, 256);
        try self.scratch_a.items.ensureTotalCapacity(alloc, 256);
        try self.scratch_b.items.ensureTotalCapacity(alloc, 256);
        try self.scratch_decorators.items.ensureTotalCapacity(alloc, 128);
        if (self.collect_tokens) {
            try self.tokens.ensureTotalCapacity(alloc, @max(64, source_len / 3));
        }
    }
};

pub const Checkpoint = struct {
    lexer_cursor: u32,
    lexer_state: lexer.LexerState,
    lexer_mode: lexer.LexerMode,
    lexer_comments_len: usize,
    flat_comments_len: usize,

    current_token: Token,
    prev_token_end: u32,

    nodes_len: usize,
    extras_len: usize,
    diagnostics_len: usize,
    tokens_len: usize,

    context: Context,
    ts_context: TsContext,
    state: ParserState,
};

const ScratchBuffer = struct {
    items: std.ArrayList(ast.NodeIndex) = .empty,

    pub inline fn begin(self: *ScratchBuffer) usize {
        return self.items.items.len;
    }

    pub inline fn append(
        self: *ScratchBuffer,
        alloc: std.mem.Allocator,
        index: ast.NodeIndex,
    ) Error!void {
        if (self.items.items.len < self.items.capacity) {
            self.items.appendAssumeCapacity(index);
        } else {
            try self.items.append(alloc, index);
        }
    }

    pub inline fn reset(self: *ScratchBuffer, checkpoint: usize) void {
        self.items.shrinkRetainingCapacity(checkpoint);
    }
};

/// Parses JavaScript or TypeScript source into a `Tree`. Call `deinit()` to free it.
pub fn parse(
    child_allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) Error!ast.Tree {
    var parser: Parser = undefined;
    parser.init(child_allocator, source, options);
    return parser.parse();
}

pub fn parseProgramRange(
    child_allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
    range: ast.Span,
) Error!ast.Tree {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= source.len);
    var parser: Parser = undefined;
    try parser.initSession(child_allocator, source, options, range);
    return parser.parse();
}

pub fn parseExpression(
    child_allocator: std.mem.Allocator,
    source: []const u8,
    options: *const ExpressionOptions,
) Error!ExpressionResult {
    std.debug.assert(source.len <= std.math.maxInt(u32));
    const end = options.end orelse @as(u32, @intCast(source.len));
    std.debug.assert(options.start <= end);
    std.debug.assert(end <= source.len);
    var parser: Parser = undefined;
    parser.init(child_allocator, source, options.options);
    errdefer parser.deinit();
    try parser.initialize(.{
        .start = options.start,
        .end = end,
    }, @min(end - options.start, 512));
    if (options.context) |context| parser.context = context;

    var root: ast.NodeIndex = .null;
    const empty = parser.current_token.tag == (options.terminator orelse .eof);
    if (!empty or !options.allow_empty) {
        root = try expressions.parseExpression(&parser, options.min_precedence, .{
            .allow_in = options.allow_in,
        }) orelse .null;
    }
    if (parser.state.cover_init_names > 0) try grammar.reportCoverInitializedNames(&parser);
    if (options.terminator) |terminator| {
        if (parser.current_token.tag != terminator) {
            try parser.reportExpected(
                parser.current_token.span,
                "Expected expression delimiter",
                .{},
            );
        }
    } else {
        if (parser.current_token.tag != .eof) {
            try parser.reportExpected(parser.current_token.span, "Expected end of expression", .{});
        }
    }
    const consumed_end = parser.prev_token_end;
    const next = parser.current_token;
    const tree = try parser.finish(root);
    std.debug.assert(consumed_end >= options.start);
    std.debug.assert(next.span.end <= end);
    return .{ .tree = tree, .end = consumed_end, .next = next };
}

fn metadataRange(start: u32, end: usize) ast.IndexRange {
    std.debug.assert(start <= end);
    std.debug.assert(end <= std.math.maxInt(u32));
    return .{ .start = start, .len = @intCast(end - start) };
}
