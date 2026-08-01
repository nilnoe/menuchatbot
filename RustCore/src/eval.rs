//! T0 计算器：纯 Rust 表达式求值器（`dc_eval_expr` 的求值核心）。
//!
//! 支持：四则运算、括号、幂（^，右结合）、取模（%）、一元正负号、小数与
//! 科学计数法。无子进程、无文件 / 网络访问（T2-2b）。

use crate::json::Number;

/// 求值一个表达式；失败返回人类可读错误。
pub fn evaluate(expression: &str) -> Result<Number, String> {
    let tokens = tokenize(expression)?;
    let mut parser = Parser { tokens, pos: 0 };
    let value = parser.parse_expr()?;
    if parser.pos != parser.tokens.len() {
        return Err("表达式中存在多余内容".to_string());
    }
    Ok(value)
}

// MARK: - Tokenizer

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Number(Number),
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Caret,
    LParen,
    RParen,
}

fn tokenize(input: &str) -> Result<Vec<Tok>, String> {
    let bytes = input.as_bytes();
    let mut tokens = Vec::new();
    let mut pos = 0;
    while pos < bytes.len() {
        let c = bytes[pos];
        match c {
            b' ' | b'\t' | b'\n' | b'\r' => pos += 1,
            b'+' => {
                tokens.push(Tok::Plus);
                pos += 1;
            }
            b'-' => {
                tokens.push(Tok::Minus);
                pos += 1;
            }
            b'*' => {
                tokens.push(Tok::Star);
                pos += 1;
            }
            b'/' => {
                tokens.push(Tok::Slash);
                pos += 1;
            }
            b'%' => {
                tokens.push(Tok::Percent);
                pos += 1;
            }
            b'^' => {
                tokens.push(Tok::Caret);
                pos += 1;
            }
            b'(' => {
                tokens.push(Tok::LParen);
                pos += 1;
            }
            b')' => {
                tokens.push(Tok::RParen);
                pos += 1;
            }
            c if c.is_ascii_digit() || c == b'.' => {
                let (number, next) = parse_number(bytes, pos)?;
                tokens.push(Tok::Number(number));
                pos = next;
            }
            other => {
                let ch = std::str::from_utf8(&bytes[pos..pos + utf8_len(other)])
                    .map_err(|_| "无效字符".to_string())?;
                return Err(format!("不支持的字符：{}", ch));
            }
        }
    }
    Ok(tokens)
}

fn utf8_len(first: u8) -> usize {
    if first < 0x80 {
        1
    } else if first >> 5 == 0b110 {
        2
    } else if first >> 4 == 0b1110 {
        3
    } else if first >> 3 == 0b11110 {
        4
    } else {
        1
    }
}

/// 解析数字字面量：整数 / 小数 / 科学计数法；整数溢出时提升为浮点。
fn parse_number(bytes: &[u8], start: usize) -> Result<(Number, usize), String> {
    let mut pos = start;
    let mut is_float = false;
    while pos < bytes.len() && bytes[pos].is_ascii_digit() {
        pos += 1;
    }
    if pos < bytes.len() && bytes[pos] == b'.' {
        is_float = true;
        pos += 1;
        while pos < bytes.len() && bytes[pos].is_ascii_digit() {
            pos += 1;
        }
    }
    if pos < bytes.len() && matches!(bytes[pos], b'e' | b'E') {
        is_float = true;
        pos += 1;
        if pos < bytes.len() && matches!(bytes[pos], b'+' | b'-') {
            pos += 1;
        }
        while pos < bytes.len() && bytes[pos].is_ascii_digit() {
            pos += 1;
        }
    }
    if pos == start {
        return Err("数字格式错误".to_string());
    }
    let text = std::str::from_utf8(&bytes[start..pos]).map_err(|_| "数字格式错误".to_string())?;
    if !is_float {
        if let Ok(i) = text.parse::<i64>() {
            return Ok((Number::Int(i), pos));
        }
    }
    let f: f64 = text.parse().map_err(|_| "数字格式错误".to_string())?;
    Ok((Number::Float(f), pos))
}

// MARK: - Pratt / 递归下降解析
//
// 优先级：+ - < * / % < 一元符号 < ^（右结合）
// `-2^2` 按惯例解释为 -(2^2) = -4；`2^3^2` = 2^(3^2) = 512。

