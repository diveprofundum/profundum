use crate::error::FormulaError;
use crate::formula::ast::{BinaryOp, Expr, UnaryOp};

/// Relative tolerance for floating-point equality comparisons.
/// Two values are considered equal if they differ by less than this fraction
/// of the larger absolute value (with a floor of the tolerance itself for small numbers).
const FLOAT_TOLERANCE: f64 = 1e-6;

/// Check if two floats are nearly equal using relative tolerance.
fn nearly_equal(a: f64, b: f64) -> bool {
    let diff = (a - b).abs();
    let largest = a.abs().max(b.abs());
    // Use relative tolerance, but with absolute floor for numbers near zero
    diff <= FLOAT_TOLERANCE * largest.max(1.0)
}

/// Result of evaluating an expression.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Number(f64),
    Boolean(bool),
}

impl Value {
    pub fn as_number(&self) -> Result<f64, FormulaError> {
        match self {
            Value::Number(n) => Ok(*n),
            Value::Boolean(b) => Ok(if *b { 1.0 } else { 0.0 }),
        }
    }

    pub fn as_bool(&self) -> Result<bool, FormulaError> {
        match self {
            Value::Boolean(b) => Ok(*b),
            Value::Number(n) => Ok(*n != 0.0),
        }
    }

    pub fn is_truthy(&self) -> bool {
        match self {
            Value::Boolean(b) => *b,
            Value::Number(n) => *n != 0.0,
        }
    }
}

/// Trait for providing variable values during evaluation.
pub trait VariableProvider {
    fn get(&self, name: &str) -> Option<f64>;
}

impl<F> VariableProvider for F
where
    F: Fn(&str) -> Option<f64>,
{
    fn get(&self, name: &str) -> Option<f64> {
        self(name)
    }
}

/// Evaluate an expression with the given variable provider.
pub fn evaluate<V: VariableProvider>(expr: &Expr, vars: &V) -> Result<Value, FormulaError> {
    match expr {
        Expr::Number(n) => Ok(Value::Number(*n)),
        Expr::Boolean(b) => Ok(Value::Boolean(*b)),
        Expr::Variable(name) => vars
            .get(name)
            .map(Value::Number)
            .ok_or_else(|| FormulaError::UnknownVariable(name.clone())),
        Expr::Binary { op, left, right } => {
            let left_val = evaluate(left, vars)?;
            let right_val = evaluate(right, vars)?;
            evaluate_binary(*op, left_val, right_val)
        }
        Expr::Unary { op, expr } => {
            let val = evaluate(expr, vars)?;
            evaluate_unary(*op, val)
        }
        Expr::FunctionCall { name, args } => {
            let arg_values: Result<Vec<Value>, _> =
                args.iter().map(|a| evaluate(a, vars)).collect();
            evaluate_function(name, arg_values?)
        }
        Expr::Ternary {
            condition,
            then_expr,
            else_expr,
        } => {
            let cond = evaluate(condition, vars)?;
            if cond.is_truthy() {
                evaluate(then_expr, vars)
            } else {
                evaluate(else_expr, vars)
            }
        }
    }
}

fn evaluate_binary(op: BinaryOp, left: Value, right: Value) -> Result<Value, FormulaError> {
    match op {
        BinaryOp::Add => {
            let l = left.as_number()?;
            let r = right.as_number()?;
            Ok(Value::Number(l + r))
        }
        BinaryOp::Sub => {
            let l = left.as_number()?;
            let r = right.as_number()?;
            Ok(Value::Number(l - r))
        }
        BinaryOp::Mul => {
            let l = left.as_number()?;
            let r = right.as_number()?;
            Ok(Value::Number(l * r))
        }
        BinaryOp::Div => {
            let l = left.as_number()?;
            let r = right.as_number()?;
            if r == 0.0 {
                Err(FormulaError::DivisionByZero)
            } else {
                Ok(Value::Number(l / r))
            }
        }
        BinaryOp::Gt => {
            let l = left.as_number()?;
            let r = right.as_number()?;
            Ok(Value::Boolean(l > r))
        }
        BinaryOp::Lt => {
            let l = left.as_number()?;
            let r = right.as_number()?;
            Ok(Value::Boolean(l < r))
        }
        BinaryOp::Gte => {
            let l = left.as_number()?;
            let r = right.as_number()?;
            Ok(Value::Boolean(l >= r))
        }
        BinaryOp::Lte => {
            let l = left.as_number()?;
            let r = right.as_number()?;
            Ok(Value::Boolean(l <= r))
        }
        BinaryOp::Eq => {
            let l = left.as_number()?;
            let r = right.as_number()?;
            Ok(Value::Boolean(nearly_equal(l, r)))
        }
        BinaryOp::Neq => {
            let l = left.as_number()?;
            let r = right.as_number()?;
            Ok(Value::Boolean(!nearly_equal(l, r)))
        }
        BinaryOp::And => {
            let l = left.as_bool()?;
            let r = right.as_bool()?;
            Ok(Value::Boolean(l && r))
        }
        BinaryOp::Or => {
            let l = left.as_bool()?;
            let r = right.as_bool()?;
            Ok(Value::Boolean(l || r))
        }
    }
}

