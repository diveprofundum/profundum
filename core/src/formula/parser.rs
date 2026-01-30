use nom::{
    branch::alt,
    bytes::complete::{tag, tag_no_case, take_while1},
    character::complete::{char, multispace0},
    combinator::{map, opt, recognize, value},
    multi::separated_list0,
    number::complete::recognize_float,
    sequence::{delimited, pair, tuple},
    IResult,
};

use crate::error::FormulaError;
use crate::formula::ast::{BinaryOp, Expr, UnaryOp};

/// Parse a formula expression string into an AST.
pub fn parse(input: &str) -> Result<Expr, FormulaError> {
    let input = input.trim();
    if input.is_empty() {
        return Err(FormulaError::EmptyExpression);
    }

    match parse_expr(input) {
        Ok((remaining, expr)) => {
            let remaining = remaining.trim();
            if remaining.is_empty() {
                Ok(expr)
            } else {
                Err(FormulaError::ParseError {
                    position: input.len() - remaining.len(),
                    message: format!("unexpected characters: '{}'", remaining),
                })
            }
        }
        Err(e) => Err(FormulaError::ParseError {
            position: 0,
            message: format!("parse error: {:?}", e),
        }),
    }
}

fn ws<'a, F, O>(inner: F) -> impl FnMut(&'a str) -> IResult<&'a str, O>
where
    F: FnMut(&'a str) -> IResult<&'a str, O>,
{
    delimited(multispace0, inner, multispace0)
}

fn parse_expr(input: &str) -> IResult<&str, Expr> {
    parse_ternary(input)
}

fn parse_ternary(input: &str) -> IResult<&str, Expr> {
    let (input, condition) = parse_or(input)?;
    let (input, _) = multispace0(input)?;

    if let Ok((input, _)) = char::<&str, nom::error::Error<&str>>('?')(input) {
        let (input, _) = multispace0(input)?;
        let (input, then_expr) = parse_expr(input)?;
        let (input, _) = multispace0(input)?;
        let (input, _) = char(':')(input)?;
        let (input, _) = multispace0(input)?;
        let (input, else_expr) = parse_expr(input)?;
        Ok((input, Expr::ternary(condition, then_expr, else_expr)))
    } else {
        Ok((input, condition))
    }
}

fn parse_or(input: &str) -> IResult<&str, Expr> {
    let (input, left) = parse_and(input)?;
    parse_binary_chain(input, left, parse_or_op, parse_and)
}

fn parse_or_op(input: &str) -> IResult<&str, BinaryOp> {
    ws(value(BinaryOp::Or, tag_no_case("or")))(input)
}

fn parse_and(input: &str) -> IResult<&str, Expr> {
    let (input, left) = parse_comparison(input)?;
    parse_binary_chain(input, left, parse_and_op, parse_comparison)
}

fn parse_and_op(input: &str) -> IResult<&str, BinaryOp> {
    ws(value(BinaryOp::And, tag_no_case("and")))(input)
}

fn parse_comparison(input: &str) -> IResult<&str, Expr> {
    let (input, left) = parse_additive(input)?;
    parse_binary_chain(input, left, parse_comparison_op, parse_additive)
}

fn parse_comparison_op(input: &str) -> IResult<&str, BinaryOp> {
    ws(alt((
        value(BinaryOp::Gte, tag(">=")),
        value(BinaryOp::Lte, tag("<=")),
        value(BinaryOp::Eq, tag("==")),
        value(BinaryOp::Neq, tag("!=")),
        value(BinaryOp::Gt, tag(">")),
        value(BinaryOp::Lt, tag("<")),
    )))(input)
}

fn parse_additive(input: &str) -> IResult<&str, Expr> {
    let (input, left) = parse_multiplicative(input)?;
    parse_binary_chain(input, left, parse_additive_op, parse_multiplicative)
}

fn parse_additive_op(input: &str) -> IResult<&str, BinaryOp> {
    ws(alt((
        value(BinaryOp::Add, char('+')),
        value(BinaryOp::Sub, char('-')),
    )))(input)
}

fn parse_multiplicative(input: &str) -> IResult<&str, Expr> {
    let (input, left) = parse_unary(input)?;
    parse_binary_chain(input, left, parse_multiplicative_op, parse_unary)
}

fn parse_multiplicative_op(input: &str) -> IResult<&str, BinaryOp> {
    ws(alt((
        value(BinaryOp::Mul, char('*')),
        value(BinaryOp::Div, char('/')),
    )))(input)
}

fn parse_binary_chain<'a, F, G>(
    mut input: &'a str,
    mut left: Expr,
    mut op_parser: F,
    mut expr_parser: G,
) -> IResult<&'a str, Expr>
where
    F: FnMut(&'a str) -> IResult<&'a str, BinaryOp>,
    G: FnMut(&'a str) -> IResult<&'a str, Expr>,
{
    loop {
        match op_parser(input) {
            Ok((remaining, op)) => {
                let (remaining, right) = expr_parser(remaining)?;
                left = Expr::binary(op, left, right);
                input = remaining;
            }
            Err(_) => return Ok((input, left)),
        }
    }
}

fn parse_unary(input: &str) -> IResult<&str, Expr> {
    let (input, _) = multispace0(input)?;

    // Try negation
    if let Ok((input, _)) = char::<&str, nom::error::Error<&str>>('-')(input) {
        let (input, _) = multispace0(input)?;
        let (input, expr) = parse_unary(input)?;
        return Ok((input, Expr::unary(UnaryOp::Neg, expr)));
    }

    // Try 'not'
    if let Ok((input, _)) = tag_no_case::<&str, &str, nom::error::Error<&str>>("not")(input) {
        let (input, _) = multispace0(input)?;
        let (input, expr) = parse_unary(input)?;
        return Ok((input, Expr::unary(UnaryOp::Not, expr)));
    }

    parse_primary(input)
}

fn parse_primary(input: &str) -> IResult<&str, Expr> {
    let (input, _) = multispace0(input)?;

    alt((
        parse_parenthesized,
        parse_boolean,
        parse_function_call,
        parse_number,
        parse_variable,
    ))(input)
}

fn parse_parenthesized(input: &str) -> IResult<&str, Expr> {
    delimited(
        pair(char('('), multispace0),
        parse_expr,
        pair(multispace0, char(')')),
    )(input)
}

fn parse_boolean(input: &str) -> IResult<&str, Expr> {
    alt((
        value(Expr::Boolean(true), tag_no_case("true")),
        value(Expr::Boolean(false), tag_no_case("false")),
    ))(input)
}

fn parse_number(input: &str) -> IResult<&str, Expr> {
    map(recognize_float, |s: &str| {
        Expr::Number(s.parse().unwrap_or(0.0))
    })(input)
}

fn parse_variable(input: &str) -> IResult<&str, Expr> {
    map(
        recognize(pair(
            take_while1(|c: char| c.is_alphabetic() || c == '_'),
            opt(take_while1(|c: char| c.is_alphanumeric() || c == '_')),
        )),
        |s: &str| Expr::Variable(s.to_string()),
    )(input)
}

fn parse_function_call(input: &str) -> IResult<&str, Expr> {
    let (input, name) = recognize(pair(
        take_while1(|c: char| c.is_alphabetic() || c == '_'),
        opt(take_while1(|c: char| c.is_alphanumeric() || c == '_')),
    ))(input)?;

    // Must have opening parenthesis immediately after name (with optional whitespace)
    let (input, _) = multispace0(input)?;
    let (input, _) = char('(')(input)?;
    let (input, _) = multispace0(input)?;

    let (input, args) =
        separated_list0(tuple((multispace0, char(','), multispace0)), parse_expr)(input)?;

    let (input, _) = multispace0(input)?;
    let (input, _) = char(')')(input)?;

    Ok((input, Expr::function_call(name, args)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_number() {
        let expr = parse("42").unwrap();
        assert!(matches!(expr, Expr::Number(n) if (n - 42.0).abs() < f64::EPSILON));

        let expr = parse("3.5").unwrap();
        assert!(matches!(expr, Expr::Number(n) if (n - 3.5).abs() < f64::EPSILON));

        let expr = parse("-5").unwrap();
        assert!(matches!(
            expr,
            Expr::Unary {
                op: UnaryOp::Neg,
                ..
            }
        ));
    }

    #[test]
    fn test_parse_variable() {
        let expr = parse("max_depth_m").unwrap();
        assert!(matches!(expr, Expr::Variable(ref s) if s == "max_depth_m"));

        let expr = parse("x").unwrap();
        assert!(matches!(expr, Expr::Variable(ref s) if s == "x"));
    }

    #[test]
    fn test_parse_boolean() {
        let expr = parse("true").unwrap();
        assert!(matches!(expr, Expr::Boolean(true)));

        let expr = parse("FALSE").unwrap();
        assert!(matches!(expr, Expr::Boolean(false)));
    }

    #[test]
    fn test_parse_binary_ops() {
        let expr = parse("1 + 2").unwrap();
        assert!(matches!(
            expr,
            Expr::Binary {
                op: BinaryOp::Add,
                ..
            }
        ));

        let expr = parse("a - b").unwrap();
        assert!(matches!(
            expr,
            Expr::Binary {
                op: BinaryOp::Sub,
                ..
            }
        ));

        let expr = parse("x * y").unwrap();
        assert!(matches!(
            expr,
            Expr::Binary {
                op: BinaryOp::Mul,
                ..
            }
        ));

        let expr = parse("a / b").unwrap();
        assert!(matches!(
            expr,
            Expr::Binary {
                op: BinaryOp::Div,
                ..
            }
        ));
    }

    #[test]
    fn test_parse_comparison_ops() {
        let expr = parse("a > b").unwrap();
        assert!(matches!(
            expr,
            Expr::Binary {
                op: BinaryOp::Gt,
                ..
            }
        ));

        let expr = parse("a >= b").unwrap();
        assert!(matches!(
            expr,
            Expr::Binary {
                op: BinaryOp::Gte,
                ..
            }
        ));

        let expr = parse("a == b").unwrap();
        assert!(matches!(
            expr,
            Expr::Binary {
                op: BinaryOp::Eq,
                ..
            }
        ));

        let expr = parse("a != b").unwrap();
        assert!(matches!(
            expr,
            Expr::Binary {
                op: BinaryOp::Neq,
                ..
            }
        ));
    }

    #[test]
    fn test_parse_logical_ops() {
        let expr = parse("a and b").unwrap();
        assert!(matches!(
            expr,
            Expr::Binary {
                op: BinaryOp::And,
                ..
            }
        ));

        let expr = parse("a or b").unwrap();
        assert!(matches!(
            expr,
            Expr::Binary {
                op: BinaryOp::Or,
                ..
            }
        ));

        let expr = parse("not x").unwrap();
        assert!(matches!(
            expr,
            Expr::Unary {
                op: UnaryOp::Not,
                ..
            }
        ));
    }

    #[test]
    fn test_parse_precedence() {
        // Multiplication binds tighter than addition
        let expr = parse("1 + 2 * 3").unwrap();
        if let Expr::Binary { op, left, right } = expr {
            assert_eq!(op, BinaryOp::Add);
            assert!(matches!(*left, Expr::Number(_)));
            assert!(matches!(
                *right,
                Expr::Binary {
                    op: BinaryOp::Mul,
                    ..
                }
            ));
        } else {
            panic!("Expected binary expression");
        }
    }

    #[test]
    fn test_parse_parentheses() {
        let expr = parse("(1 + 2) * 3").unwrap();
        if let Expr::Binary { op, left, .. } = expr {
            assert_eq!(op, BinaryOp::Mul);
            assert!(matches!(
                *left,
                Expr::Binary {
                    op: BinaryOp::Add,
                    ..
                }
            ));
        } else {
            panic!("Expected binary expression");
        }
    }

    #[test]
    fn test_parse_function_call() {
        let expr = parse("min(a, b)").unwrap();
        if let Expr::FunctionCall { name, args } = expr {
            assert_eq!(name, "min");
            assert_eq!(args.len(), 2);
        } else {
            panic!("Expected function call");
        }

        let expr = parse("round(x, 2)").unwrap();
        if let Expr::FunctionCall { name, args } = expr {
            assert_eq!(name, "round");
            assert_eq!(args.len(), 2);
        } else {
            panic!("Expected function call");
        }
    }

    #[test]
    fn test_parse_ternary() {
        let expr = parse("x > 0 ? x : -x").unwrap();
        assert!(matches!(expr, Expr::Ternary { .. }));
    }

    #[test]
    fn test_parse_complex_expression() {
        let expr = parse("deco_time_min / bottom_time_min").unwrap();
        if let Expr::Binary { op, left, right } = expr {
            assert_eq!(op, BinaryOp::Div);
            assert!(matches!(*left, Expr::Variable(ref s) if s == "deco_time_min"));
            assert!(matches!(*right, Expr::Variable(ref s) if s == "bottom_time_min"));
        } else {
            panic!("Expected binary expression");
        }
    }

    #[test]
    fn test_parse_nested_functions() {
        let expr = parse("max(min(a, b), c)").unwrap();
        if let Expr::FunctionCall { name, args } = expr {
            assert_eq!(name, "max");
            assert_eq!(args.len(), 2);
            assert!(matches!(args[0], Expr::FunctionCall { .. }));
        } else {
            panic!("Expected function call");
        }
    }

    #[test]
    fn test_parse_empty() {
        let result = parse("");
        assert!(matches!(result, Err(FormulaError::EmptyExpression)));

        let result = parse("   ");
        assert!(matches!(result, Err(FormulaError::EmptyExpression)));
    }

    #[test]
    fn test_parse_error() {
        let result = parse("1 +");
        assert!(result.is_err());

        let result = parse("1 + 2 @");
        assert!(result.is_err());
    }
}
