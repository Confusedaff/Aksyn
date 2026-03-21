"""
Hybrid Audio Detection Pipeline  (v5)
===============================================
Changes vs v4:
  1. Expanded distress keyword list  — pain, injury, threat phrases added
  2. Scream fix: per-frame threshold — if ANY single frame scores >= FRAME_THRESHOLD
                                       for a scream class, alert fires immediately
                                       (doesn't wait for peak/mean average)
  3. TF deprecation warnings hidden  — cleaner console output

Install:
    pip install openai-whisper sounddevice numpy scipy tensorflow tensorflow-hub

Run:
    python hybrid_audio_detector.py            # live mic
    python hybrid_audio_detector.py audio.wav  # file
    python hybrid_audio_detector.py --debug    # live mic + YAMNet debug scores
"""

import os
import re
import csv
import threading
import queue
import time
import urllib.request
import warnings

# Suppress TF/Keras deprecation noise
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
warnings.filterwarnings("ignore")

import numpy as np
import sounddevice as sd
import scipy.io.wavfile as wav
import whisper
import tensorflow as tf
import tensorflow_hub as hub

tf.get_logger().setLevel("ERROR")

# ─────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────

SAMPLE_RATE      = 16000
CHUNK_DURATION   = 4           # seconds per analysis window
CHUNK_SAMPLES    = SAMPLE_RATE * CHUNK_DURATION
OVERLAP_DURATION = 1.0
OVERLAP_SAMPLES  = int(SAMPLE_RATE * OVERLAP_DURATION)

SILENCE_RMS_THRESHOLD = 0.002  # Lowered from 0.01

# YAMNet thresholds
YAMNET_MEAN_THRESHOLD  = 0.05  # Lowered from 0.10
YAMNET_FRAME_THRESHOLD = 0.10  # Lowered from 0.20
#   ↑ If a SINGLE frame of the chunk scores above this for a scream/alarm class,
#     it triggers regardless of the mean. Catches short screams that average out.

WHISPER_MODEL_SIZE = "base"
DEBUG = False   # set True or pass --debug to see YAMNet raw scores


# ─────────────────────────────────────────────────────────────────
# KEYWORD RULES  (keyword, [negation words])
# ─────────────────────────────────────────────────────────────────

NEGATION_WINDOW = 6

STT_KEYWORD_RULES = [

    # ── Direct distress calls ─────────────────────────────────────
    ("help",              ["no", "not", "don't", "dont", "doesn't", "doesnt",
                           "didn't", "didnt", "without", "need no", "want no",
                           "i don't", "i dont", "don't need", "dont need"]),
    ("save me",           []),
    ("call police",       []),
    ("call 911",          []),
    ("call an ambulance", []),
    ("someone help",      []),
    ("anybody help",      []),
    ("please help",       []),

    # ── Fire / disaster ───────────────────────────────────────────
    ("fire",              ["no", "not", "don't", "dont", "ceasefire", "gunfire",
                           "open fire", "rapid fire"]),
    ("there's a fire",    []),
    ("flood",             ["no", "not"]),
    ("earthquake",        []),
    ("explosion",         []),
    ("emergency",         ["no", "not", "non"]),

    # ── Violence / threat ─────────────────────────────────────────
    ("attack",            ["no", "not", "counter", "heart attack"]),
    ("thief",             []),
    ("robbery",           []),
    ("gun",               ["no", "not", "top gun", "water gun"]),
    ("bomb",              ["no", "not", "photobomb"]),
    ("knife",             ["no", "not"]),
    ("he's got a",        []),
    ("she's got a",       []),

    # ── Pain & injury ─────────────────────────────────────────────
    ("i'm hurt",          []),
    ("i am hurt",         []),
    ("i'm bleeding",      []),
    ("i am bleeding",     []),
    ("i'm dying",         ["not", "no"]),
    ("i am dying",        ["not", "no"]),
    ("i can't breathe",   []),
    ("i cannot breathe",  []),
    ("can't breathe",     []),
    ("so much pain",      []),
    ("in pain",           ["no", "not", "without"]),
    ("it hurts",          []),
    ("i'm injured",       []),
    ("i am injured",      []),
    ("broken",            ["not", "no"]),   # "my leg is broken"
    ("unconscious",       []),
    ("passed out",        []),
    ("i fell",            []),
    ("i've fallen",       []),
    ("chest pain",        []),
    ("heart attack",      []),
    ("i need a doctor",   []),
    ("call a doctor",     []),
    ("overdose",          []),
    ("poisoned",          []),

    # ── Abduction / assault ───────────────────────────────────────
    ("let me go",         []),
    ("let me out",        []),
    ("stop hurting",      []),
    ("don't touch me",    []),
    ("get away from me",  []),
    ("leave me alone",    ["please"]),   # "please leave me alone" is ambiguous but ok
    ("i'm being followed",  []),
    ("following me",      []),
    ("kidnap",            []),
    ("abduct",            []),
    ("rape",              []),
    ("assault",           []),

    # ── Accident ─────────────────────────────────────────────────
    ("accident",          ["no", "not"]),
    ("crash",             ["no", "not"]),
    ("i've been hit",     []),
]


