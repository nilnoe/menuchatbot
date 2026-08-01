//! 极简 JSON 实现（零依赖，保证 cargo build --offline 可构建）。
//!
//! 只覆盖本 crate 需要的子集：对象 / 数组 / 字符串 / 数字 / 布尔 / null，
//! 带完整转义解析与 UTF-8 输出。Tier 3 引入 embedding 依赖（candle）时，
//! 可切换为 serde_json；本模块保持内部使用，不进入 C ABI。

use std::fmt;

/// JSON 数字：整数优先（精确算术），必要时提升为浮点。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Number {
    Int(i64),
    Float(f64),
}

impl Number {
    pub fn as_f64(self) -> f64 {
        match self {
            Number::Int(i) => i as f64,
            Number::Float(f) => f,
        }
    }

    /// 展示用文本：整数直接输出；浮点若为整数值（如 4/2=2.0）去掉小数尾。
    pub fn to_display_string(self) -> String {
        match self {
            Number::Int(i) => i.to_string(),
            Number::Float(f) => {
                if f.is_finite() && f.fract() == 0.0 && f.abs() < 1e15 {
                    format!("{}", f as i64)
                } else {
                    format!("{}", f)
                }
            }
        }
    }
}

/// JSON 值（对象保留插入顺序，便于稳定输出）。
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Number(Number),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    pub fn object(pairs: Vec<(&str, Json)>) -> Json {
        Json::Object(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(items) => items.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// 数组按下标取元素。
    pub fn at(&self, index: usize) -> Option<&Json> {
        match self {
            Json::Array(items) => items.get(index),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Number(Number::Int(i)) => Some(*i),
            Json::Number(Number::Float(f)) if f.fract() == 0.0 && f.abs() < 9.2e18 => {
                Some(*f as i64)
            }
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }
}

impl fmt::Display for Json {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Json::Null => f.write_str("null"),
            Json::Bool(b) => write!(f, "{}", b),
            Json::Number(n) => f.write_str(&n.to_display_string()),
            Json::String(s) => write!(f, "{}", escape_string(s)),
            Json::Array(items) => {
                f.write_str("[")?;
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        f.write_str(",")?;
                    }
                    write!(f, "{}", item)?;
                }
                f.write_str("]")
            }
            Json::Object(items) => {
                f.write_str("{")?;
                for (i, (k, v)) in items.iter().enumerate() {
                    if i > 0 {
                        f.write_str(",")?;
                    }
                    write!(f, "{}", escape_string(k))?;
                    f.write_str(":")?;
                    write!(f, "{}", v)?;
                }
                f.write_str("}")
            }
        }
    }
}

fn escape_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// MARK: - 解析

