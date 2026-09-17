"""入口：python3 -m gm --config models.json"""
from __future__ import annotations

import argparse
import logging
import sys

from .engine import ModelManager
from .registry import Registry
from .server import make_server


def main() -> int:
    ap = argparse.ArgumentParser(prog="gm", description="General Model 本地推理网关")
    ap.add_argument("--config", default="models.json", help="models.json 路径")
    ap.add_argument("--host", default=None, help="覆盖配置里的 host")
    ap.add_argument("--port", type=int, default=None, help="覆盖配置里的 port")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    log = logging.getLogger("gm")

    registry = Registry.load(args.config)
    if args.host:
        registry.server.host = args.host
    if args.port:
        registry.server.port = args.port

    manager = ModelManager(registry, max_resident=registry.server.max_resident)
    srv = make_server(registry, manager)
    log.info(
        "gm gateway on http://%s:%d | models: %s",
        registry.server.host,
        registry.server.port,
        ", ".join(registry.list_ids()),
    )
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log.info("bye")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
