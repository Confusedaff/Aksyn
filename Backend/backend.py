"""
Live Audio Detection Server
============================
Receives audio chunks from Flutter via WebSocket (live streaming) or
HTTP POST (completed recordings), runs Whisper + YAMNet detection,
and saves results + the final audio file to Supabase.

Install:
    pip install fastapi uvicorn python-multipart websockets
    pip install openai-whisper numpy scipy tensorflow tensorflow-hub
    pip install supabase python-dotenv

Run:
    uvicorn server:app --host 0.0.0.0 --port 8000 --reload

.env:
    SUPABASE_URL=https://xxxx.supabase.co
    SUPABASE_KEY=your-service-role-key
    SUPABASE_BUCKET=audio-recordings
"""

import os
import io
import re
import csv
import uuid
import time
import threading
import tempfile
import warnings
import urllib.request
from typing import Optional

os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
warnings.filterwarnings("ignore")

import numpy as np
import scipy.io.wavfile as wav
import scipy.signal as signal
import whisper
import tensorflow as tf
import tensorflow_hub as hub

tf.get_logger().setLevel("ERROR")

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

# ─────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────

SUPABASE_URL    = os.getenv("SUPABASE_URL", "")
SUPABASE_KEY    = os.getenv("SUPABASE_KEY", "")
SUPABASE_BUCKET = os.getenv("SUPABASE_BUCKET", "audio-recordings")

SAMPLE_RATE            = 16000
CHUNK_DURATION         = 4
CHUNK_SAMPLES          = SAMPLE_RATE * CHUNK_DURATION
OVERLAP_SAMPLES        = int(SAMPLE_RATE * 1.0)
SILENCE_RMS_THRESHOLD  = 0.002
YAMNET_MEAN_THRESHOLD  = 0.05
YAMNET_FRAME_THRESHOLD = 0.10
NEGATION_WINDOW        = 6

YAMNET_CLASS_MAP_URL = (
    "https://raw.githubusercontent.com/tensorflow/models/master/"
    "research/audioset/yamnet/yamnet_class_map.csv"
)
YAMNET_ALERT_SUBSTRINGS = [
    "scream", "screaming", "crying", "sobbing", "yell", "yelling",
    "shout", "wail", "wailing", "moan", "fire alarm", "smoke detector",
    "gunshot", "gun", "explosion", "glass", "breaking", "siren", "alarm",
]

STT_KEYWORD_RULES = [
    ("help",               ["no", "not", "don't", "dont", "doesn't", "doesnt",
                            "didn't", "didnt", "without", "need no", "want no"]),
    ("save me",            []),
    ("call police",        []),
    ("call 911",           []),
    ("call an ambulance",  []),
    ("someone help",       []),
    ("please help",        []),
    ("fire",               ["no", "not", "don't", "dont", "ceasefire", "gunfire"]),
    ("there's a fire",     []),
    ("flood",              ["no", "not"]),
    ("earthquake",         []),
    ("explosion",          []),
    ("emergency",          ["no", "not", "non"]),
    ("attack",             ["no", "not", "counter"]),
    ("thief",              []),
    ("robbery",            []),
    ("gun",                ["no", "not", "top gun", "water gun"]),
    ("bomb",               ["no", "not", "photobomb"]),
    ("knife",              ["no", "not"]),
    ("i'm hurt",           []),
    ("i am hurt",          []),
    ("i'm bleeding",       []),
    ("i am bleeding",      []),
    ("i'm dying",          ["not", "no"]),
    ("i can't breathe",    []),
    ("can't breathe",      []),
    ("so much pain",       []),
    ("in pain",            ["no", "not", "without"]),
    ("it hurts",           []),
    ("chest pain",         []),
    ("heart attack",       []),
    ("i need a doctor",    []),
    ("call a doctor",      []),
    ("overdose",           []),
    ("let me go",          []),
    ("let me out",         []),
    ("don't touch me",     []),
    ("get away from me",   []),
    ("kidnap",             []),
    ("assault",            []),
    ("accident",           ["no", "not"]),
    ("crash",              ["no", "not"]),
    ("i've been hit",      []),
]


# ─────────────────────────────────────────────────────────────────
# MODEL LOADING  (at startup — not per-request)
# ─────────────────────────────────────────────────────────────────

print("Loading Whisper model …")
whisper_model = whisper.load_model("base")
print("✔  Whisper ready.")

