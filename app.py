# -*- coding: utf-8 -*-
"""
酒店英语口语练习 - Edge-TTS 后端服务
=====================================
功能：
1. /api/tts  接收文本与语速，调用 edge-tts 生成 MP3 音频流返回
2. 对于单个单词，优先调用 Free Dictionary API 获取真人发音音频；
   若词典无音频或为长句，则降级使用 edge-tts 生成。

依赖：
    pip install flask edge-tts requests

运行：
    python app.py
默认监听 http://localhost:5000
"""

import asyncio
import io
import re
import tempfile
import os

import edge_tts
import requests
from flask import Flask, request, send_file, jsonify
from flask_cors import CORS

# ---------- 基础配置 ----------
app = Flask(__name__)
# 允许前端 localhost:8080 跨域访问（也允许所有来源，方便本地调试）
CORS(app, resources={r"/*": {"origins": "*"}})

# 优选自然女声（edge-tts 神经网络语音）
# en-US-JennyNeural 与 en-US-AriaNeural 均为微软高质量自然女声
PREFERRED_VOICES = ["en-US-JennyNeural", "en-US-AriaNeural"]

# Free Dictionary API 基础地址（免费、无需 key）
DICT_API_BASE = "https://api.dictionaryapi.dev/api/v2/entries/en"

# 请求超时（秒）
REQUEST_TIMEOUT = 15


# ---------- 工具函数 ----------

def is_single_word(text: str) -> bool:
    """判断文本是否为单个单词（仅含字母与连字符，不含空格/标点）"""
    cleaned = text.strip()
    # 单个单词：只包含字母、撇号、连字符，无空格
    return bool(re.fullmatch(r"[A-Za-z'’\-]+", cleaned))


def get_dictionary_audio_url(word: str):
    """
    调用 Free Dictionary API 获取单词真人发音音频 URL。
    返回音频 URL 字符串；若未找到则返回 None。
    """
    try:
        url = f"{DICT_API_BASE}/{word}"
        resp = requests.get(url, timeout=REQUEST_TIMEOUT)
        if resp.status_code != 200:
            return None
        data = resp.json()
        # 词典返回为列表，取第一个词条的 phonetics
        if isinstance(data, list) and data:
            phonetics = data[0].get("phonetics", [])
            # phonetics 数组中可能有多个音频，优先取非空的 audio
            for ph in phonetics:
                audio = ph.get("audio", "")
                if audio and audio.startswith("http"):
                    return audio
        return None
    except Exception as e:
        # 词典请求失败不阻断流程，静默降级到 edge-tts
        print(f"[Dictionary API] 查询失败: {e}")
        return None


async def generate_edge_tts(text: str, rate: float) -> bytes:
    """
    使用 edge-tts 将文本合成为 MP3 字节流。
    :param text: 要朗读的文本
    :param rate: 语速倍率，0.9 为正常略慢，0.65 为慢速
    :return: MP3 音频的字节数据
    """
    # edge-tts 的 rate 参数格式："+0%" / "-10%" 等，需要把倍率换算成百分比
    # rate=0.9 → -10%；rate=0.65 → -35%
    rate_percent = int((rate - 1.0) * 100)
    rate_str = f"{rate_percent:+d}%"

    last_error = None
    # 依次尝试优选语音，避免某个语音不可用导致整体失败
    for voice in PREFERRED_VOICES:
        try:
            communicate = edge_tts.Communicate(text, voice, rate=rate_str)
            audio_buffer = io.BytesIO()
            async for chunk in communicate.stream():
                if chunk["type"] == "audio":
                    audio_buffer.write(chunk["data"])
            audio_buffer.seek(0)
            return audio_buffer.read()
        except Exception as e:
            last_error = e
            continue

    # 所有优选语音都失败，抛出异常
    raise RuntimeError(f"edge-tts 生成失败: {last_error}")


# ---------- 路由 ----------

@app.route("/api/tts", methods=["POST"])
def tts():
    """
    文本转语音接口。
    请求体（JSON）：
        {
            "text": "The room is already prepaid.",   必填，要朗读的英文文本
            "rate": 0.9                                可选，语速倍率，默认 0.9
        }
    响应：
        成功：返回 audio/mpeg 的 MP3 音频流
        失败：返回 4xx/5xx JSON 错误信息
    """
    data = request.get_json(silent=True) or {}
    text = (data.get("text") or "").strip()
    rate = data.get("rate", 0.9)

    # 参数校验
    if not text:
        return jsonify({"error": "text 参数不能为空"}), 400
    try:
        rate = float(rate)
    except (TypeError, ValueError):
        return jsonify({"error": "rate 必须是数字"}), 400
    if rate <= 0:
        return jsonify({"error": "rate 必须大于 0"}), 400

    # 策略 1：若为单个单词，优先尝试词典真人发音
    if is_single_word(text):
        audio_url = get_dictionary_audio_url(text)
        if audio_url:
            try:
                audio_resp = requests.get(audio_url, timeout=REQUEST_TIMEOUT)
                if audio_resp.status_code == 200 and audio_resp.content:
                    return send_file(
                        io.BytesIO(audio_resp.content),
                        mimetype="audio/mpeg",
                        as_attachment=False,
                    )
            except Exception as e:
                print(f"[Dictionary Audio] 下载失败，降级到 edge-tts: {e}")

    # 策略 2（降级）：使用 edge-tts 生成 MP3
    try:
        audio_bytes = asyncio.run(generate_edge_tts(text, rate))
    except Exception as e:
        return jsonify({"error": f"TTS 生成失败: {str(e)}"}), 500

    return send_file(
        io.BytesIO(audio_bytes),
        mimetype="audio/mpeg",
        as_attachment=False,
    )


@app.route("/api/health", methods=["GET"])
def health():
    """健康检查接口，用于确认服务是否启动"""
    return jsonify({"status": "ok", "voices": PREFERRED_VOICES})


if __name__ == "__main__":
    # debug=True 方便开发；生产环境请关闭
    app.run(host="0.0.0.0", port=5000, debug=False)