struct Parser {
    tokens: Vec<Tok>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.tokens.get(self.pos)
    }

    fn advance(&mut self) -> Option<Tok> {
        let tok = self.tokens.get(self.pos).cloned();
        if tok.is_some() {
            self.pos += 1;
        }
        tok
    }

    fn parse_expr(&mut self) -> Result<Number, String> {
        self.parse_add()
    }

    fn parse_add(&mut self) -> Result<Number, String> {
        let mut lhs = self.parse_mul()?;
        loop {
            match self.peek() {
                Some(Tok::Plus) => {
                    self.advance();
                    let rhs = self.parse_mul()?;
                    lhs = add(lhs, rhs)?;
                }
                Some(Tok::Minus) => {
                    self.advance();
                    let rhs = self.parse_mul()?;
                    lhs = sub(lhs, rhs)?;
                }
                _ => return Ok(lhs),
            }
        }
    }

    fn parse_mul(&mut self) -> Result<Number, String> {
        let mut lhs = self.parse_unary()?;
        loop {
            match self.peek() {
                Some(Tok::Star) => {
                    self.advance();
                    let rhs = self.parse_unary()?;
                    lhs = mul(lhs, rhs)?;
                }
                Some(Tok::Slash) => {
                    self.advance();
                    let rhs = self.parse_unary()?;
                    lhs = div(lhs, rhs)?;
                }
                Some(Tok::Percent) => {
                    self.advance();
                    let rhs = self.parse_unary()?;
                    lhs = modulo(lhs, rhs)?;
                }
                _ => return Ok(lhs),
            }
        }
    }

    fn parse_unary(&mut self) -> Result<Number, String> {
        match self.peek() {
            Some(Tok::Minus) => {
                self.advance();
                let value = self.parse_unary()?;
                negate(value)
            }
            Some(Tok::Plus) => {
                self.advance();
                self.parse_unary()
            }
            _ => self.parse_power(),
        }
    }

    /// 幂运算：右结合，优先级高于一元符号（-2^2 = -4）。
    fn parse_power(&mut self) -> Result<Number, String> {
        let base = self.parse_primary()?;
        if self.peek() == Some(&Tok::Caret) {
            self.advance();
            let exponent = self.parse_unary()?;
            return pow(base, exponent);
        }
        Ok(base)
    }

    fn parse_primary(&mut self) -> Result<Number, String> {
        match self.advance() {
            Some(Tok::Number(n)) => Ok(n),
            Some(Tok::LParen) => {
                let value = self.parse_expr()?;
                match self.advance() {
                    Some(Tok::RParen) => Ok(value),
                    _ => Err("缺少右括号".to_string()),
                }
            }
            _ => Err("表达式不完整".to_string()),
        }
    }
}

// MARK: - 算术

fn add(a: Number, b: Number) -> Result<Number, String> {
    match (a, b) {
        (Number::Int(x), Number::Int(y)) => x
            .checked_add(y)
            .map(Number::Int)
            .ok_or_else(|| "数值溢出".to_string()),
        (x, y) => Ok(Number::Float(x.as_f64() + y.as_f64())),
    }
}

fn sub(a: Number, b: Number) -> Result<Number, String> {
    match (a, b) {
        (Number::Int(x), Number::Int(y)) => x
            .checked_sub(y)
            .map(Number::Int)
            .ok_or_else(|| "数值溢出".to_string()),
        (x, y) => Ok(Number::Float(x.as_f64() - y.as_f64())),
    }
}

fn mul(a: Number, b: Number) -> Result<Number, String> {
    match (a, b) {
        (Number::Int(x), Number::Int(y)) => x
            .checked_mul(y)
            .map(Number::Int)
            .ok_or_else(|| "数值溢出".to_string()),
        (x, y) => Ok(Number::Float(x.as_f64() * y.as_f64())),
    }
}

fn div(a: Number, b: Number) -> Result<Number, String> {
    let divisor = b.as_f64();
    if divisor == 0.0 {
        return Err("不能除以零".to_string());
    }
    Ok(Number::Float(a.as_f64() / divisor))
}

fn modulo(a: Number, b: Number) -> Result<Number, String> {
    match (a, b) {
        (Number::Int(x), Number::Int(y)) => {
            if y == 0 {
                Err("不能对零取模".to_string())
            } else {
                Ok(Number::Int(x % y))
            }
        }
        (x, y) => {
            let divisor = y.as_f64();
            if divisor == 0.0 {
                Err("不能对零取模".to_string())
            } else {
                Ok(Number::Float(x.as_f64() % divisor))
            }
        }
    }
}

