"""
Hybrid Audio Detection Pipeline  (v6 — Supabase Integration)
=============================================================
Modes:
  1. SUPABASE MODE  — polls your Supabase storage bucket for new audio files,
                      downloads each one, runs full detection, marks as processed
  2. FILE MODE      — python hybrid_audio_detector.py audio.wav
  3. LIVE MIC MODE  — python hybrid_audio_detector.py

Install:
    pip install openai-whisper sounddevice numpy scipy tensorflow tensorflow-hub
    pip install supabase python-dotenv

Supabase setup:
  - Create a storage bucket (e.g. "audio-clips")
  - Create a table "audio_detections" to log results  (see SQL below)
  - Add a column "processed" (bool, default false) to your audio metadata table
    OR use a separate tracking table (see SUPABASE_PROCESSED_TABLE below)

SQL to create the results table in Supabase:
    create table audio_detections (
        id uuid default gen_random_uuid() primary key,
        file_name text,
        source text,
        label text,
        confidence float,
        transcript text,
        triggered_at timestamptz default now()
    );

SQL to create the processed-tracking table:
    create table processed_audio (
        file_name text primary key,
        processed_at timestamptz default now()
    );

.env file (create in same folder as this script):
    SUPABASE_URL=https://xxxx.supabase.co
    SUPABASE_KEY=your-service-role-key
    SUPABASE_BUCKET=audio-clips
    POLL_INTERVAL=10
"""

import os
import re
import csv
import threading
import queue
import time
import tempfile
import urllib.request
import warnings

os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
warnings.filterwarnings("ignore")

import numpy as np
import sounddevice as sd
import scipy.io.wavfile as wav
import whisper
import tensorflow as tf
import tensorflow_hub as hub

tf.get_logger().setLevel("ERROR")

# ── Try loading .env ──────────────────────────────────────────────
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass   # .env not used — set env vars manually

# ─────────────────────────────────────────────────────────────────
# SUPABASE CONFIGURATION  (reads from .env or environment variables)
# ─────────────────────────────────────────────────────────────────

SUPABASE_URL    = os.getenv("SUPABASE_URL",    "")       # https://xxxx.supabase.co
SUPABASE_KEY    = os.getenv("SUPABASE_KEY",    "")       # service-role key
SUPABASE_BUCKET = os.getenv("SUPABASE_BUCKET", "audio-clips")
POLL_INTERVAL   = int(os.getenv("POLL_INTERVAL", "10"))  # seconds between polls

# Table that tracks which files have already been processed
SUPABASE_PROCESSED_TABLE = "processed_audio"
# Table where detection results are logged
SUPABASE_RESULTS_TABLE   = "audio_detections"

# ─────────────────────────────────────────────────────────────────
# AUDIO / MODEL CONFIGURATION
# ─────────────────────────────────────────────────────────────────

SAMPLE_RATE      = 16000
CHUNK_DURATION   = 4
CHUNK_SAMPLES    = SAMPLE_RATE * CHUNK_DURATION
OVERLAP_DURATION = 1.0
OVERLAP_SAMPLES  = int(SAMPLE_RATE * OVERLAP_DURATION)

SILENCE_RMS_THRESHOLD  = 0.002
YAMNET_MEAN_THRESHOLD  = 0.05
YAMNET_FRAME_THRESHOLD = 0.10

WHISPER_MODEL_SIZE = "base"
DEBUG = False

NEGATION_WINDOW = 6

