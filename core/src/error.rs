use thiserror::Error;

/// Error type for formula parsing and evaluation.
#[derive(Error, Debug, Clone, PartialEq)]
pub enum FormulaError {
    #[error("parse error at position {position}: {message}")]
    ParseError { position: usize, message: String },

    #[error("unknown variable: {0}")]
    UnknownVariable(String),

    #[error("unknown function: {0}")]
    UnknownFunction(String),

    #[error("type error: {0}")]
    TypeError(String),

    #[error("division by zero")]
    DivisionByZero,

    #[error("invalid argument count for {function}: expected {expected}, got {got}")]
    InvalidArgCount {
        function: String,
        expected: usize,
        got: usize,
    },

    #[error("empty expression")]
    EmptyExpression,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_formula_error_display() {
        let err = FormulaError::ParseError {
            position: 5,
            message: "unexpected token".to_string(),
        };
        assert_eq!(
            err.to_string(),
            "parse error at position 5: unexpected token"
        );

        let err = FormulaError::UnknownVariable("foo".to_string());
        assert_eq!(err.to_string(), "unknown variable: foo");

        let err = FormulaError::DivisionByZero;
        assert_eq!(err.to_string(), "division by zero");

        let err = FormulaError::InvalidArgCount {
            function: "min".to_string(),
            expected: 2,
            got: 1,
        };
        assert_eq!(
            err.to_string(),
            "invalid argument count for min: expected 2, got 1"
        );
    }
}
