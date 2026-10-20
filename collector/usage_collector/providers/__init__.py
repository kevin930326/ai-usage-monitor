from . import claude, codex

# 輸出 JSON 的 key → provider 模組；新增服務只要在這裡註冊
PROVIDERS = {
    "claude": claude,
    "codex": codex,
}