# ─────────────────────────────────────────────────────────────────
# YAMNET LABEL CONFIG
# ─────────────────────────────────────────────────────────────────

YAMNET_ALERT_SUBSTRINGS = [
    "scream", "screaming",
    "crying", "sobbing",
    "yell", "yelling",
    "shout",
    "wail", "wailing", "moan",
    "fire alarm", "smoke detector",
    "gunshot", "gun",
    "explosion",
    "glass", "breaking",
    "siren",
    "alarm",
]

YAMNET_CLASS_MAP_URL = (
    "https://raw.githubusercontent.com/tensorflow/models/master/"
    "research/audioset/yamnet/yamnet_class_map.csv"
)


# ─────────────────────────────────────────────────────────────────
# ALERT HANDLER  — replace / extend with SMS, webhook, etc.
# ─────────────────────────────────────────────────────────────────

def trigger_alert(source, label, confidence=None, transcript=None):
    timestamp = time.strftime("%H:%M:%S")
    border    = "=" * 60
    print(f"\n🚨 ALERT TRIGGERED @ {timestamp}")
    print(border)
    print(f"  Source     : {source}")
    print(f"  Label      : {label}")
    if confidence is not None:
        print(f"  Confidence : {confidence:.2%}")
    if transcript:
        print(f"  Transcript : \"{transcript}\"")
    print(border)
    # send_sms(...)
    # post_webhook(...)


# ─────────────────────────────────────────────────────────────────
# MODEL LOADING
# ─────────────────────────────────────────────────────────────────

print("Loading Whisper model …")
whisper_model = whisper.load_model(WHISPER_MODEL_SIZE)
print(f"✔  Whisper '{WHISPER_MODEL_SIZE}' ready.")

print("Loading YAMNet model …")
yamnet_model = hub.load("https://tfhub.dev/google/yamnet/1")
print("✔  YAMNet ready.")

print("Fetching YAMNet class labels …")
yamnet_all_labels = {}
try:
    with urllib.request.urlopen(YAMNET_CLASS_MAP_URL, timeout=10) as resp:
        lines = resp.read().decode("utf-8").splitlines()
    for row in csv.DictReader(lines):
        yamnet_all_labels[int(row["index"])] = row["display_name"].lower()

    YAMNET_ALERT_INDICES = {
        idx: lbl for idx, lbl in yamnet_all_labels.items()
        if any(sub in lbl for sub in YAMNET_ALERT_SUBSTRINGS)
    }
    print(f"✔  Matched {len(YAMNET_ALERT_INDICES)} YAMNet alert classes:")
    for idx, lbl in sorted(YAMNET_ALERT_INDICES.items()):
        print(f"     [{idx:3d}] {lbl}")