fn pow(base: Number, exponent: Number) -> Result<Number, String> {
    match (base, exponent) {
        (Number::Int(b), Number::Int(e)) if e >= 0 => {
            let result = b.checked_pow(e as u32);
            match result {
                Some(v) => Ok(Number::Int(v)),
                None => Ok(Number::Float((b as f64).powf(e as f64))),
            }
        }
        (b, e) => Ok(Number::Float(b.as_f64().powf(e.as_f64()))),
    }
}

fn negate(n: Number) -> Result<Number, String> {
    match n {
        Number::Int(i) => i
            .checked_neg()
            .map(Number::Int)
            .ok_or_else(|| "数值溢出".to_string()),
        Number::Float(f) => Ok(Number::Float(-f)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::Number::*;

    fn eval(expr: &str) -> Result<Number, String> {
        evaluate(expr)
    }

    #[test]
    fn arithmetic() {
        assert_eq!(eval("1+2").unwrap(), Int(3));
        assert_eq!(eval("7-10").unwrap(), Int(-3));
        assert_eq!(eval("3*4").unwrap(), Int(12));
        assert_eq!(eval("8/4").unwrap(), Float(2.0));
        assert_eq!(eval("1/3").unwrap(), Float(1.0 / 3.0));
    }

    #[test]
    fn precedence() {
        assert_eq!(eval("1+2*3").unwrap(), Int(7));
        assert_eq!(eval("10-2-3").unwrap(), Int(5));
        assert_eq!(eval("20/4*2").unwrap(), Float(10.0));
        assert_eq!(eval("2+3*4-5").unwrap(), Int(9));
    }

    #[test]
    fn parentheses() {
        assert_eq!(eval("(1+2)*3").unwrap(), Int(9));
        assert_eq!(eval("2*(3+4)").unwrap(), Int(14));
        assert_eq!(eval("((2+3)*4)").unwrap(), Int(20));
        assert_eq!(eval("(1+2)*(3+4)").unwrap(), Int(21));
    }

    #[test]
    fn power() {
        assert_eq!(eval("2^10").unwrap(), Int(1024));
        assert_eq!(eval("2^3^2").unwrap(), Int(512), "幂应为右结合");
        assert_eq!(eval("-2^2").unwrap(), Int(-4), "幂优先于一元负号");
        assert_eq!(eval("2^-1").unwrap(), Float(0.5));
        assert_eq!(eval("9^0.5").unwrap(), Float(3.0));
        assert_eq!(eval("2^63").unwrap(), Float(9.223372036854776e18));
    }

    #[test]
    fn modulo() {
        assert_eq!(eval("7%3").unwrap(), Int(1));
        assert_eq!(eval("10%5").unwrap(), Int(0));
        assert_eq!(eval("-7%3").unwrap(), Int(-1));
        assert_eq!(eval("7.5%2").unwrap(), Float(1.5));
    }

    #[test]
    fn unary_minus() {
        assert_eq!(eval("-5").unwrap(), Int(-5));
        assert_eq!(eval("--5").unwrap(), Int(5));
        assert_eq!(eval("-2+3").unwrap(), Int(1));
        assert_eq!(eval("3*-2").unwrap(), Int(-6));
    }

    #[test]
    fn decimals_and_scientific() {
        assert_eq!(eval("0.1+0.2").unwrap(), Float(0.30000000000000004));
        assert_eq!(eval("1e2").unwrap(), Float(100.0));
        assert_eq!(eval("1.5e-1").unwrap(), Float(0.15));
    }

    #[test]
    fn invalid_expressions_return_errors() {
        assert!(eval("").is_err());
        assert!(eval("1+").is_err());
        assert!(eval("(1+2").is_err());
        assert!(eval("1+2)").is_err());
        assert!(eval("abc").is_err());
        assert!(eval("1/0").is_err());
        assert!(eval("5%0").is_err());
        assert!(eval("1 2").is_err());
        assert!(eval("1+*2").is_err());
    }

    #[test]
    fn whitespace_insensitive() {
        assert_eq!(eval("  1 + 2 * ( 3 - 1 )  ").unwrap(), Int(5));
        assert_eq!(eval("1\t+\n2").unwrap(), Int(3));
    }
}