STT_KEYWORD_RULES = [
    ("help",               ["no", "not", "don't", "dont", "doesn't", "doesnt",
                            "didn't", "didnt", "without", "need no", "want no",
                            "i don't", "i dont", "don't need", "dont need"]),
    ("save me",            []),
    ("call police",        []),
    ("call 911",           []),
    ("call an ambulance",  []),
    ("someone help",       []),
    ("anybody help",       []),
    ("please help",        []),
    ("fire",               ["no", "not", "don't", "dont", "ceasefire", "gunfire",
                            "open fire", "rapid fire"]),
    ("there's a fire",     []),
    ("flood",              ["no", "not"]),
    ("earthquake",         []),
    ("explosion",          []),
    ("emergency",          ["no", "not", "non"]),
    ("attack",             ["no", "not", "counter", "heart attack"]),
    ("thief",              []),
    ("robbery",            []),
    ("gun",                ["no", "not", "top gun", "water gun"]),
    ("bomb",               ["no", "not", "photobomb"]),
    ("knife",              ["no", "not"]),
    ("he's got a",         []),
    ("she's got a",        []),
    ("i'm hurt",           []),
    ("i am hurt",          []),
    ("i'm bleeding",       []),
    ("i am bleeding",      []),
    ("i'm dying",          ["not", "no"]),
    ("i am dying",         ["not", "no"]),
    ("i can't breathe",    []),
    ("i cannot breathe",   []),
    ("can't breathe",      []),
    ("so much pain",       []),
    ("in pain",            ["no", "not", "without"]),
    ("it hurts",           []),
    ("i'm injured",        []),
    ("i am injured",       []),
    ("broken",             ["not", "no"]),
    ("unconscious",        []),
    ("passed out",         []),
    ("i fell",             []),
    ("i've fallen",        []),
    ("chest pain",         []),
    ("heart attack",       []),
    ("i need a doctor",    []),
    ("call a doctor",      []),
    ("overdose",           []),
    ("poisoned",           []),
    ("let me go",          []),
    ("let me out",         []),
    ("stop hurting",       []),
    ("don't touch me",     []),
    ("get away from me",   []),
    ("leave me alone",     ["please"]),
    ("i'm being followed", []),
    ("following me",       []),
    ("kidnap",             []),
    ("abduct",             []),
    ("rape",               []),
    ("assault",            []),
    ("accident",           ["no", "not"]),
    ("crash",              ["no", "not"]),
    ("i've been hit",      []),
]

YAMNET_ALERT_SUBSTRINGS = [
    "scream", "screaming", "crying", "sobbing", "yell", "yelling",
    "shout", "wail", "wailing", "moan",
    "fire alarm", "smoke detector", "gunshot", "gun",
    "explosion", "glass", "breaking", "siren", "alarm",
]

YAMNET_CLASS_MAP_URL = (
    "https://raw.githubusercontent.com/tensorflow/models/master/"
    "research/audioset/yamnet/yamnet_class_map.csv"
)


# ─────────────────────────────────────────────────────────────────
# ALERT HANDLER
# ─────────────────────────────────────────────────────────────────

# Filled in after Supabase client is initialised (if available)
_supabase_client = None

def trigger_alert(source, label, confidence=None, transcript=None, file_name=None):
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
    if file_name:
        print(f"  File       : {file_name}")
    print(border)

    # ── Log result to Supabase audio_detections table ─────────────
    if _supabase_client:
        try:
            _supabase_client.table(SUPABASE_RESULTS_TABLE).insert({
                "file_name":  file_name or "live-mic",
                "source":     source,
                "label":      label,
                "confidence": round(confidence, 4) if confidence else None,
                "transcript": transcript,
            }).execute()
        except Exception as e:
            print(f"[Supabase] Failed to log alert: {e}")


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
    print(f"⚠  Label fetch failed ({e}). Using fallback.")
    YAMNET_ALERT_INDICES = {
        11: "screaming", 19: "crying, sobbing", 22: "wail, moan",
        390: "siren", 393: "smoke detector", 394: "fire alarm",
        420: "explosion", 421: "gunshot, gunfire",
        435: "glass", 464: "breaking",
    }


# ─────────────────────────────────────────────────────────────────
# SILENCE GATE
# ─────────────────────────────────────────────────────────────────

def is_silent(audio_np):
    return float(np.sqrt(np.mean(audio_np ** 2))) < SILENCE_RMS_THRESHOLD


# ─────────────────────────────────────────────────────────────────
# KEYWORD MATCHING
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

def run_stt_detection(audio_np, file_name=None):
    if is_silent(audio_np):
        return
    try:
        result     = whisper_model.transcribe(audio_np, fp16=False)
        transcript = result.get("text", "").strip()
        if not transcript:
            return
        if len(transcript.split()) < 2:
            standalone_kws = [kw for kw, _ in STT_KEYWORD_RULES if " " not in kw]
            if transcript.lower() not in standalone_kws:
                return
        print(f"[STT] → {transcript}")
        fired, kw = keyword_triggered(transcript)
        if fired:
            trigger_alert("Whisper STT", f"Keyword: '{kw}'",
                          transcript=transcript, file_name=file_name)
    except Exception as e:
        print(f"[STT] Error: {e}")


# ─────────────────────────────────────────────────────────────────
# YAMNET DETECTOR
# ─────────────────────────────────────────────────────────────────

