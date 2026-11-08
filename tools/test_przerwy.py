#!/usr/bin/env python3
"""
test_przerwy.py – czy przerwy między klatkami spowalniają analizę?

Mierzy czas jednej analizy OpenVINO (CPU) w dwóch trybach:
  ciągiem        – analiza za analizą (jak benchmark_app)
  z przerwami    – po każdej analizie pauza (jak w usłudze: ~2 klatki/s)
dla 2 i 4 wątków. Na czas testu zatrzymaj usługę: sudo systemctl stop szukaj_cpu@$USER

  /opt/szukaj_cpu/venv/bin/python /opt/szukaj_cpu/tools/test_przerwy.py
  /opt/szukaj_cpu/venv/bin/python /opt/szukaj_cpu/tools/test_przerwy.py --model ~/.szukaj_cpu/models/yolo11s_960x544_openvino_model/yolo11s.xml --pause 0.5
"""
import argparse
import os
import statistics
import time

import numpy as np
import openvino as ov


def cpu_mhz():
    try:
        vals = [int(open(f"/sys/devices/system/cpu/cpu{i}/cpufreq/scaling_cur_freq").read()) / 1000
                for i in range(os.cpu_count() or 1)]
        return sum(vals) / len(vals)
    except OSError:
        return float("nan")


def measure(compiled, x, n, pause):
    req = compiled.create_infer_request()
    for _ in range(3):                      # rozgrzewka
        req.infer({0: x})
    times, mhz = [], []
    for _ in range(n):
        if pause:
            time.sleep(pause)
        mhz.append(cpu_mhz())               # taktowanie tuż przed analizą
        t0 = time.perf_counter()
        req.infer({0: x})
        times.append((time.perf_counter() - t0) * 1000)
    return statistics.median(times), statistics.mean(times), statistics.median(mhz)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.path.expanduser(
        "~/.szukaj_cpu/models/yolo11s_960x544_openvino_model/yolo11s.xml"))
    ap.add_argument("--pause", type=float, default=0.5, help="przerwa między analizami (s)")
    ap.add_argument("-n", type=int, default=30, help="liczba pomiarów w każdym wariancie")
    a = ap.parse_args()

    core = ov.Core()
    model = core.read_model(a.model)
    shape = [d.get_length() for d in model.input(0).get_partial_shape()]
    x = np.random.rand(*shape).astype(np.float32)

    try:
        epp = open("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference").read().strip()
    except OSError:
        epp = "?"
    print(f"Model: {os.path.basename(a.model)}  wejście {shape}  EPP: {epp}  przerwa: {a.pause} s\n")
    print(f"{'wątki':>6} {'tryb':<14} {'mediana ms':>11} {'średnia ms':>11} {'MHz przed':>10}")
    for threads in (2, 4):
        compiled = core.compile_model(model, "CPU", {"INFERENCE_NUM_THREADS": threads,
                                                     "PERFORMANCE_HINT": "LATENCY"})
        for name, pause in (("ciągiem", 0.0), ("z przerwami", a.pause)):
            med, avg, mhz = measure(compiled, x, a.n, pause)
            print(f"{threads:>6} {name:<14} {med:>11.0f} {avg:>11.0f} {mhz:>10.0f}")


if __name__ == "__main__":
    main()