except Exception as e:
    print(f"⚠  Label fetch failed ({e}). Using fallback indices.")
    YAMNET_ALERT_INDICES = {
        11: "screaming", 19: "crying, sobbing", 22: "wail, moan",
        390: "siren", 393: "smoke detector", 394: "fire alarm",
        420: "explosion", 421: "gunshot, gunfire",
        435: "glass", 464: "breaking",
    }


# ─────────────────────────────────────────────────────────────────
# SILENCE GATE
# ─────────────────────────────────────────────────────────────────

def is_silent(audio_np: np.ndarray) -> bool:
    return float(np.sqrt(np.mean(audio_np ** 2))) < SILENCE_RMS_THRESHOLD


# ─────────────────────────────────────────────────────────────────
# NEGATION-AWARE KEYWORD MATCHING
# ─────────────────────────────────────────────────────────────────

def _tokenize(text):
    return re.findall(r"[a-z']+", text.lower())

def keyword_triggered(transcript):
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


# ─────────────────────────────────────────────────────────────────
# STT DETECTOR
# ─────────────────────────────────────────────────────────────────

def run_stt_detection(audio_np: np.ndarray):
    if is_silent(audio_np):
        return
    try:
        result     = whisper_model.transcribe(audio_np, fp16=False, language="en")
        transcript = result.get("text", "").strip()
        if not transcript:
            return
        # Suppress single-word noise unless it's a standalone keyword
        if len(transcript.split()) < 2:
            standalone_kws = [kw for kw, _ in STT_KEYWORD_RULES if " " not in kw]
            if transcript.lower() not in standalone_kws:
                return

        print(f"[STT] → {transcript}")
        fired, kw = keyword_triggered(transcript)
        if fired:
            trigger_alert("Whisper STT", f"Keyword: '{kw}'", transcript=transcript)
    except Exception as e:
        print(f"[STT] Error: {e}")


# ─────────────────────────────────────────────────────────────────
# YAMNET DETECTOR  — mean threshold + per-frame burst detection
# ─────────────────────────────────────────────────────────────────

def run_yamnet_detection(audio_np: np.ndarray):
    if is_silent(audio_np):
        return
    try:
        waveform  = tf.constant(audio_np, dtype=tf.float32)
        scores, _emb, _spec = yamnet_model(waveform)
        scores_np = scores.numpy()          # shape: (num_frames, 521)

        mean_scores = scores_np.mean(axis=0)
        peak_scores = scores_np.max(axis=0)

        if DEBUG:
            top5 = np.argsort(mean_scores)[::-1][:5]
            print("[YAMNet] top-5 mean:", [
                (idx, yamnet_all_labels.get(idx, "?"), f"{mean_scores[idx]:.3f}")
                for idx in top5
            ])
            # Also show best alert-class score
            alert_scores = {idx: float(peak_scores[idx]) for idx in YAMNET_ALERT_INDICES}
            best_debug = max(alert_scores, key=alert_scores.get)
            print(f"[YAMNet] best alert class peak: [{best_debug}] "
                  f"'{YAMNET_ALERT_INDICES[best_debug]}' "
                  f"@ {alert_scores[best_debug]:.3f}")

        fired_label, fired_conf, fired_reason = "", 0.0, ""

        for idx, label in YAMNET_ALERT_INDICES.items():
            mean_s = float(mean_scores[idx])
            peak_s = float(peak_scores[idx])

            # Method A: sustained sound (mean score)
            if mean_s >= YAMNET_MEAN_THRESHOLD:
                if mean_s > fired_conf:
                    fired_label, fired_conf, fired_reason = label, mean_s, "sustained"

            # Method B: short burst like a scream (single-frame peak)
            if peak_s >= YAMNET_FRAME_THRESHOLD:
                if peak_s > fired_conf:
                    fired_label, fired_conf, fired_reason = label, peak_s, "burst"
            
            # Method C: Relative dominance (Alert class is in the top 3 overall)
            elif idx in np.argsort(mean_scores)[-3:]: 
                if mean_s > fired_conf:
                    fired_label, fired_conf, fired_reason = label, mean_s, "top-3 presence"

        if fired_label:
            trigger_alert(
                source=f"YAMNet ({fired_reason})",
                label=fired_label.title(),
                confidence=fired_conf,
            )

    except Exception as e:
        print(f"[YAMNet] Error: {e}")


