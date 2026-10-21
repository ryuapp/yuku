const parser = @import("parser.zig");

pub const parse = parser.parse;
pub const parseProgramRange = parser.parseProgramRange;
pub const parseExpression = parser.parseExpression;
pub const ExpressionOptions = parser.ExpressionOptions;
pub const ExpressionResult = parser.ExpressionResult;
pub const Parser = parser.Parser;
pub const Context = parser.Context;
pub const TsContext = parser.TsContext;
pub const Checkpoint = parser.Checkpoint;
pub const RangeState = parser.RangeState;
pub const Metadata = parser.Metadata;
pub const RangeResult = parser.RangeResult;
pub const LexerMode = @import("lexer.zig").LexerMode;
pub const Precedence = @import("token.zig").Precedence;
pub const Options = parser.Options;
pub const CommentMode = parser.CommentMode;

pub const ast = @import("ast.zig");
pub const lexical = @import("lexical.zig");

pub const dialect = @import("dialect/root.zig");

pub const traverser = @import("traverser/root.zig");
pub const semantic = @import("semantic/root.zig");
pub const codegen = @import("codegen/root.zig");

test {
    _ = ast;
    _ = lexical;
    _ = codegen;
}
