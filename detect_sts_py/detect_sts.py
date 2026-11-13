#!/usr/bin/env python3
"""
Python-модель detect_sts.v (см. ../detect_sts/src/detect_sts.v) - принимает
на вход файл с IQ-отсчётами и печатает номера отсчётов, на которых
short_preamble_detected взводится (передний фронт).

Алгоритм максимально повторяет RTL: скользящее окно ровно в 32 отсчёта
(WINDOW_SHIFT=5, как WINDOW_SHIFT в detect_sts.v), задержка на 32 отсчёта
(период S0 liquid-dsp, как DELAY / delay_ctl fifo_sample_delay_inst),
приближённая величина модуля
(alpha-max-beta-min, как complex_to_mag.v - НЕ настоящий sqrt), комплексное
умножение и накопление сумм - всё на голой целочисленной арифметике,
БЕЗ numpy/cmath/statistics и т.п.

Формат входного файла (по умолчанию): сырой бинарник, 4 байта на отсчёт,
little-endian int16, порядок байт [Q_lo, Q_hi, I_lo, I_hi] - тот же формат,
что tx_iq_dump.cf32 / iq_from_ila.bin в этом проекте (см. чат). Флаг
--format cf32 переключает на другой формат, встречавшийся в этом проекте
(iq_dump_one1.cf32): сырой complex64 (float32 real, float32 imag), без
заголовка - значения масштабируются на 32767 и округляются до целых, т.к.
sample_in в RTL - целочисленное/fixed-point поле, а не float.
"""

"""
ZSE: liquid-dsp STS детекция должна идти с периодом 32 а не 16
Экспериментально плато гдето 70 на 48 присутствуют ложные срабатывания 
"""
import argparse
import csv
import struct


WINDOW_SHIFT = 5            # WINDOW_SHIFT (LOG2_AVG_LEN) в detect_sts.v - окно усреднения = 32 отсчёта
WINDOW = 1 << WINDOW_SHIFT
DELAY_CTL = 32             # DELAY (delay_ctl у fifo_sample_delay_inst) в detect_sts.v


def load_int16(path):
    """[Q_lo, Q_hi, I_lo, I_hi] на 4-байтный отсчёт, little-endian int16."""
    with open(path, "rb") as f:
        data = f.read()
    n = len(data) // 4
    samples = []
    for k in range(n):
        q = struct.unpack_from("<h", data, k * 4 + 0)[0]
        i = struct.unpack_from("<h", data, k * 4 + 2)[0]
        samples.append((i, q))
    return samples


def load_cf32(path):
    """Сырой complex64: float32 real, float32 imag, без заголовка. Значения
    в iq_dump_one1.cf32 уже в разумном целочисленном диапазоне (сотни -
    единицы тысяч, не нормированы в [-1,1]) - просто округляются до целых,
    без дополнительного масштабирования."""
    with open(path, "rb") as f:
        data = f.read()
    n = len(data) // 8
    samples = []
    for k in range(n):
        re, im = struct.unpack_from("<ff", data, k * 8)
        i = int(round(re))
        q = int(round(im))
        samples.append((i, q))
    return samples


def mag_sq(i, q):
    """complex_to_mag_sq.v: mag_sq = i*i + q*q."""
    return i * i + q * q


def mag_approx(i, q):
    """complex_to_mag.v: alpha-max-beta-min приближение -
    mag = max(|i|,|q|) + (min(|i|,|q|) >> 2) - НЕ настоящий sqrt(i^2+q^2)."""
    ai = i if i >= 0 else -i
    aq = q if q >= 0 else -q
    if ai > aq:
        return ai + (aq >> 2)
    else:
        return aq + (ai >> 2)


def complex_mult(a_i, a_q, b_i, b_q):
    """Обычное комплексное умножение p = a*b (вызывающий код сам заранее
    меняет знак b_q для получения a*conj(b) - та же схема, что
    sample_delayed_conj в detect_sts.v)."""
    p_i = a_i * b_i - a_q * b_q
    p_q = a_i * b_q + a_q * b_i
    return p_i, p_q


