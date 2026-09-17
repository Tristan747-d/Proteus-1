"""模型管理：加载/LRU 卸载/串行生成（单 GPU 模型一次只跑一个请求）。"""
from __future__ import annotations

import threading
import time
from collections import OrderedDict
from typing import Dict, List, Optional

from .backends.base import Backend, GenOptions
from .registry import ModelEntry, Registry


class ModelManager:
    def __init__(self, registry: Registry, max_resident: int = 1):
        self.registry = registry
        self.max_resident = max(1, max_resident)
        self._loaded: "OrderedDict[str, Backend]" = OrderedDict()
        self._create_lock = threading.Lock()
        self.gen_lock = threading.Lock()  # 单模型 GPU 推理串行化
        self.started_at = time.time()
        self.last_meta: Optional[dict] = None

    # ---- lifecycle -------------------------------------------------------

    def get(self, entry: ModelEntry) -> Backend:
        key = entry.name
        with self._create_lock:
            if key in self._loaded:
                self._loaded.move_to_end(key)
                return self._loaded[key]
            backend = __import__(
                f"gm.backends.{entry.runtime}_backend", fromlist=["create"]
            ).create(entry)
            backend.load()
            self._loaded[key] = backend
            self._trim()
            return backend

    def _trim(self) -> None:
        while len(self._loaded) > self.max_resident:
            old_key, old = self._loaded.popitem(last=False)
            try:
                old.unload()
            except Exception:
                pass

    def loaded_names(self) -> List[str]:
        return list(self._loaded.keys())

    def backend_for(self, name: Optional[str]) -> "tuple[ModelEntry, Backend]":
        entry = self.registry.resolve(name)
        return entry, self.get(entry)

    def stats(self) -> dict:
        # 每个已加载后端的投机解码实际状态。换 target 模型时若 draft 的
        # tokenizer 不兼容，闸门会安全退回普通解码 —— 这里把它显式暴露，
        # 否则运维只会看到「换模型之后变慢了」而查不到原因。
        spec = {}
        for name, backend in self._loaded.items():
            fn = getattr(backend, "spec_status", None)
            if callable(fn):
                try:
                    spec[name] = fn()
                except Exception as exc:  # pragma: no cover - 观测不应影响主流程
                    spec[name] = {"error": str(exc)}
        return {
            "uptime_s": round(time.time() - self.started_at, 1),
            "models": self.registry.list_ids(),
            "loaded": self.loaded_names(),
            "speculative": spec,
            "last_meta": self.last_meta,
        }