def run_yamnet_detection(audio_np, file_name=None):
    if is_silent(audio_np):
        return
    try:
        waveform  = tf.constant(audio_np, dtype=tf.float32)
        scores, _emb, _spec = yamnet_model(waveform)
        scores_np   = scores.numpy()
        mean_scores = scores_np.mean(axis=0)
        peak_scores = scores_np.max(axis=0)

        if DEBUG:
            top5 = np.argsort(mean_scores)[::-1][:5]
            print("[YAMNet] top-5:", [(i, yamnet_all_labels.get(i,"?"),
                                       f"{mean_scores[i]:.3f}") for i in top5])

        fired_label, fired_conf, fired_reason = "", 0.0, ""
        for idx, label in YAMNET_ALERT_INDICES.items():
            mean_s = float(mean_scores[idx])
            peak_s = float(peak_scores[idx])
            if mean_s >= YAMNET_MEAN_THRESHOLD and mean_s > fired_conf:
                fired_label, fired_conf, fired_reason = label, mean_s, "sustained"
            if peak_s >= YAMNET_FRAME_THRESHOLD and peak_s > fired_conf:
                fired_label, fired_conf, fired_reason = label, peak_s, "burst"

        if fired_label:
            trigger_alert(f"YAMNet ({fired_reason})", fired_label.title(),
                          confidence=fired_conf, file_name=file_name)
    except Exception as e:
        print(f"[YAMNet] Error: {e}")


# ─────────────────────────────────────────────────────────────────
# CORE: ANALYSE A NUMPY AUDIO ARRAY  (shared by all modes)
# ─────────────────────────────────────────────────────────────────

def analyze_audio_array(audio_np: np.ndarray, file_name: str = None):
    """
    Run the full detection pipeline on a float32 16 kHz mono numpy array.
    Splits into overlapping chunks and processes each in parallel.
    """
    step = CHUNK_SAMPLES - OVERLAP_SAMPLES
    for start in range(0, len(audio_np), step):
        chunk = audio_np[start: start + CHUNK_SAMPLES]
        if len(chunk) < SAMPLE_RATE:
            break
        if len(chunk) < CHUNK_SAMPLES:
            chunk = np.pad(chunk, (0, CHUNK_SAMPLES - len(chunk)))
        t1 = threading.Thread(target=run_stt_detection,
                               args=(chunk,), kwargs={"file_name": file_name}, daemon=True)
        t2 = threading.Thread(target=run_yamnet_detection,
                               args=(chunk,), kwargs={"file_name": file_name}, daemon=True)
        t1.start(); t2.start()
        t1.join();  t2.join()


# ─────────────────────────────────────────────────────────────────
# SUPABASE MODE
# ─────────────────────────────────────────────────────────────────

def init_supabase():
    """Initialise the Supabase client. Returns client or None on failure."""
    global _supabase_client
    try:
        from supabase import create_client
        if not SUPABASE_URL or not SUPABASE_KEY:
            print("⚠  SUPABASE_URL / SUPABASE_KEY not set. Supabase mode unavailable.")
            return None
        _supabase_client = create_client(SUPABASE_URL, SUPABASE_KEY)
        print(f"✔  Supabase connected → bucket: '{SUPABASE_BUCKET}'")
        return _supabase_client
    except ImportError:
        print("⚠  supabase-py not installed. Run: pip install supabase")
        return None
    except Exception as e:
        print(f"⚠  Supabase init failed: {e}")
        return None


def get_unprocessed_files(sb):
    """
    Returns a list of file names in the bucket that haven't been processed yet.

    Strategy:
      - List all files in the bucket
      - Query the processed_audio table for already-processed names
      - Return the difference
    """
    try:
        # List all files in bucket (top-level; adjust prefix if files are in sub-folders)
        bucket_files = sb.storage.from_(SUPABASE_BUCKET).list()
        all_names    = {f["name"] for f in bucket_files if f.get("name")}

        # Fetch processed names
        resp = sb.table(SUPABASE_PROCESSED_TABLE).select("file_name").execute()
        done = {row["file_name"] for row in (resp.data or [])}

        pending = sorted(all_names - done)
        if pending:
            print(f"[Supabase] {len(pending)} new file(s) to process: {pending}")
        return pending
    except Exception as e:
        print(f"[Supabase] Error listing files: {e}")
        return []


