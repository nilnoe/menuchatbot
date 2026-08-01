//! 确定性 fuzz 冒烟（AU-16 的常驻部分）：10 万伪随机输入打 `json::parse` 与
//! `eval::evaluate`（`dc_eval_expr` / `dc_index_upsert` 的输入边界），无 panic。
//! 真 fuzz（libFuzzer）由 CI cron job 运行，见 `.github/workflows/ci.yml`。

use rustcore::eval;
use rustcore::json;

/// 最小线性同余 PRNG（无依赖，仅生成伪随机字节）。
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u8 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        (self.0 >> 56) as u8
    }
}

#[test]
fn fuzz_smoke_100k_inputs_no_panic() {
    let mut rng = Lcg(0x1234_5678_9abc_def0);
    let mut buffer = Vec::with_capacity(256);
    for _ in 0..100_000 {
        buffer.clear();
        let length = (rng.next() as usize) % 256;
        for _ in 0..length {
            buffer.push(rng.next());
        }
        if let Ok(text) = std::str::from_utf8(&buffer) {
            let _ = json::parse(text);
            let _ = eval::evaluate(text);
        }
    }
}
