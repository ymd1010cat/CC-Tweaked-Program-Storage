#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Lua 源码的小工具：扫描分类 + 安全剥注释。

只做两件事，但必须做得对：
  1. scan(src)：单遍扫描，统计 代码/注释/字符串 各占多少字节（以及其中中文多少）。
  2. strip_comments(src)：去掉注释与行尾空白、压掉多余空行，
     **但不碰字符串内容**（长字符串、引号字符串里的 -- 与空行都必须原样保留）。

CC 电脑磁盘默认只有 1MB，而中文注释随包发出去是纯浪费，所以打包时会剥注释；
源码本身保留完整注释，方便人读。
"""

import re

CJK_MIN = 0x2E7F        # 超过这个码位基本就是中文/全角标点


def _cjk_bytes(text):
    return sum(len(c.encode("utf-8")) for c in text if ord(c) > CJK_MIN)


def scan(src):
    """返回 (counts, cjk)：counts/cjk 都是 {code=, comment=, string=} 的字节数。"""
    i, n = 0, len(src)
    counts = {"code": 0, "comment": 0, "string": 0}
    cjk = {"code": 0, "comment": 0, "string": 0}

    def bump(chunk, kind):
        counts[kind] += len(chunk.encode("utf-8"))
        cjk[kind] += _cjk_bytes(chunk)

    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):
            end = _long_bracket_end(src, i + 2)
            if end is not None:
                bump(src[i:end], "comment")
                i = end
                continue
            end = src.find("\n", i)
            end = n if end < 0 else end
            bump(src[i:end], "comment")
            i = end
            continue
        if c == "[":
            end = _long_bracket_end(src, i)
            if end is not None:
                bump(src[i:end], "string")
                i = end
                continue
        if c in "\"'":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == c or src[j] == "\n":
                    j += 1
                    break
                j += 1
            bump(src[i:j], "string")
            i = j
            continue
        bump(c, "code")
        i += 1

    return counts, cjk


def _long_bracket_end(src, start):
    """若 src[start:] 是 [[ / [=[ 形式的长括号，返回它的结束下标（含结束符），否则 None。"""
    if start >= len(src) or src[start] != "[":
        return None
    k = start + 1
    level = 0
    while k < len(src) and src[k] == "=":
        level += 1
        k += 1
    if k >= len(src) or src[k] != "[":
        return None
    close = "]" + "=" * level + "]"
    end = src.find(close, k + 1)
    return len(src) if end < 0 else end + len(close)


def strip_comments(src, collapse_blank=True):
    """剥掉注释（保留换行）、行尾空白，并压缩连续空行。

    实现方式是"复制保留区、跳过注释区"，所以字符串里的内容绝对不会被改动。
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):
            end = _long_bracket_end(src, i + 2)
            if end is not None:
                # 块注释：保留其中的换行，避免把前后两行粘在一起
                out.append("\n" * src.count("\n", i, end))
                i = end
                continue
            end = src.find("\n", i)
            if end < 0:
                i = n
                continue
            i = end                      # 行注释：换行留给下一轮处理
            continue
        if c == "[":
            end = _long_bracket_end(src, i)
            if end is not None:
                out.append(src[i:end])   # 长字符串整体保留
                i = end
                continue
        if c in "\"'":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == c or src[j] == "\n":
                    j += 1
                    break
                j += 1
            out.append(src[i:j])
            i = j
            continue
        out.append(c)
        i += 1

    text = "".join(out)
    # 行尾空白
    text = re.sub(r"[ \t]+(\r?\n)", r"\1", text)
    if collapse_blank:
        text = re.sub(r"\n{3,}", "\n\n", text)
    return text.lstrip("\n")


def stats_line(name, src):
    counts, cjk = scan(src)
    total = len(src.encode("utf-8"))
    return "%-20s %8d 字节  注释 %6d  字符串 %6d  代码 %6d  中文(串) %5d" % (
        name, total, counts["comment"], counts["string"], counts["code"], cjk["string"])