class MovingSum:
    """Скользящая сумма по последним WINDOW отсчётам - повторяет
    running_total в mv_avg.v (push нового, вытеснение самого старого один
    раз окно заполнилось; data_out = running_total >> WINDOW_SHIFT)."""

    def __init__(self):
        self.history = []
        self.total = 0

    def push(self, value):
        self.history.append(value)
        self.total += value
        has_been_full = len(self.history) > WINDOW - 1
        if has_been_full and len(self.history) > WINDOW:
            self.total -= self.history.pop(0)
        avg = self.total >> WINDOW_SHIFT
        return avg, has_been_full


CSV_FIELDS = [
    "n", "i", "q", "mag_sq", "mag_sq_avg",
    "prod_i", "prod_q", "prod_avg_i", "prod_avg_q",
    "delay_prod_avg_mag_stb", "delay_prod_avg_mag", "prod_thres",
    "has_pos", "has_neg", "pos_count", "neg_count",
    "plateau_count", "short_preamble_detected",
]


def run_detect_sts(samples, min_plateau=8, threshold_scale=0, csv_writer=None):
    """Потактовая (пооотсчётная) модель always-блока detect_sts.v.
    Возвращает список номеров отсчётов n, на которых
    short_preamble_detected взводится (только передний фронт импульса).

    csv_writer (опционально) - csv.DictWriter с колонками CSV_FIELDS: если
    передан, на каждый отсчёт пишется строка со всеми промежуточными
    значениями каждого блока (для отладки, аналог DIAG-вывода в SV
    тестбенчах этого проекта)."""

    mag_sq_avg_mov = MovingSum()
    prod_i_mov = MovingSum()
    prod_q_mov = MovingSum()

    # регистровое состояние (семантика NBA: справа - СТАРЫЕ значения,
    # новые фиксируются одновременно в конце итерации - как в always-блоке)
    pos_count = 0
    neg_count = 0
    min_pos = 0
    min_neg = 0
    has_pos = False
    has_neg = False
    plateau_count = 0
    prod_thres = 0

    detections = []
    prev_detected = False

    delay_buf = []  # последние DELAY_CTL отсчётов для fifo_sample_delay

    for n, (i, q) in enumerate(samples):
        # complex_to_mag_sq + mv_avg (mag_sq_avg_inst)
        mag_sq_avg, _ = mag_sq_avg_mov.push(mag_sq(i, q))

        # fifo_sample_delay (delay_ctl=DELAY_CTL) + конъюгация
        delayed = delay_buf[-DELAY_CTL] if len(delay_buf) >= DELAY_CTL else None
        delay_buf.append((i, q))

        # delay_prod_inst (complex_mult) + mv_avg_dual_ch (delay_prod_avg_inst)
        prod_i = prod_q = prod_avg_i = prod_avg_q = 0
        delay_prod_avg_mag_stb = False
        delay_prod_avg_mag = 0
        if delayed is not None:
            d_i, d_q = delayed
            prod_i, prod_q = complex_mult(i, q, d_i, -d_q)  # a*conj(b)
            prod_avg_i, valid_i = prod_i_mov.push(prod_i)
            prod_avg_q, valid_q = prod_q_mov.push(prod_q)
            delay_prod_avg_mag_stb = valid_i and valid_q
            if delay_prod_avg_mag_stb:
                delay_prod_avg_mag = mag_approx(prod_avg_i, prod_avg_q)

        # --- регистровые обновления (все считаются от СТАРОГО состояния) ---
        new_min_pos = min_plateau >> 2
        new_min_neg = min_plateau >> 2
        new_has_pos = pos_count > min_pos
        new_has_neg = neg_count > min_neg
        if threshold_scale:
            new_prod_thres = (mag_sq_avg >> 2) + (mag_sq_avg >> 3)
        else:
            new_prod_thres = (mag_sq_avg >> 1) + (mag_sq_avg >> 2)

        new_pos_count = pos_count
        new_neg_count = neg_count
        new_plateau_count = plateau_count
        new_short_preamble_detected = False

        if delay_prod_avg_mag_stb:
            if delay_prod_avg_mag > prod_thres:
                if i < 0:  # sample_in[31] == знаковый бит I
                    new_neg_count = neg_count + 1
                else:
                    new_pos_count = pos_count + 1
                if plateau_count > min_plateau:
                    new_plateau_count = 0
                    new_pos_count = 0
                    new_neg_count = 0
                    new_short_preamble_detected = has_pos and has_neg
                else:
                    new_plateau_count = plateau_count + 1
            else:
                new_plateau_count = 0
                new_pos_count = 0
                new_neg_count = 0

        # фиксация (как посл. присваивания always-блока в конце такта)
        min_pos, min_neg = new_min_pos, new_min_neg
        has_pos, has_neg = new_has_pos, new_has_neg
        prod_thres = new_prod_thres
        pos_count, neg_count = new_pos_count, new_neg_count
        plateau_count = new_plateau_count
        short_preamble_detected = new_short_preamble_detected

        if short_preamble_detected and not prev_detected:
            detections.append(n)
        prev_detected = short_preamble_detected

        if csv_writer is not None:
            csv_writer.writerow({
                "n": n, "i": i, "q": q, 
                "mag_sq": mag_sq(i, q), "mag_sq_avg": mag_sq_avg,
                "prod_i": prod_i, "prod_q": prod_q,
                "prod_avg_i": prod_avg_i, "prod_avg_q": prod_avg_q,
                "delay_prod_avg_mag_stb": int(delay_prod_avg_mag_stb),
                "delay_prod_avg_mag": delay_prod_avg_mag,
                "prod_thres": prod_thres,
                "has_pos": int(has_pos), "has_neg": int(has_neg),
                "pos_count": pos_count, "neg_count": neg_count,
                "plateau_count": plateau_count,
                "short_preamble_detected": int(short_preamble_detected),
            })

    return detections


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("iq_file", help="путь к файлу с IQ-отсчётами")
    ap.add_argument(
        "--format", choices=["int16", "cf32"], default="int16",
        help="int16: сырой [Q_lo,Q_hi,I_lo,I_hi] int16 (по умолчанию, как "
             "tx_iq_dump.cf32/iq_from_ila.bin). cf32: сырой complex64 "
             "float32, масштабируется на 32767."
    )
    ap.add_argument("--min-plateau", type=int, default=8,
                     help="min_plateau (по умолчанию 8 - 'щадящий' порог)")
    ap.add_argument("--threshold-scale", type=int, choices=[0, 1], default=0)
    ap.add_argument("--csv", metavar="PATH",
                     help="писать пошаговые значения всех блоков (по одной "
                          "строке на отсчёт) в CSV-файл PATH - для отладки")
    args = ap.parse_args()

    samples = load_int16(args.iq_file) if args.format == "int16" else load_cf32(args.iq_file)
    print(f"загружено {len(samples)} комплексных отсчётов из {args.iq_file} (format={args.format})")

    if args.csv:
        with open(args.csv, "w", newline="") as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=CSV_FIELDS)
            writer.writeheader()
            detections = run_detect_sts(
                samples, min_plateau=args.min_plateau,
                threshold_scale=args.threshold_scale, csv_writer=writer,
            )
        print(f"пошаговые значения записаны в {args.csv}")
    else:
        detections = run_detect_sts(samples, min_plateau=args.min_plateau, threshold_scale=args.threshold_scale)

    print(f"min_plateau={args.min_plateau}, threshold_scale={args.threshold_scale}: {len(detections)} срабатываний")
    for d in detections:
        print(f"  отсчёт #{d}")


if __name__ == "__main__":
    main()
