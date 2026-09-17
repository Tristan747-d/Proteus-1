"""附件文本提取（网关侧）。

为什么放在网关而不是 GUI
------------------------
这样**任何**客户端都能用附件，而不只是本项目的 SwiftUI 应用。任何 OpenAI
兼容客户端只要发标准的 content parts 格式，网关就会代为提取：

    {"role": "user", "content": [
        {"type": "text", "text": "总结这个文件"},
        {"type": "file", "file": {"name": "a.py", "data": "<base64>"}}
    ]}

设计约束
--------
* **零新依赖优先**。网关跑在专用 venv 里（本机是 3.11，装了 mlx_lm，但
  **没有** pypdf/python-docx）。为了不把网关的依赖面撑大，这里按
  「macOS 自带 → 可选第三方 → 纯 stdlib」的顺序降级：
    - PDF    : pypdf（若装了）→ 否则 `mdimport`/纯文本兜底 → 失败即明确报错
    - docx   : `textutil`（macOS 自带，系统保证存在）
    - rtf/html/doc 等 : `textutil`
    - 纯文本/代码/CSV/JSON/MD : 直接读字节
* **绝不静默丢弃**。原实现 `_flatten_message` 会把非 text 的 part 直接跳过 ——
  用户附了一张图，模型收不到任何东西，也没有任何提示。附件路径必须显式：
  能提取就提取，不能提取就报错并说明原因。
* **有上限**。附件是任意长度的文本，塞进 prompt 会直接撑爆上下文或让
  prefill 变得极慢。这里做字节/字符双限，并在截断时明确标注截断位置。

安全
----
`textutil` / `mdimport` 通过 `subprocess` 调用，参数以**列表**形式传入
（绝不拼 shell 字符串），文件名不做解释执行。提取结果只作为文本进入 prompt。
"""
from __future__ import annotations

import base64
import json
import mimetypes
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

# ---- 限额 ----------------------------------------------------------------
# 单次请求里所有附件合计允许进入 prompt 的最大字符数。
# 定这个值的依据：模型 max_prompt_tokens=32768，中英混排大约 1 token ≈
# 1.5–3 字符。留出对话本身的空间，附件上限取 ~24000 字符（约 8k–16k token）。
MAX_TOTAL_CHARS = 24000
# 单个附件解压后的原始字节上限，防止读进一个几百 MB 的文件。
MAX_FILE_BYTES = 20 * 1024 * 1024
# 单个附件提取后允许的字符数（再大就截断）。
MAX_ONE_CHARS = 16000

# 直接按文本读取的扩展名（无需任何外部工具）
TEXT_EXTS = {
    ".txt", ".md", ".markdown", ".rst", ".log", ".ini", ".cfg", ".conf",
    ".py", ".pyi", ".js", ".jsx", ".ts", ".tsx", ".swift", ".c", ".h", ".cc",
    ".cpp", ".hpp", ".m", ".mm", ".java", ".kt", ".go", ".rs", ".rb", ".php",
    ".sh", ".bash", ".zsh", ".fish", ".ps1", ".sql", ".r", ".jl", ".lua",
    ".pl", ".scala", ".clj", ".hs", ".ml", ".ex", ".exs", ".erl", ".vim",
    ".html", ".htm", ".xml", ".css", ".scss", ".sass", ".less", ".svg",
    ".json", ".jsonl", ".yaml", ".yml", ".toml", ".csv", ".tsv", ".env",
    ".gitignore", ".dockerfile", ".makefile", ".cmake", ".gradle", ".tex",
}

# 交给 textutil 的扩展名（macOS 自带，覆盖 Office/RTF/HTML 等）
TEXTUTIL_EXTS = {
    ".docx", ".doc", ".rtf", ".rtfd", ".odt", ".wordml", ".webarchive",
}


class AttachmentError(ValueError):
    """附件无法处理。消息面向用户，必须可操作。"""


def _ext(name: str) -> str:
    return Path(name).suffix.lower()


