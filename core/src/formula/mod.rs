//! Formula engine for user-defined calculated fields.
//!
//! This module provides parsing, validation, and evaluation of formula expressions
//! that can reference dive and segment variables.
//!
//! # Supported Grammar
//!
//! - Arithmetic: `+ - * / ( )`
//! - Comparison: `> < >= <= == !=`
//! - Boolean: `and or not`
//! - Ternary: `cond ? a : b`
//! - Functions: `min(a,b)`, `max(a,b)`, `round(x,n)`, `abs(x)`, `sqrt(x)`, `floor(x)`, `ceil(x)`, `if(cond,a,b)`
//!
//! # Example
//!
//! ```
//! use divelog_compute::formula::{validate, compute};
//!
//! // Validate a formula
//! let formula = "deco_time_min / bottom_time_min";
//! validate(formula).expect("Formula should be valid");
//!
//! // Compute with variables
//! let vars = |name: &str| match name {
//!     "deco_time_min" => Some(10.0),
//!     "bottom_time_min" => Some(50.0),
//!     _ => None,
//! };
//! let result = compute(formula, &vars).expect("Should compute");
//! assert!((result - 0.2).abs() < f64::EPSILON);
//! ```

pub mod ast;
pub mod evaluator;
pub mod parser;

pub use ast::{BinaryOp, Expr, UnaryOp};
pub use evaluator::{evaluate, supported_functions, FunctionInfo, Value, VariableProvider};
pub use parser::parse;

use crate::error::FormulaError;

/// Validate a formula expression without evaluating it.
///
/// This checks that the formula parses correctly but does not validate
/// that all variables exist (as that depends on context).
pub fn validate(expression: &str) -> Result<(), FormulaError> {
    parse(expression)?;
    Ok(())
}

/// Validate a formula and check that all variables are available.
pub fn validate_with_variables(expression: &str, available: &[&str]) -> Result<(), FormulaError> {
    let ast = parse(expression)?;
    check_variables(&ast, available)
}

fn check_variables(expr: &Expr, available: &[&str]) -> Result<(), FormulaError> {
    match expr {
        Expr::Number(_) | Expr::Boolean(_) => Ok(()),
        Expr::Variable(name) => {
            if available.contains(&name.as_str()) {
                Ok(())
            } else {
                Err(FormulaError::UnknownVariable(name.clone()))
            }
        }
        Expr::Binary { left, right, .. } => {
            check_variables(left, available)?;
            check_variables(right, available)
        }
        Expr::Unary { expr, .. } => check_variables(expr, available),
        Expr::FunctionCall { args, .. } => {
            for arg in args {
                check_variables(arg, available)?;
            }
            Ok(())
        }
        Expr::Ternary {
            condition,
            then_expr,
            else_expr,
        } => {
            check_variables(condition, available)?;
            check_variables(then_expr, available)?;
            check_variables(else_expr, available)
        }
    }
}

/// Compute a formula's numeric result given a variable provider.
pub fn compute<V: VariableProvider>(expression: &str, vars: &V) -> Result<f64, FormulaError> {
    let ast = parse(expression)?;
    let result = evaluate(&ast, vars)?;
    result.as_number()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_valid() {
        assert!(validate("1 + 2").is_ok());
        assert!(validate("x * y").is_ok());
        assert!(validate("min(a, b)").is_ok());
        assert!(validate("x > 0 ? x : -x").is_ok());
    }

    #[test]
    fn test_validate_invalid() {
        assert!(validate("").is_err());
        assert!(validate("1 +").is_err());
        assert!(validate("((1 + 2)").is_err());
    }

    #[test]
    fn test_validate_with_variables() {
        let available = vec!["x", "y"];
        assert!(validate_with_variables("x + y", &available).is_ok());
        assert!(validate_with_variables("x + z", &available).is_err());
    }

    #[test]
    fn test_compute() {
        let vars = |name: &str| match name {
            "x" => Some(10.0),
            "y" => Some(5.0),
            _ => None,
        };

        let result = compute("x + y", &vars).unwrap();
        assert!((result - 15.0).abs() < f64::EPSILON);

        let result = compute("x / y", &vars).unwrap();
        assert!((result - 2.0).abs() < f64::EPSILON);

        let result = compute("max(x, y) * 2", &vars).unwrap();
        assert!((result - 20.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_compute_dive_formula() {
        let vars = |name: &str| match name {
            "deco_time_min" => Some(15.0),
            "bottom_time_min" => Some(45.0),
            "max_depth_m" => Some(30.0),
            _ => None,
        };

        // Deco ratio
        let result = compute("deco_time_min / bottom_time_min", &vars).unwrap();
        assert!((result - 0.333).abs() < 0.01);

        // Depth classification as number
        let result = compute("max_depth_m > 40 ? 1 : 0", &vars).unwrap();
        assert!((result - 0.0).abs() < f64::EPSILON);
    }
}