print("Loading YAMNet model …")
yamnet_model = hub.load("https://tfhub.dev/google/yamnet/1")
print("✔  YAMNet ready.")

print("Fetching YAMNet class labels …")
yamnet_all_labels = {}
YAMNET_ALERT_INDICES = {}
try:
    with urllib.request.urlopen(YAMNET_CLASS_MAP_URL, timeout=10) as resp:
        for row in csv.DictReader(resp.read().decode().splitlines()):
            yamnet_all_labels[int(row["index"])] = row["display_name"].lower()
    YAMNET_ALERT_INDICES = {
        idx: lbl for idx, lbl in yamnet_all_labels.items()
        if any(sub in lbl for sub in YAMNET_ALERT_SUBSTRINGS)
    }
    print(f"✔  Matched {len(YAMNET_ALERT_INDICES)} YAMNet alert classes.")
except Exception as e:
    print(f"⚠  Label fetch failed: {e}")
    YAMNET_ALERT_INDICES = {
        11: "screaming", 19: "crying, sobbing", 390: "siren",
        394: "fire alarm", 420: "explosion", 421: "gunshot, gunfire",
    }


# ─────────────────────────────────────────────────────────────────
# SUPABASE CLIENT
# ─────────────────────────────────────────────────────────────────

_sb = None
try:
    from supabase import create_client
    if SUPABASE_URL and SUPABASE_KEY:
        _sb = create_client(SUPABASE_URL, SUPABASE_KEY)
        print(f"✔  Supabase connected → bucket: '{SUPABASE_BUCKET}'")
    else:
        print("⚠  SUPABASE_URL/KEY not set — results won't be saved.")
except Exception as e:
    print(f"⚠  Supabase init failed: {e}")


# ─────────────────────────────────────────────────────────────────
# FASTAPI APP
# ─────────────────────────────────────────────────────────────────