fn evaluate_unary(op: UnaryOp, val: Value) -> Result<Value, FormulaError> {
    match op {
        UnaryOp::Neg => {
            let n = val.as_number()?;
            Ok(Value::Number(-n))
        }
        UnaryOp::Not => {
            let b = val.as_bool()?;
            Ok(Value::Boolean(!b))
        }
    }
}

fn evaluate_function(name: &str, args: Vec<Value>) -> Result<Value, FormulaError> {
    match name.to_lowercase().as_str() {
        "min" => {
            if args.len() != 2 {
                return Err(FormulaError::InvalidArgCount {
                    function: "min".to_string(),
                    expected: 2,
                    got: args.len(),
                });
            }
            let a = args[0].as_number()?;
            let b = args[1].as_number()?;
            Ok(Value::Number(a.min(b)))
        }
        "max" => {
            if args.len() != 2 {
                return Err(FormulaError::InvalidArgCount {
                    function: "max".to_string(),
                    expected: 2,
                    got: args.len(),
                });
            }
            let a = args[0].as_number()?;
            let b = args[1].as_number()?;
            Ok(Value::Number(a.max(b)))
        }
        "round" => {
            if args.len() != 2 {
                return Err(FormulaError::InvalidArgCount {
                    function: "round".to_string(),
                    expected: 2,
                    got: args.len(),
                });
            }
            let x = args[0].as_number()?;
            let decimals = args[1].as_number()? as i32;
            let factor = 10_f64.powi(decimals);
            Ok(Value::Number((x * factor).round() / factor))
        }
        "abs" => {
            if args.len() != 1 {
                return Err(FormulaError::InvalidArgCount {
                    function: "abs".to_string(),
                    expected: 1,
                    got: args.len(),
                });
            }
            let x = args[0].as_number()?;
            Ok(Value::Number(x.abs()))
        }
        "sqrt" => {
            if args.len() != 1 {
                return Err(FormulaError::InvalidArgCount {
                    function: "sqrt".to_string(),
                    expected: 1,
                    got: args.len(),
                });
            }
            let x = args[0].as_number()?;
            Ok(Value::Number(x.sqrt()))
        }
        "floor" => {
            if args.len() != 1 {
                return Err(FormulaError::InvalidArgCount {
                    function: "floor".to_string(),
                    expected: 1,
                    got: args.len(),
                });
            }
            let x = args[0].as_number()?;
            Ok(Value::Number(x.floor()))
        }
        "ceil" => {
            if args.len() != 1 {
                return Err(FormulaError::InvalidArgCount {
                    function: "ceil".to_string(),
                    expected: 1,
                    got: args.len(),
                });
            }
            let x = args[0].as_number()?;
            Ok(Value::Number(x.ceil()))
        }
        "if" => {
            if args.len() != 3 {
                return Err(FormulaError::InvalidArgCount {
                    function: "if".to_string(),
                    expected: 3,
                    got: args.len(),
                });
            }
            let condition = args[0].as_bool()?;
            if condition {
                Ok(args[1].clone())
            } else {
                Ok(args[2].clone())
            }
        }
        _ => Err(FormulaError::UnknownFunction(name.to_string())),
    }
}

/// Information about a supported function.
#[derive(Debug, Clone)]
pub struct FunctionInfo {
    pub name: String,
    pub signature: String,
    pub description: String,
    pub arg_count: u32,
}

