# History index oracle fixtures

Synthetic records only; no user paths, prompts, responses or account data.

`codex-counters.jsonl` fixes cumulative growth, duplicate observations and epoch reset. Expected nonzero deltas: total 100, 45, 15, 15; input 80, 40, 10, 10; cached 50, 20, 2, 2; output 20, 5, 5, 5. These expectations reflect main db40798 semantics, not an independently invented normalization rule.

Existing token, timezone, model inference and leadership self-tests remain mandatory oracles. Incremental parsing must be compared at every complete-line restart boundary.

压缩回归夹具由 Zstandard 1.5.7 的 `zstd -q -c --check` 生成：

- `codex-counters.jsonl.zst`：现有完整计数器夹具，累计 175 token
- `codex-first-counter.jsonl.zst`：计数器夹具的第一行，累计 100 token，用于原子替换回归
- `codex-large-output.jsonl.zst`：`compacted` 事件的 `payload` 为 200000 个 `x`，用于跨解码输出块验证，不包含真实正文