# ─────────────────────────────────────────────────────────────────
# WORKER QUEUE
# ─────────────────────────────────────────────────────────────────

audio_queue: queue.Queue = queue.Queue()

def processing_worker():
    while True:
        chunk = audio_queue.get()
        if chunk is None:
            break
        t1 = threading.Thread(target=run_stt_detection,    args=(chunk,), daemon=True)
        t2 = threading.Thread(target=run_yamnet_detection, args=(chunk,), daemon=True)
        t1.start(); t2.start()
        t1.join();  t2.join()
        audio_queue.task_done()


# ─────────────────────────────────────────────────────────────────
# REAL-TIME MIC STREAM
# ─────────────────────────────────────────────────────────────────

_buffer = np.zeros(0, dtype=np.float32)

def audio_callback(indata, frames, time_info, status):
    global _buffer
    mono    = indata[:, 0].astype(np.float32)
    _buffer = np.concatenate([_buffer, mono])
    while len(_buffer) >= CHUNK_SAMPLES:
        chunk   = _buffer[:CHUNK_SAMPLES].copy()
        _buffer = _buffer[CHUNK_SAMPLES - OVERLAP_SAMPLES:]
        audio_queue.put(chunk)

def start_realtime_listening():
    print("\n🎙  Listening on microphone … (press Ctrl+C to stop)\n")
    worker = threading.Thread(target=processing_worker, daemon=True)
    worker.start()
    try:
        with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                            blocksize=int(SAMPLE_RATE * 0.1), callback=audio_callback):
            while True:
                time.sleep(0.1)
    except KeyboardInterrupt:
        print("\n⏹  Stopped.")
    finally:
        audio_queue.put(None)
        worker.join(timeout=5)


# ─────────────────────────────────────────────────────────────────
# FILE ANALYSIS
# ─────────────────────────────────────────────────────────────────

def analyze_file(filepath: str):
    print(f"\n📂 Analysing: {filepath}")
    sr, data = wav.read(filepath)
    if sr != SAMPLE_RATE:
        raise ValueError(f"Resample first:\n"
                         f"  ffmpeg -i {filepath} -ar {SAMPLE_RATE} -ac 1 out.wav")
    if data.dtype != np.float32:
        data = data.astype(np.float32) / np.iinfo(data.dtype).max
    if data.ndim > 1:
        data = data[:, 0]

    step = CHUNK_SAMPLES - OVERLAP_SAMPLES
    for start in range(0, len(data), step):
        chunk = data[start: start + CHUNK_SAMPLES]
        if len(chunk) < SAMPLE_RATE:
            break
        if len(chunk) < CHUNK_SAMPLES:
            chunk = np.pad(chunk, (0, CHUNK_SAMPLES - len(chunk)))
        t1 = threading.Thread(target=run_stt_detection,    args=(chunk,), daemon=True)
        t2 = threading.Thread(target=run_yamnet_detection, args=(chunk,), daemon=True)
        t1.start(); t2.start()
        t1.join();  t2.join()
    print("\n✔  Done.")


# ─────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import sys
    if "--debug" in sys.argv:
        DEBUG = True
        sys.argv.remove("--debug")
    if len(sys.argv) > 1:
        analyze_file(sys.argv[1])
    else:
        start_realtime_listening()