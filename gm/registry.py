"""配置与模型注册表。

models.json 结构（加模型=加一项，不改代码）：
{
  "server": {"host": "127.0.0.1", "port": 8320, "max_resident": 1},
  // port 只是默认值，可改。它是端口的唯一真相源：CLI、GUI、bench 都读这里。
  "models": [
    {
      "name": "llama-3.1-8b-4bit",
      "aliases": ["default", "general"],
      "runtime": "mlx_lm",                 // 对应 backends 注册表里的 key
      "path": "/path/to/your/model",
      "context": {"max_prompt_tokens": 8192, "max_output_tokens": 4096},
      "params": {"temperature": 0.7, "top_p": 1.0}
    }
  ]
}
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional


@dataclass
class ModelEntry:
    name: str
    runtime: str
    path: str
    aliases: List[str] = field(default_factory=list)
    max_prompt_tokens: int = 8192
    max_output_tokens: int = 4096
    params: Dict[str, Any] = field(default_factory=dict)

    def resolve_path(self) -> Path:
        return Path(self.path).expanduser()

    def exists(self) -> bool:
        return self.resolve_path().is_dir()


@dataclass
class ServerConfig:
    host: str = "127.0.0.1"
    port: int = 8320
    max_resident: int = 1  # 常驻模型数；超出按 LRU 卸载
    log_level: str = "INFO"


class Registry:
    """模型注册表：name/alias → ModelEntry。"""

    def __init__(self, entries: List[ModelEntry], server: ServerConfig):
        self.entries = entries
        self.server = server
        self._by_key: Dict[str, ModelEntry] = {}
        for e in entries:
            self._by_key[e.name.lower()] = e
            for a in e.aliases:
                self._by_key[a.lower()] = e

    def resolve(self, name: Optional[str]) -> ModelEntry:
        """按 name 或 alias 解析；空值/'default' → 注册表第一个模型。"""
        if not name or name.lower() == "default":
            if not self.entries:
                raise KeyError("registry is empty")
            return self.entries[0]
        key = name.lower()
        if key not in self._by_key:
            known = ", ".join(sorted({e.name for e in self.entries}))
            raise KeyError(f"unknown model '{name}' (known: {known})")
        return self._by_key[key]

    def list_ids(self) -> List[str]:
        return [e.name for e in self.entries]

    @classmethod
    def load(cls, config_path: str | Path) -> "Registry":
        p = Path(config_path).expanduser()
        raw = json.loads(p.read_text(encoding="utf-8"))
        srv = raw.get("server", {})
        server = ServerConfig(
            host=srv.get("host", "127.0.0.1"),
            port=int(srv.get("port", 8320)),
            max_resident=int(srv.get("max_resident", 1)),
            log_level=srv.get("log_level", "INFO"),
        )
        entries: List[ModelEntry] = []
        for m in raw.get("models", []):
            ctx = m.get("context", {})
            entries.append(
                ModelEntry(
                    name=m["name"],
                    runtime=m.get("runtime", "mlx_lm"),
                    path=m["path"],
                    aliases=list(m.get("aliases", [])),
                    max_prompt_tokens=int(ctx.get("max_prompt_tokens", 8192)),
                    max_output_tokens=int(ctx.get("max_output_tokens", 4096)),
                    params=dict(m.get("params", {})),
                )
            )
        if not entries:
            raise ValueError(f"no models defined in {p}")
        return cls(entries, server)