def _decode_b64(data: str) -> bytes:
    """解 base64，容忍 data URL 前缀与换行。"""
    if not isinstance(data, str):
        raise AttachmentError("附件数据必须是 base64 字符串")
    s = data.strip()
    if s.startswith("data:"):
        # data:application/pdf;base64,XXXX
        comma = s.find(",")
        if comma >= 0:
            s = s[comma + 1:]
    s = "".join(s.split())
    try:
        raw = base64.b64decode(s, validate=False)
    except Exception as exc:
        raise AttachmentError(f"附件 base64 解码失败：{exc}") from exc
    if len(raw) > MAX_FILE_BYTES:
        raise AttachmentError(
            f"附件过大（{len(raw) / 1048576:.1f} MB），上限 "
            f"{MAX_FILE_BYTES / 1048576:.0f} MB")
    return raw


def _looks_binary(raw: bytes) -> bool:
    """粗判二进制：含 NUL 字节即视为二进制。"""
    return b"\x00" in raw[:8192]


def _decode_text(raw: bytes) -> str:
    """按常见编码解码。宁可替换坏字符，也不要因为一个字而整份失败。"""
    for enc in ("utf-8", "utf-8-sig", "gb18030", "big5", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def _run(cmd: list[str], timeout: int = 60) -> str:
    """跑外部命令，参数以列表传入（不经过 shell）。"""
    try:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout)
    except FileNotFoundError as exc:
        raise AttachmentError(f"找不到命令：{cmd[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise AttachmentError(f"{cmd[0]} 超时（{timeout}s）") from exc
    if r.returncode != 0:
        err = (r.stderr or b"").decode("utf-8", "replace").strip()
        raise AttachmentError(f"{cmd[0]} 失败：{err or r.returncode}")
    return r.stdout.decode("utf-8", errors="replace")


def _extract_pdf(path: Path) -> str:
    """PDF 文本提取。优先 pypdf；没有则回落到 textutil；再不行明确报错。

    ⚠️ 不假装成功。实测踩到：网关 venv 里没有 pypdf 时，`textutil` 对 PDF
    **返回码 0 但输出为空** —— 若不区分，用户会被告知「可能是扫描件」，
    而真实原因是根本没装解析库。这两件事必须分开说，否则用户会白费功夫
    去重新导出 PDF。因此这里在回落分支上显式检查：textutil 没吐字就当作
    「库缺失」而不是「空文档」。

    扫描件/纯图片 PDF 提取不出文字是**正常结果**，此时返回空串，由上层
    给出「可能是扫描件」的提示 —— 那才是真正该怀疑扫描件的场景。
    """
    try:
        import pypdf  # type: ignore
    except ImportError:
        pypdf = None

    if pypdf is not None:
        try:
            reader = pypdf.PdfReader(str(path))
            out = []
            for page in reader.pages:
                try:
                    out.append(page.extract_text() or "")
                except Exception:
                    out.append("")
            return "\n".join(out).strip()
        except Exception as exc:
            raise AttachmentError(f"PDF 解析失败：{exc}") from exc

    # 退路：macOS 的 textutil 对 PDF 基本不解析文本（实测空输出），
    # 这里只在它**确实吐出内容**时才采信。
    if shutil.which("textutil"):
        try:
            t = _run(["textutil", "-convert", "txt", "-stdout", str(path)]).strip()
            if t:
                return t
        except AttachmentError:
            pass

    raise AttachmentError(
        "无法提取 PDF 文本：网关环境未安装 pypdf（textutil 也不能解析 PDF）。"
        "安装后即可支持：用网关的解释器执行 pip install pypdf")


def _extract_textutil(path: Path) -> str:
    if not shutil.which("textutil"):
        raise AttachmentError(f"处理 {path.suffix} 需要 macOS 的 textutil（未找到）")
    return _run(["textutil", "-convert", "txt", "-stdout", str(path)]).strip()


def extract_one(name: str, raw: bytes) -> tuple[str, str]:
    """提取单个附件的文本。

    返回 (text, note)。note 用于向用户说明「提取到了什么/有什么损失」，
    例如「PDF 未提取到文字，可能是扫描件」。正常情况返回空 note。

    抛 AttachmentError 表示**无法**处理 —— 调用方应把这条错误暴露给用户，
    不要静默跳过（见模块顶部说明）。
    """
    ext = _ext(name)
    note = ""

    if ext in TEXTUTIL_EXTS:
        with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as f:
            f.write(raw)
            tmp = f.name
        try:
            text = _extract_textutil(Path(tmp))
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    elif ext == ".pdf":
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
            f.write(raw)
            tmp = f.name
        try:
            text = _extract_pdf(Path(tmp))
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        if not text.strip():
            note = "PDF 未提取到任何文字（可能是扫描件或纯图片）"
    elif ext in TEXT_EXTS or not ext:
        # 已知文本类型，或无扩展名 —— 用二进制探测兜底
        if _looks_binary(raw):
            raise AttachmentError(
                f"{name} 看起来是二进制文件，无法作为文本发送")
        text = _decode_text(raw)
    else:
        # 未知扩展名：先试文本，二进制则明确拒绝
        if _looks_binary(raw):
            raise AttachmentError(
                f"不支持的文件类型：{ext or '(无扩展名)'}。"
                f"可发送文本/代码/CSV/JSON/Markdown/PDF/docx 等。")
        text = _decode_text(raw)
        note = f"按纯文本解读（未知类型 {ext}）"

    return text, note


def build_attachment_block(parts: list) -> str:
    """把 OpenAI content parts 里的附件 part 转成一段注入 prompt 的文本。

    支持两种 part：
      {"type": "file", "file": {"name": ..., "data": <base64>}}
      {"type": "file", "file": {"name": ..., "text": <已解码文本>}}   ← 便捷形式

    返回拼接好的区块（可能为空串）。无附件时返回 ""，调用方行为不变。
    任何单个附件失败都抛 AttachmentError —— 绝不静默跳过。
    """
    files = []
    for p in parts:
        if not isinstance(p, dict):
            continue
        if p.get("type") != "file":
            continue
        f = p.get("file")
        if not isinstance(f, dict):
            raise AttachmentError("file part 缺少 file 对象")
        files.append(f)

    if not files:
        return ""

    blocks: list[str] = []
    total = 0
    for f in files:
        name = str(f.get("name") or "attachment")
        if "text" in f and isinstance(f["text"], str):
            text = f["text"]
            note = ""
        else:
            raw = _decode_b64(f.get("data", ""))
            text, note = extract_one(name, raw)

        # 单个附件截断
        truncated = False
        if len(text) > MAX_ONE_CHARS:
            text = text[:MAX_ONE_CHARS]
            truncated = True

        # 总量截断：超出即停止，并明确告诉用户后面的没进去
        remain = MAX_TOTAL_CHARS - total
        if remain <= 0:
            blocks.append(
                f"[附件「{name}」未包含：已达本次附件总量上限 "
                f"{MAX_TOTAL_CHARS} 字符]")
            continue
        if len(text) > remain:
            text = text[:remain]
            truncated = True
            total = MAX_TOTAL_CHARS
        else:
            total += len(text)

        head = f"--- 附件：{name} ---"
        if note:
            head += f"（{note}）"
        if truncated:
            head += f"（已截断至 {len(text)} 字符）"
        blocks.append(f"{head}\n{text}\n--- 附件结束 ---")

    if not blocks:
        return ""
    return ("\n\n以下是用户提供的附件内容，请结合它们回答：\n\n"
            + "\n\n".join(blocks))


def describe_formats() -> str:
    """附件支持说明（供 /stats 或文档使用）。"""
    pdf = "pypdf" if _has("pypdf") else "未安装"
    return (
        f"文本/代码/CSV/JSON/Markdown：直接读取；"
        f"docx/rtf/html：textutil（macOS 自带）；"
        f"PDF：{pdf}；"
        f"单附件上限 {MAX_ONE_CHARS} 字符，合计 {MAX_TOTAL_CHARS} 字符。"
    )


def _has(mod: str) -> bool:
    try:
        __import__(mod)
        return True
    except ImportError:
        return False