app = FastAPI(title="Voice Detection API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─────────────────────────────────────────────────────────────────
# DETECTION HELPERS
# ─────────────────────────────────────────────────────────────────

def is_silent(audio_np: np.ndarray) -> bool:
    return float(np.sqrt(np.mean(audio_np ** 2))) < SILENCE_RMS_THRESHOLD


def _tokenize(text: str) -> list:
    return re.findall(r"[a-z']+", text.lower())


def keyword_triggered(transcript: str):
    tokens   = _tokenize(transcript)
    text_low = transcript.lower()
    for keyword, negations in STT_KEYWORD_RULES:
        pattern = r"\b" + re.escape(keyword) + r"\b"
        for m in re.finditer(pattern, text_low):
            char_pos  = m.start()
            token_pos = len(re.findall(r"[a-z']+", text_low[:char_pos]))
            preceding = " ".join(tokens[max(0, token_pos - NEGATION_WINDOW): token_pos])
            if not any(neg in preceding for neg in negations):
                return True, keyword
    return False, ""


def run_stt(audio_np: np.ndarray) -> Optional[dict]:
    """Returns alert dict or None."""
    if is_silent(audio_np):
        return None
    try:
        result     = whisper_model.transcribe(audio_np, fp16=False)
        transcript = result.get("text", "").strip()
        if not transcript or len(transcript.split()) < 2:
            return None
        print(f"[STT] → {transcript}")
        fired, kw = keyword_triggered(transcript)
        if fired:
            return {"source": "Whisper STT", "label": f"keyword:{kw}",
                    "transcript": transcript, "confidence": None}
    except Exception as e:
        print(f"[STT] Error: {e}")
    return None


def run_yamnet(audio_np: np.ndarray) -> Optional[dict]:
    """Returns alert dict or None."""
    if is_silent(audio_np):
        return None
    try:
        scores_np   = yamnet_model(tf.constant(audio_np, dtype=tf.float32))[0].numpy()
        mean_scores = scores_np.mean(axis=0)
        peak_scores = scores_np.max(axis=0)

        best_label, best_conf, best_reason = "", 0.0, ""
        for idx, label in YAMNET_ALERT_INDICES.items():
            mean_s = float(mean_scores[idx])
            peak_s = float(peak_scores[idx])
            if mean_s >= YAMNET_MEAN_THRESHOLD and mean_s > best_conf:
                best_label, best_conf, best_reason = label, mean_s, "sustained"
            if peak_s >= YAMNET_FRAME_THRESHOLD and peak_s > best_conf:
                best_label, best_conf, best_reason = label, peak_s, "burst"

        if best_label:
            return {"source": f"YAMNet ({best_reason})", "label": best_label,
                    "transcript": None, "confidence": round(best_conf, 4)}
    except Exception as e:
        print(f"[YAMNet] Error: {e}")
    return None


def process_chunk(audio_np: np.ndarray) -> list[dict]:
    """Run both detectors on a chunk. Returns list of any alerts."""
    alerts = []
    results = [None, None]

    def stt():  results[0] = run_stt(audio_np)
    def ynn():  results[1] = run_yamnet(audio_np)

    t1, t2 = threading.Thread(target=stt), threading.Thread(target=ynn)
    t1.start(); t2.start()
    t1.join();  t2.join()

    for r in results:
        if r:
            alerts.append(r)
    return alerts


def to_float32_16k(raw_bytes: bytes, src_sample_rate: int = 44100,
                   channels: int = 1) -> np.ndarray:
    """Convert raw PCM int16 bytes → float32 numpy array at 16 kHz mono."""
    audio = np.frombuffer(raw_bytes, dtype=np.int16).astype(np.float32) / 32768.0
    if channels > 1:
        audio = audio.reshape(-1, channels)[:, 0]
    if src_sample_rate != SAMPLE_RATE:
        audio = signal.resample_poly(audio, SAMPLE_RATE, src_sample_rate).astype(np.float32)
    return audio


def load_wav_bytes(data: bytes) -> Optional[np.ndarray]:
    """Load WAV bytes → float32 16 kHz mono numpy array."""
    try:
        sr, arr = wav.read(io.BytesIO(data))
        if arr.dtype != np.float32:
            arr = arr.astype(np.float32) / np.iinfo(arr.dtype).max
        if arr.ndim > 1:
            arr = arr[:, 0]
        if sr != SAMPLE_RATE:
            arr = signal.resample_poly(arr, SAMPLE_RATE, sr).astype(np.float32)
        return arr
    except Exception as e:
        print(f"[Audio] load failed: {e}")
        return None


def save_to_supabase(file_bytes: bytes, file_name: str, alerts: list[dict]):
    """Upload the WAV file to storage and insert alert rows."""
    if not _sb:
        return
    try:
        # Upload WAV to storage bucket
        _sb.storage.from_(SUPABASE_BUCKET).upload(
            file_name, file_bytes,
            file_options={"content-type": "audio/wav", "upsert": "false"}
        )
        print(f"[Supabase] ✔ uploaded {file_name}")
    except Exception as e:
        print(f"[Supabase] Upload error: {e}")

    # Insert each alert row
    for alert in alerts:
        try:
            _sb.table("audio_detections").insert({
                "file_name":  file_name,
                "source":     alert["source"],
                "label":      alert["label"],
                "confidence": alert.get("confidence"),
                "transcript": alert.get("transcript"),
            }).execute()
        except Exception as e:
            print(f"[Supabase] Insert error: {e}")


# ─────────────────────────────────────────────────────────────────
# WEBSOCKET — live streaming from Flutter
# ─────────────────────────────────────────────────────────────────
# Flutter sends raw PCM int16 chunks over the WebSocket.
# The server accumulates them, processes overlapping 4-second windows,
# sends back JSON alert messages in real time, and at the end uploads
# the complete recording to Supabase.
#
# Message protocol:
#   Flutter → Server:
#     - binary frames: raw PCM int16 at 44100 Hz, mono
#     - text "END:<filename>" → signals recording complete
#   Server → Flutter:
#     - JSON: {"type":"alert","source":...,"label":...,"confidence":...,"transcript":...}
#     - JSON: {"type":"done","file_name":...,"alert_count":N}
# ─────────────────────────────────────────────────────────────────

@app.websocket("/ws/stream")
async def websocket_stream(websocket: WebSocket):
    await websocket.accept()
    print("[WS] Client connected")

    # Accumulate incoming raw PCM (int16, 44100 Hz, mono)
    raw_pcm_buffer  = bytearray()
    analysis_buffer = np.zeros(0, dtype=np.float32)  # 16kHz float32
    all_alerts      = []
    file_name       = f"recording_{uuid.uuid4()}.wav"

    try:
        while True:
            msg = await websocket.receive()

            # ── Text message: end signal ──────────────────────────
            if "text" in msg:
                text = msg["text"]
                if text.startswith("END:"):
                    file_name = text[4:].strip() or file_name
                    print(f"[WS] END signal — saving as '{file_name}'")

                    # Process any remaining audio in buffer
                    if len(analysis_buffer) >= SAMPLE_RATE:
                        chunk = analysis_buffer
                        if len(chunk) < CHUNK_SAMPLES:
                            chunk = np.pad(chunk, (0, CHUNK_SAMPLES - len(chunk)))
                        for alert in process_chunk(chunk):
                            all_alerts.append(alert)
                            await websocket.send_json({
                                "type": "alert", **alert
                            })

                    # Save WAV + alerts to Supabase
                    if raw_pcm_buffer:
                        wav_bytes = _pcm_to_wav_bytes(bytes(raw_pcm_buffer), 44100)
                        threading.Thread(
                            target=save_to_supabase,
                            args=(wav_bytes, file_name, all_alerts),
                            daemon=True
                        ).start()

                    await websocket.send_json({
                        "type": "done",
                        "file_name": file_name,
                        "alert_count": len(all_alerts)
                    })
                    break

            # ── Binary message: raw PCM chunk ─────────────────────
            elif "bytes" in msg:
                chunk_bytes = msg["bytes"]
                raw_pcm_buffer.extend(chunk_bytes)

                # Convert incoming int16 44100 → float32 16000
                new_audio = to_float32_16k(chunk_bytes, src_sample_rate=44100)
                analysis_buffer = np.concatenate([analysis_buffer, new_audio])

                # Process complete 4-second windows
                while len(analysis_buffer) >= CHUNK_SAMPLES:
                    window  = analysis_buffer[:CHUNK_SAMPLES].copy()
                    analysis_buffer = analysis_buffer[CHUNK_SAMPLES - OVERLAP_SAMPLES:]

                    # Run detection in a thread so we don't block the event loop
                    import asyncio
                    loop    = asyncio.get_event_loop()
                    alerts  = await loop.run_in_executor(None, process_chunk, window)

                    for alert in alerts:
                        all_alerts.append(alert)
                        print(f"[WS] 🚨 {alert['source']} — {alert['label']}")
                        await websocket.send_json({"type": "alert", **alert})

    except WebSocketDisconnect:
        print("[WS] Client disconnected")
    except Exception as e:
        print(f"[WS] Error: {e}")
        try:
            await websocket.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass


# ─────────────────────────────────────────────────────────────────
# HTTP POST — upload completed recording
# ─────────────────────────────────────────────────────────────────

@app.post("/upload")
async def upload_recording(file: UploadFile = File(...)):
    """
    Receives a completed WAV file, runs detection, saves to Supabase.
    Returns all triggered alerts.
    """
    data     = await file.read()
    audio_np = load_wav_bytes(data)
    if audio_np is None:
        raise HTTPException(400, "Could not decode audio file")

    file_name = f"recording_{uuid.uuid4()}.wav"
    alerts    = []

    step = CHUNK_SAMPLES - OVERLAP_SAMPLES
    for start in range(0, len(audio_np), step):
        chunk = audio_np[start: start + CHUNK_SAMPLES]
        if len(chunk) < SAMPLE_RATE:
            break
        if len(chunk) < CHUNK_SAMPLES:
            chunk = np.pad(chunk, (0, CHUNK_SAMPLES - len(chunk)))
        alerts.extend(process_chunk(chunk))

    # Save to Supabase in background
    threading.Thread(
        target=save_to_supabase,
        args=(data, file_name, alerts),
        daemon=True
    ).start()

    return {"file_name": file_name, "alerts": alerts, "alert_count": len(alerts)}


# ─────────────────────────────────────────────────────────────────
# HEALTH CHECK
# ─────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "supabase": _sb is not None}


# ─────────────────────────────────────────────────────────────────
# PCM → WAV HELPER
# ─────────────────────────────────────────────────────────────────

def _pcm_to_wav_bytes(pcm_bytes: bytes, sample_rate: int) -> bytes:
    """Wrap raw PCM int16 bytes in a WAV container."""
    import struct
    num_samples    = len(pcm_bytes) // 2
    num_channels   = 1
    bits_per_sample = 16
    byte_rate      = sample_rate * num_channels * bits_per_sample // 8
    block_align    = num_channels * bits_per_sample // 8
    data_size      = len(pcm_bytes)
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + data_size, b"WAVE",
        b"fmt ", 16, 1, num_channels, sample_rate,
        byte_rate, block_align, bits_per_sample,
        b"data", data_size
    )
    return header + pcm_bytes