/// List of supported built-in functions.
pub fn supported_functions() -> Vec<FunctionInfo> {
    vec![
        FunctionInfo {
            name: "min".to_string(),
            signature: "min(a, b)".to_string(),
            description: "Returns the smaller of two values".to_string(),
            arg_count: 2,
        },
        FunctionInfo {
            name: "max".to_string(),
            signature: "max(a, b)".to_string(),
            description: "Returns the larger of two values".to_string(),
            arg_count: 2,
        },
        FunctionInfo {
            name: "round".to_string(),
            signature: "round(x, n)".to_string(),
            description: "Rounds x to n decimal places".to_string(),
            arg_count: 2,
        },
        FunctionInfo {
            name: "abs".to_string(),
            signature: "abs(x)".to_string(),
            description: "Returns the absolute value of x".to_string(),
            arg_count: 1,
        },
        FunctionInfo {
            name: "sqrt".to_string(),
            signature: "sqrt(x)".to_string(),
            description: "Returns the square root of x".to_string(),
            arg_count: 1,
        },
        FunctionInfo {
            name: "floor".to_string(),
            signature: "floor(x)".to_string(),
            description: "Rounds x down to the nearest integer".to_string(),
            arg_count: 1,
        },
        FunctionInfo {
            name: "ceil".to_string(),
            signature: "ceil(x)".to_string(),
            description: "Rounds x up to the nearest integer".to_string(),
            arg_count: 1,
        },
        FunctionInfo {
            name: "if".to_string(),
            signature: "if(cond, a, b)".to_string(),
            description: "Returns a if cond is true, otherwise b".to_string(),
            arg_count: 3,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::formula::parser::parse;
    use std::collections::HashMap;

    fn make_vars(values: Vec<(&str, f64)>) -> impl VariableProvider {
        let map: HashMap<String, f64> = values
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect();
        move |name: &str| map.get(name).copied()
    }

    #[test]
    fn test_evaluate_number() {
        let expr = parse("42").unwrap();
        let vars = make_vars(vec![]);
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 42.0).abs() < f64::EPSILON));
    }

    #[test]
    fn test_evaluate_variable() {
        let expr = parse("x").unwrap();
        let vars = make_vars(vec![("x", 10.0)]);
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 10.0).abs() < f64::EPSILON));
    }

    #[test]
    fn test_evaluate_unknown_variable() {
        let expr = parse("unknown").unwrap();
        let vars = make_vars(vec![]);
        let result = evaluate(&expr, &vars);
        assert!(matches!(result, Err(FormulaError::UnknownVariable(_))));
    }

    #[test]
    fn test_evaluate_arithmetic() {
        let vars = make_vars(vec![("a", 10.0), ("b", 3.0)]);

        let expr = parse("a + b").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 13.0).abs() < f64::EPSILON));

        let expr = parse("a - b").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 7.0).abs() < f64::EPSILON));

        let expr = parse("a * b").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 30.0).abs() < f64::EPSILON));

        let expr = parse("a / b").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 10.0/3.0).abs() < 0.0001));
    }

    #[test]
    fn test_evaluate_division_by_zero() {
        let expr = parse("1 / 0").unwrap();
        let vars = make_vars(vec![]);
        let result = evaluate(&expr, &vars);
        assert!(matches!(result, Err(FormulaError::DivisionByZero)));
    }

    #[test]
    fn test_evaluate_comparison() {
        let vars = make_vars(vec![("a", 10.0), ("b", 5.0)]);

        let expr = parse("a > b").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));

        let expr = parse("a < b").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Boolean(false)));

        let expr = parse("a >= 10").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));

        let expr = parse("a == 10").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));
    }

    #[test]
    fn test_evaluate_logical() {
        let vars = make_vars(vec![("a", 1.0), ("b", 0.0)]);

        let expr = parse("a and b").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Boolean(false)));

        let expr = parse("a or b").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));

        let expr = parse("not b").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));
    }

    #[test]
    fn test_evaluate_unary_neg() {
        let expr = parse("-5").unwrap();
        let vars = make_vars(vec![]);
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - (-5.0)).abs() < f64::EPSILON));
    }

    #[test]
    fn test_evaluate_functions() {
        let vars = make_vars(vec![("a", 3.0), ("b", 7.0)]);

        let expr = parse("min(a, b)").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 3.0).abs() < f64::EPSILON));

        let expr = parse("max(a, b)").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 7.0).abs() < f64::EPSILON));

        let expr = parse("round(2.7182, 2)").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 2.72).abs() < f64::EPSILON));

        let expr = parse("abs(-5)").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 5.0).abs() < f64::EPSILON));

        let expr = parse("sqrt(16)").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 4.0).abs() < f64::EPSILON));
    }

    #[test]
    fn test_evaluate_unknown_function() {
        let expr = parse("unknown(1)").unwrap();
        let vars = make_vars(vec![]);
        let result = evaluate(&expr, &vars);
        assert!(matches!(result, Err(FormulaError::UnknownFunction(_))));
    }

    #[test]
    fn test_evaluate_function_wrong_arg_count() {
        let expr = parse("min(1)").unwrap();
        let vars = make_vars(vec![]);
        let result = evaluate(&expr, &vars);
        assert!(matches!(result, Err(FormulaError::InvalidArgCount { .. })));
    }

    #[test]
    fn test_evaluate_ternary() {
        let vars = make_vars(vec![("x", 5.0)]);

        let expr = parse("x > 0 ? x : -x").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 5.0).abs() < f64::EPSILON));

        let vars = make_vars(vec![("x", -3.0)]);
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 3.0).abs() < f64::EPSILON));
    }

    #[test]
    fn test_evaluate_complex_formula() {
        let vars = make_vars(vec![("deco_time_min", 10.0), ("bottom_time_min", 50.0)]);

        let expr = parse("deco_time_min / bottom_time_min").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 0.2).abs() < f64::EPSILON));
    }

    #[test]
    fn test_evaluate_nested() {
        let vars = make_vars(vec![("a", 5.0), ("b", 3.0), ("c", 10.0)]);

        let expr = parse("max(min(a, b), c / 2)").unwrap();
        let result = evaluate(&expr, &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 5.0).abs() < f64::EPSILON));
    }

    // ── Coverage gap tests ──────────────────────────────────

    #[test]
    fn test_value_boolean_as_number() {
        assert_eq!(Value::Boolean(true).as_number().unwrap(), 1.0);
        assert_eq!(Value::Boolean(false).as_number().unwrap(), 0.0);
    }

    #[test]
    fn test_value_number_as_bool() {
        assert!(Value::Number(1.0).as_bool().unwrap());
        assert!(!Value::Number(0.0).as_bool().unwrap());
        assert!(Value::Number(-5.0).as_bool().unwrap());
        assert!(Value::Number(0.001).as_bool().unwrap());
    }

    #[test]
    fn test_value_is_truthy() {
        assert!(Value::Boolean(true).is_truthy());
        assert!(!Value::Boolean(false).is_truthy());
        assert!(Value::Number(1.0).is_truthy());
        assert!(!Value::Number(0.0).is_truthy());
    }

    #[test]
    fn test_evaluate_floor() {
        let vars = make_vars(vec![]);
        let result = evaluate(&parse("floor(2.7)").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 2.0).abs() < f64::EPSILON));

        let result = evaluate(&parse("floor(-2.3)").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - (-3.0)).abs() < f64::EPSILON));
    }

    #[test]
    fn test_evaluate_ceil() {
        let vars = make_vars(vec![]);
        let result = evaluate(&parse("ceil(2.3)").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 3.0).abs() < f64::EPSILON));

        let result = evaluate(&parse("ceil(-2.7)").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - (-2.0)).abs() < f64::EPSILON));
    }

    #[test]
    fn test_evaluate_floor_ceil_wrong_arg_count() {
        let vars = make_vars(vec![]);
        // Construct directly to avoid parser ambiguity
        let floor_2args = Expr::function_call("floor", vec![Expr::number(1.0), Expr::number(2.0)]);
        assert!(matches!(
            evaluate(&floor_2args, &vars),
            Err(FormulaError::InvalidArgCount { .. })
        ));

        let ceil_0args = Expr::function_call("ceil", vec![]);
        assert!(matches!(
            evaluate(&ceil_0args, &vars),
            Err(FormulaError::InvalidArgCount { .. })
        ));
    }

    #[test]
    fn test_evaluate_if_function() {
        let vars = make_vars(vec![("x", 5.0)]);
        let result = evaluate(&parse("if(x > 3, 1, 0)").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if (n - 1.0).abs() < f64::EPSILON));

        let result = evaluate(&parse("if(x > 10, 1, 0)").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Number(n) if n.abs() < f64::EPSILON));
    }

    #[test]
    fn test_evaluate_if_wrong_arg_count() {
        let vars = make_vars(vec![]);
        let if_2args = Expr::function_call("if", vec![Expr::boolean(true), Expr::number(1.0)]);
        assert!(matches!(
            evaluate(&if_2args, &vars),
            Err(FormulaError::InvalidArgCount { .. })
        ));
    }

    #[test]
    fn test_evaluate_comparison_lte() {
        let vars = make_vars(vec![("a", 5.0), ("b", 10.0)]);
        let result = evaluate(&parse("a <= b").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));

        let result = evaluate(&parse("a <= 5").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));

        let result = evaluate(&parse("b <= a").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(false)));
    }

    #[test]
    fn test_evaluate_comparison_neq() {
        let vars = make_vars(vec![("a", 5.0), ("b", 10.0)]);
        let result = evaluate(&parse("a != b").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));

        let result = evaluate(&parse("a != 5").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(false)));
    }

    #[test]
    fn test_evaluate_comparison_lt() {
        let vars = make_vars(vec![("a", 3.0), ("b", 7.0)]);
        let result = evaluate(&parse("a < b").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));

        let result = evaluate(&parse("b < a").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(false)));
    }

    #[test]
    fn test_evaluate_boolean_literals() {
        let vars = make_vars(vec![]);
        let result = evaluate(&parse("true").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));

        let result = evaluate(&parse("false").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(false)));
    }

    #[test]
    fn test_supported_functions_list() {
        let funcs = supported_functions();
        let names: Vec<&str> = funcs.iter().map(|f| f.name.as_str()).collect();
        assert!(names.contains(&"min"));
        assert!(names.contains(&"max"));
        assert!(names.contains(&"round"));
        assert!(names.contains(&"abs"));
        assert!(names.contains(&"sqrt"));
        assert!(names.contains(&"floor"));
        assert!(names.contains(&"ceil"));
        assert!(names.contains(&"if"));
        assert_eq!(funcs.len(), 8);
    }

    #[test]
    fn test_nearly_equal_edge_cases() {
        // Small numbers near zero
        let vars = make_vars(vec![]);
        let result = evaluate(&parse("0.0000001 == 0.0000001").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));

        // Large numbers
        let result = evaluate(&parse("1000000 == 1000000").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));
    }

    #[test]
    fn test_evaluate_unary_not_on_boolean() {
        let vars = make_vars(vec![]);
        let result = evaluate(&parse("not true").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(false)));

        let result = evaluate(&parse("not false").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));
    }

    #[test]
    fn test_evaluate_round_wrong_arg_count() {
        let vars = make_vars(vec![]);
        let round_1arg = Expr::function_call("round", vec![Expr::number(2.5)]);
        assert!(matches!(
            evaluate(&round_1arg, &vars),
            Err(FormulaError::InvalidArgCount { .. })
        ));
    }

    #[test]
    fn test_evaluate_abs_wrong_arg_count() {
        let vars = make_vars(vec![]);
        let abs_2args = Expr::function_call("abs", vec![Expr::number(1.0), Expr::number(2.0)]);
        assert!(matches!(
            evaluate(&abs_2args, &vars),
            Err(FormulaError::InvalidArgCount { .. })
        ));
    }

    #[test]
    fn test_evaluate_sqrt_wrong_arg_count() {
        let vars = make_vars(vec![]);
        let sqrt_0args = Expr::function_call("sqrt", vec![]);
        assert!(matches!(
            evaluate(&sqrt_0args, &vars),
            Err(FormulaError::InvalidArgCount { .. })
        ));
    }

    #[test]
    fn test_evaluate_max_wrong_arg_count() {
        let vars = make_vars(vec![]);
        let max_1arg = Expr::function_call("max", vec![Expr::number(1.0)]);
        assert!(matches!(
            evaluate(&max_1arg, &vars),
            Err(FormulaError::InvalidArgCount { .. })
        ));
    }

    // ── Mutation coverage tests ──────────────────────────────

    #[test]
    fn test_gt_boundary_equal() {
        // 5 > 5 → false (catches > → >=)
        let vars = make_vars(vec![]);
        let result = evaluate(&parse("5 > 5").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(false)));
    }

    #[test]
    fn test_lt_boundary_equal() {
        // 5 < 5 → false (catches < → <=)
        let vars = make_vars(vec![]);
        let result = evaluate(&parse("5 < 5").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(false)));
    }

    #[test]
    fn test_nearly_equal_relative_tolerance() {
        // 1000000.0 == 1000000.5 → true (relative tolerance: diff=0.5, largest=1e6, tol=1e-6*1e6=1.0)
        // If * → / in line 14, tolerance = 1e-6 / 1e6 = 1e-12, and this would be false
        let vars = make_vars(vec![]);
        let result = evaluate(&parse("1000000.0 == 1000000.5").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(true)));

        // Also verify unequal values are detected
        let result = evaluate(&parse("1000000.0 == 1000002.0").unwrap(), &vars).unwrap();
        assert!(matches!(result, Value::Boolean(false)));
    }
}