def download_to_tempfile(sb, file_name: str) -> str | None:
    """
    Download a file from Supabase storage to a local temp file.
    Returns the temp file path, or None on failure.
    """
    try:
        print(f"[Supabase] Downloading: {file_name} …")
        data = sb.storage.from_(SUPABASE_BUCKET).download(file_name)

        # Determine extension so scipy can read it correctly
        ext  = os.path.splitext(file_name)[-1] or ".wav"
        tmp  = tempfile.NamedTemporaryFile(delete=False, suffix=ext)
        tmp.write(data)
        tmp.close()
        print(f"[Supabase] Saved to temp: {tmp.name}")
        return tmp.name
    except Exception as e:
        print(f"[Supabase] Download failed for '{file_name}': {e}")
        return None


def mark_as_processed(sb, file_name: str):
    """Insert the file name into the processed_audio tracking table."""
    try:
        sb.table(SUPABASE_PROCESSED_TABLE).insert({"file_name": file_name}).execute()
    except Exception as e:
        print(f"[Supabase] Failed to mark '{file_name}' as processed: {e}")


def load_wav_to_array(filepath: str) -> np.ndarray | None:
    """
    Load a WAV file into a float32 16 kHz mono numpy array.
    Handles resampling from common sample rates automatically.
    """
    try:
        sr, data = wav.read(filepath)

        # Convert to float32
        if data.dtype != np.float32:
            max_val = np.iinfo(data.dtype).max if np.issubdtype(data.dtype, np.integer) else 1.0
            data    = data.astype(np.float32) / max_val

        # Mono
        if data.ndim > 1:
            data = data[:, 0]

        # Resample to 16 kHz if needed (simple decimation / interpolation)
        if sr != SAMPLE_RATE:
            print(f"[Audio] Resampling {sr} Hz → {SAMPLE_RATE} Hz …")
            try:
                import scipy.signal as signal
                data = signal.resample_poly(data, SAMPLE_RATE, sr).astype(np.float32)
            except Exception:
                print(f"[Audio] scipy resample failed — use ffmpeg to pre-convert:\n"
                      f"  ffmpeg -i input.wav -ar {SAMPLE_RATE} -ac 1 output.wav")
                return None

        return data
    except Exception as e:
        print(f"[Audio] Failed to load '{filepath}': {e}")
        return None


def process_supabase_file(sb, file_name: str):
    """Download, analyse, mark processed, clean up temp file."""
    tmp_path = download_to_tempfile(sb, file_name)
    if not tmp_path:
        return

    try:
        audio_np = load_wav_to_array(tmp_path)
        if audio_np is None:
            print(f"[Audio] Skipping '{file_name}' — could not load.")
            return

        print(f"[Analysis] Processing '{file_name}' "
              f"({len(audio_np)/SAMPLE_RATE:.1f}s) …")
        analyze_audio_array(audio_np, file_name=file_name)
        mark_as_processed(sb, file_name)
        print(f"[Supabase] ✔ '{file_name}' done.")
    finally:
        try:
            os.remove(tmp_path)
        except Exception:
            pass


def start_supabase_polling(sb):
    """
    Continuously polls Supabase storage for new audio files and processes them.
    Runs until Ctrl+C.
    """
    print(f"\n☁️  Supabase polling mode — checking every {POLL_INTERVAL}s\n"
          f"    Bucket  : {SUPABASE_BUCKET}\n"
          f"    Results : {SUPABASE_RESULTS_TABLE}\n")

    while True:
        pending = get_unprocessed_files(sb)
        for file_name in pending:
            process_supabase_file(sb, file_name)

        if not pending:
            print(f"[Supabase] No new files. Waiting {POLL_INTERVAL}s …", end="\r")

        time.sleep(POLL_INTERVAL)


# ─────────────────────────────────────────────────────────────────
# LIVE MIC MODE
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
# FILE MODE
# ─────────────────────────────────────────────────────────────────

def analyze_file(filepath: str):
    print(f"\n📂 Analysing: {filepath}")
    audio_np = load_wav_to_array(filepath)
    if audio_np is None:
        return
    analyze_audio_array(audio_np, file_name=os.path.basename(filepath))
    print("\n✔  Done.")


# ─────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import sys

    if "--debug" in sys.argv:
        DEBUG = True
        sys.argv.remove("--debug")

    args = [a for a in sys.argv[1:] if not a.startswith("--")]

    if args:
        # File mode
        analyze_file(args[0])

    elif SUPABASE_URL and SUPABASE_KEY:
        # Supabase polling mode (auto-detected when env vars are set)
        sb = init_supabase()
        if sb:
            try:
                start_supabase_polling(sb)
            except KeyboardInterrupt:
                print("\n⏹  Stopped.")
        else:
            start_realtime_listening()

    else:
        # Live mic fallback
        start_realtime_listening()