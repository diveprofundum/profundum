//! Abstract syntax tree for formula expressions.

/// Binary operators.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinaryOp {
    Add,
    Sub,
    Mul,
    Div,
    Gt,
    Lt,
    Gte,
    Lte,
    Eq,
    Neq,
    And,
    Or,
}

impl BinaryOp {
    pub fn precedence(&self) -> u8 {
        match self {
            BinaryOp::Or => 1,
            BinaryOp::And => 2,
            BinaryOp::Eq | BinaryOp::Neq => 3,
            BinaryOp::Gt | BinaryOp::Lt | BinaryOp::Gte | BinaryOp::Lte => 4,
            BinaryOp::Add | BinaryOp::Sub => 5,
            BinaryOp::Mul | BinaryOp::Div => 6,
        }
    }

    pub fn symbol(&self) -> &'static str {
        match self {
            BinaryOp::Add => "+",
            BinaryOp::Sub => "-",
            BinaryOp::Mul => "*",
            BinaryOp::Div => "/",
            BinaryOp::Gt => ">",
            BinaryOp::Lt => "<",
            BinaryOp::Gte => ">=",
            BinaryOp::Lte => "<=",
            BinaryOp::Eq => "==",
            BinaryOp::Neq => "!=",
            BinaryOp::And => "and",
            BinaryOp::Or => "or",
        }
    }
}

/// Unary operators.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnaryOp {
    Neg,
    Not,
}

impl UnaryOp {
    pub fn symbol(&self) -> &'static str {
        match self {
            UnaryOp::Neg => "-",
            UnaryOp::Not => "not",
        }
    }
}

/// Expression nodes in the AST.
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    /// Numeric literal
    Number(f64),
    /// Boolean literal
    Boolean(bool),
    /// Variable reference (e.g., `max_depth_m`)
    Variable(String),
    /// Binary operation (e.g., `a + b`)
    Binary {
        op: BinaryOp,
        left: Box<Expr>,
        right: Box<Expr>,
    },
    /// Unary operation (e.g., `-x`, `not x`)
    Unary { op: UnaryOp, expr: Box<Expr> },
    /// Function call (e.g., `min(a, b)`)
    FunctionCall { name: String, args: Vec<Expr> },
    /// Ternary conditional (e.g., `cond ? a : b`)
    Ternary {
        condition: Box<Expr>,
        then_expr: Box<Expr>,
        else_expr: Box<Expr>,
    },
}

impl Expr {
    pub fn number(n: f64) -> Self {
        Expr::Number(n)
    }

    pub fn boolean(b: bool) -> Self {
        Expr::Boolean(b)
    }

    pub fn variable(name: impl Into<String>) -> Self {
        Expr::Variable(name.into())
    }

    pub fn binary(op: BinaryOp, left: Expr, right: Expr) -> Self {
        Expr::Binary {
            op,
            left: Box::new(left),
            right: Box::new(right),
        }
    }

    pub fn unary(op: UnaryOp, expr: Expr) -> Self {
        Expr::Unary {
            op,
            expr: Box::new(expr),
        }
    }

    pub fn function_call(name: impl Into<String>, args: Vec<Expr>) -> Self {
        Expr::FunctionCall {
            name: name.into(),
            args,
        }
    }

    pub fn ternary(condition: Expr, then_expr: Expr, else_expr: Expr) -> Self {
        Expr::Ternary {
            condition: Box::new(condition),
            then_expr: Box::new(then_expr),
            else_expr: Box::new(else_expr),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_binary_op_precedence() {
        assert!(BinaryOp::Mul.precedence() > BinaryOp::Add.precedence());
        assert!(BinaryOp::Add.precedence() > BinaryOp::Gt.precedence());
        assert!(BinaryOp::And.precedence() > BinaryOp::Or.precedence());
    }

    #[test]
    fn test_expr_constructors() {
        let num = Expr::number(42.0);
        assert!(matches!(num, Expr::Number(n) if (n - 42.0).abs() < f64::EPSILON));

        let var = Expr::variable("depth");
        assert!(matches!(var, Expr::Variable(ref s) if s == "depth"));

        let binary = Expr::binary(BinaryOp::Add, Expr::number(1.0), Expr::number(2.0));
        assert!(matches!(
            binary,
            Expr::Binary {
                op: BinaryOp::Add,
                ..
            }
        ));
    }
}