/// 解析 JSON 文本；失败返回带位置信息的错误描述。
pub fn parse(input: &str) -> Result<Json, String> {
    let mut parser = Parser {
        bytes: input.as_bytes(),
        pos: 0,
    };
    parser.skip_ws();
    let value = parser.parse_value()?;
    parser.skip_ws();
    if parser.pos != parser.bytes.len() {
        return Err(format!(
            "unexpected trailing characters at offset {}",
            parser.pos
        ));
    }
    Ok(value)
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn skip_ws(&mut self) {
        while self.pos < self.bytes.len()
            && matches!(self.bytes[self.pos], b' ' | b'\t' | b'\n' | b'\r')
        {
            self.pos += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn error(&self, msg: &str) -> String {
        format!("{} at offset {}", msg, self.pos)
    }

    fn parse_value(&mut self) -> Result<Json, String> {
        self.skip_ws();
        match self.peek() {
            Some(b'{') => self.parse_object(),
            Some(b'[') => self.parse_array(),
            Some(b'"') => self.parse_string().map(Json::String),
            Some(b't') => self.parse_literal("true", Json::Bool(true)),
            Some(b'f') => self.parse_literal("false", Json::Bool(false)),
            Some(b'n') => self.parse_literal("null", Json::Null),
            Some(c) if c == b'-' || c.is_ascii_digit() => self.parse_number(),
            _ => Err(self.error("unexpected character")),
        }
    }

    fn parse_literal(&mut self, literal: &str, value: Json) -> Result<Json, String> {
        let end = self.pos + literal.len();
        if end > self.bytes.len() || &self.bytes[self.pos..end] != literal.as_bytes() {
            return Err(self.error("invalid literal"));
        }
        self.pos = end;
        Ok(value)
    }

    fn parse_object(&mut self) -> Result<Json, String> {
        self.pos += 1; // {
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Json::Object(items));
        }
        loop {
            self.skip_ws();
            let key = self.parse_string()?;
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Err(self.error("expected ':' after object key"));
            }
            self.pos += 1;
            let value = self.parse_value()?;
            items.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Json::Object(items));
                }
                _ => return Err(self.error("expected ',' or '}' in object")),
            }
        }
    }

    fn parse_array(&mut self) -> Result<Json, String> {
        self.pos += 1; // [
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Json::Array(items));
        }
        loop {
            items.push(self.parse_value()?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Json::Array(items));
                }
                _ => return Err(self.error("expected ',' or ']' in array")),
            }
        }
    }

    fn parse_string(&mut self) -> Result<String, String> {
        if self.peek() != Some(b'"') {
            return Err(self.error("expected string"));
        }
        self.pos += 1;
        let mut out = String::new();
        loop {
            let c = self
                .peek()
                .ok_or_else(|| self.error("unterminated string"))?;
            self.pos += 1;
            match c {
                b'"' => return Ok(out),
                b'\\' => {
                    let esc = self
                        .peek()
                        .ok_or_else(|| self.error("unterminated escape"))?;
                    self.pos += 1;
                    match esc {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{08}'),
                        b'f' => out.push('\u{0C}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let code = self.parse_hex4()?;
                            out.push(unescape_unicode(code)?);
                        }
                        other => return Err(format!("invalid escape '\\{}'", other as char)),
                    }
                }
                c if c < 0x20 => return Err(self.error("control character in string")),
                _ => {
                    // 逐字节拼装 UTF-8（ASCII 直通，多字节序列按原样拷贝）。
                    let start = self.pos - 1;
                    let len = utf8_len(c);
                    if self.pos + len - 1 > self.bytes.len() {
                        return Err(self.error("truncated UTF-8 sequence"));
                    }
                    let slice = &self.bytes[start..start + len];
                    out.push_str(
                        std::str::from_utf8(slice).map_err(|_| self.error("invalid UTF-8"))?,
                    );
                    self.pos += len - 1;
                }
            }
        }
    }

    fn parse_hex4(&mut self) -> Result<u32, String> {
        if self.pos + 4 > self.bytes.len() {
            return Err(self.error("truncated \\u escape"));
        }
        let hex = &self.bytes[self.pos..self.pos + 4];
        let text = std::str::from_utf8(hex).map_err(|_| self.error("invalid \\u escape"))?;
        let code = u32::from_str_radix(text, 16).map_err(|_| self.error("invalid \\u escape"))?;
        self.pos += 4;
        Ok(code)
    }

    fn parse_number(&mut self) -> Result<Json, String> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
            self.pos += 1;
        }
        let mut is_float = false;
        if self.peek() == Some(b'.') {
            is_float = true;
            self.pos += 1;
            while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        if matches!(self.peek(), Some(b'e') | Some(b'E')) {
            is_float = true;
            self.pos += 1;
            if matches!(self.peek(), Some(b'+') | Some(b'-')) {
                self.pos += 1;
            }
            while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        let text = &self.bytes[start..self.pos];
        if text.is_empty() || text == b"-" {
            return Err(self.error("invalid number"));
        }
        let text = std::str::from_utf8(text).map_err(|_| self.error("invalid number"))?;
        if !is_float {
            if let Ok(i) = text.parse::<i64>() {
                return Ok(Json::Number(Number::Int(i)));
            }
        }
        let f: f64 = text.parse().map_err(|_| self.error("invalid number"))?;
        Ok(Json::Number(Number::Float(f)))
    }
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

fn unescape_unicode(code: u32) -> Result<char, String> {
    char::from_u32(code).ok_or_else(|| format!("invalid unicode escape \\u{:04x}", code))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_serialize_roundtrip() {
        let input = r#"{"id":"m1","content":"你好，世界","ok":true,"n":42,"pi":3.14,"nil":null,"arr":[1,"a",false]}"#;
        let value = parse(input).unwrap();
        assert_eq!(value.get("id").unwrap().as_str(), Some("m1"));
        assert_eq!(value.get("ok").unwrap().as_bool(), Some(true));
        assert_eq!(value.get("n").unwrap().as_i64(), Some(42));
        assert_eq!(
            value.get("arr").unwrap(),
            &Json::Array(vec![
                Json::Number(Number::Int(1)),
                Json::String("a".to_string()),
                Json::Bool(false),
            ])
        );
    }

    #[test]
    fn parse_escapes() {
        let value = parse(r#"{"a":"line\nquote\"back\\tab\t"}"#).unwrap();
        assert_eq!(
            value.get("a").unwrap().as_str(),
            Some("line\nquote\"back\\tab\t")
        );
    }

    #[test]
    fn parse_numbers_with_exponent() {
        assert_eq!(parse("1e3").unwrap(), Json::Number(Number::Float(1000.0)));
        assert_eq!(parse("-2.5").unwrap(), Json::Number(Number::Float(-2.5)));
        assert_eq!(parse("42").unwrap(), Json::Number(Number::Int(42)));
    }

    #[test]
    fn reject_invalid_input() {
        assert!(parse("").is_err());
        assert!(parse("{").is_err());
        assert!(parse(r#"{"a":}"#).is_err());
        assert!(parse("tru").is_err());
        assert!(parse("[1,]").is_err());
        assert!(parse("1 2").is_err());
    }

    #[test]
    fn display_integral_float() {
        assert_eq!(Json::Number(Number::Float(2.0)).to_string(), "2");
        assert_eq!(Json::Number(Number::Float(2.5)).to_string(), "2.5");
        assert_eq!(Json::Number(Number::Int(-3)).to_string(), "-3");
    }
}
