# Каталог IP

Краткая справка по всем блокам в этом репозитории: что делают, как
подключать (сырой Verilog-модуль или уже упакованный IP из `ip_repo/`).
Подробности про упаковку/тестирование — в [README.md](README.md).

Упакованные IP лежат в `ip_repo/<name>/`, VLNV одинаковый шаблон:
`user.org:user:<name>:1.0`.

---

## complex_mult

Комплексный умножитель `(a_i + j·a_q) × (b_i + j·b_q)` на базе Xilinx IP
`cmpy_0` (CMPY, `RoundMode=Truncate`, `NonBlocking`, задержка несколько
тактов от `input_strobe` до `output_strobe`, точное число зависит от
синтеза — латентность нужно определять по `output_strobe`, не хардкодить).
При переполнении 32-битный результат просто оборачивается (2's complement),
округления нет.

| Порт | Направление | Ширина | Описание |
|---|---|---|---|
| `clock`, `enable`, `reset` | in | 1 | reset активный высокий |
| `a_i`, `a_q`, `b_i`, `b_q` | in | 16 | операнды (I/Q) |
| `input_strobe` | in | 1 | валид входа |
| `p_i`, `p_q` | out | 32 | результат (I/Q) |
| `output_strobe` | out | 1 | валид выхода |

Параметров нет. Зависит от Xilinx IP `cmpy_0` (`.xci` лежит в `src/`).

```verilog
complex_mult u_complex_mult (
    .clock(clock), .enable(1'b1), .reset(reset),
    .a_i(a_i), .a_q(a_q), .b_i(b_i), .b_q(b_q),
    .input_strobe(in_valid),
    .p_i(p_i), .p_q(p_q), .output_strobe(out_valid)
);
```

---

## complex_to_mag_sq

Квадрат модуля `mag_sq = i² + q²`, точное значение (без приближений).
Реализован через `complex_mult`: `(i+jq)·(i-jq)`, берётся только
действительная часть. Негация `q` сатурируется на `q == INT16_MIN` (теряется
1 младший бит точности только в этом угловом случае, не переполняется).

| Порт | Направление | Ширина | Описание |
|---|---|---|---|
| `clock`, `enable`, `reset` | in | 1 | reset активный высокий |
| `i`, `q` | in | 16 signed | входной комплексный отсчёт |
| `input_strobe` | in | 1 | валид входа |
| `mag_sq` | out | 32 | квадрат модуля |
| `mag_sq_strobe` | out | 1 | валид выхода |

Параметров нет. Зависит от `complex_mult` (и транзитивно от `cmpy_0`).

```verilog
complex_to_mag_sq u_mag_sq (
    .clock(clock), .enable(1'b1), .reset(reset),
    .i(i), .q(q), .input_strobe(in_valid),
    .mag_sq(mag_sq), .mag_sq_strobe(out_valid)
);
```

---

## complex_to_mag

Приближённая оценка модуля (alpha-max-plus-beta-min, alpha=1, beta=0.25):
`mag ≈ max(|i|,|q|) + (min(|i|,|q|) >> 2)`. Быстрее и без умножителей, но не
точное значение. Латентность 3 такта от `input_strobe` до `mag_stb`.
Самостоятельный модуль, ни от чего не зависит.

| Порт | Направление | Ширина | Описание |
|---|---|---|---|
| `clock`, `enable`, `reset` | in | 1 | reset активный высокий |
| `i`, `q` | in | `DATA_WIDTH` signed | входной комплексный отсчёт |
| `input_strobe` | in | 1 | валид входа |
| `mag` | out | `DATA_WIDTH` | приближённый модуль |
| `mag_stb` | out | 1 | валид выхода |

Параметр: `DATA_WIDTH` (по умолчанию 16).

```verilog
complex_to_mag #(.DATA_WIDTH(16)) u_mag (
    .clock(clock), .enable(1'b1), .reset(reset),
    .i(i), .q(q), .input_strobe(in_valid),
    .mag(mag), .mag_stb(out_valid)
);
```

---

## mv_avg

Скользящее среднее (boxcar) по последним `2^LOG2_AVG_LEN` отсчётам.
Реализовано как FIFO-окно (`xpm_fifo_sync`) + накопитель со скользящей
суммой (push нового отсчёта / pop самого старого). Держит полную
пропускную способность — `data_in_valid` можно держать в 1 каждый такт без
пауз (актуально для потока с АЦП вроде AD9361), потерь сэмплов нет.
Латентность 2 такта от `data_in_valid` до `data_out_valid`.

| Порт | Направление | Ширина | Описание |
|---|---|---|---|
| `clk` | in | 1 | |
| `rstn` | in | 1 | reset **активный низкий** (в отличие от complex_*) |
| `data_in` | in | `DATA_WIDTH` signed | входной отсчёт |
| `data_in_valid` | in | 1 | валид входа, можно держать 1 непрерывно |
| `data_out` | out | `DATA_WIDTH` signed | среднее (сумма >> `LOG2_AVG_LEN`) |
| `data_out_valid` | out | 1 | валид выхода |

Параметры: `DATA_WIDTH` (по умолчанию 16), `LOG2_AVG_LEN` (по умолчанию 5,
т.е. окно 32 отсчёта). Пока окно не заполнилось первый раз, среднее
считается по факту накопленных отсчётов, но всё ещё делится на полный
размер окна (`>> LOG2_AVG_LEN`), т.е. в разгоне занижено — это ожидаемое
переходное поведение boxcar-фильтра, не баг.

Зависит от XPM-макроса `xpm_fifo_sync` (не Xilinx LogiCORE — резолвится
Vivado'ом сам, `.xci` не нужен).

```verilog
mv_avg #(.DATA_WIDTH(16), .LOG2_AVG_LEN(5)) u_mv_avg (
    .clk(clk), .rstn(rstn),
    .data_in(data_in), .data_in_valid(in_valid),
    .data_out(data_out), .data_out_valid(out_valid)
);
```

---

## mv_avg_dual_ch

То же самое, что `mv_avg`, но два независимых канала (например I и Q)
через одну общую FIFO (упакованы в одно широкое слово) — общая логика
push/pop, но раздельные накопители и результаты по каждому каналу.

| Порт | Направление | Ширина | Описание |
|---|---|---|---|
| `clk` | in | 1 | |
| `rstn` | in | 1 | reset активный низкий |
| `data_in0`, `data_in1` | in | `DATA_WIDTH0`/`DATA_WIDTH1` signed | входные отсчёты каналов 0/1 |
| `data_in_valid` | in | 1 | общий валид для обоих каналов |
| `data_out0`, `data_out1` | out | `DATA_WIDTH0`/`DATA_WIDTH1` signed | средние по каналам |
| `data_out_valid` | out | 1 | общий валид выхода |

Параметры: `DATA_WIDTH0`, `DATA_WIDTH1` (по умолчанию 16 каждый),
`LOG2_AVG_LEN` (по умолчанию 5). Зависит от `xpm_fifo_sync` (без `.xci`).

```verilog
mv_avg_dual_ch #(.DATA_WIDTH0(16), .DATA_WIDTH1(16), .LOG2_AVG_LEN(5)) u_mv_avg_dc (
    .clk(clk), .rstn(rstn),
    .data_in0(i_in), .data_in1(q_in), .data_in_valid(in_valid),
    .data_out0(i_out), .data_out1(q_out), .data_out_valid(out_valid)
);
```

---

## fifo_sample_delay

Программируемая линия задержки на `xpm_fifo_sync`: выдаёт `data_in`, отставший
на `delay_ctl` валидных отсчётов (сдвиговый буфер переменной длины). Держит
полную пропускную способность (push/pop в одном такте, без пауз). Пока не
накопилось `delay_ctl` отсчётов, выход не валиден (`data_out_valid=0`).

| Порт | Направление | Ширина | Описание |
|---|---|---|---|
| `clk`, `rst` | in | 1 | reset активный высокий |
| `delay_ctl` | in | `LOG2_FIFO_DEPTH` | задержка в отсчётах, максимум `2^LOG2_FIFO_DEPTH - 1` |
| `data_in` | in | `DATA_WIDTH` | входные данные (без арифметики — просто копируются) |
| `data_in_valid` | in | 1 | валид входа, можно держать 1 непрерывно |
| `data_out` | out | `DATA_WIDTH` | `data_in` с задержкой `delay_ctl` |
| `data_out_valid` | out | 1 | валид выхода |

Параметры: `DATA_WIDTH` (по умолчанию 8), `LOG2_FIFO_DEPTH` (по умолчанию 7).
Зависит от XPM-макроса `xpm_fifo_sync` (без `.xci`).

```verilog
fifo_sample_delay #(.DATA_WIDTH(32), .LOG2_FIFO_DEPTH(5)) u_delay (
    .clk(clk), .rst(rst), .delay_ctl(16),
    .data_in(data_in), .data_in_valid(in_valid),
    .data_out(data_out), .data_out_valid(out_valid)
);
```

---

## detect_sts

Детектор короткой преамбулы (STS, алгоритм Шмидля-Кокса): коррелирует
входной IQ-поток с самим собой, задержанным на 32 отсчёта — период S0
liquid-dsp, M/2 при M=64 (`fifo_sample_delay`, `delay_ctl` = `DELAY` =
`1 << DELAY_SHIFT`, задаётся localparam в `detect_sts.v`), усредняет мощность
корреляции и мощность самого сигнала (`mv_avg_dual_ch`, `mv_avg` +
`complex_to_mag_sq`/`complex_to_mag`), и поднимает
`short_preamble_detected`, когда корреляция стабильно (`min_plateau`
отсчётов) превышает порог, масштабированный от средней мощности, **и** среди
этих отсчётов встречались и положительные, и отрицательные значения
I-компоненты (защита от ложных срабатываний на постоянной мощности без
периодичности — см. комментарий в самом `detect_sts.v`). Собирает в себе
`complex_to_mag_sq`, `complex_mult`, `mv_avg`, `mv_avg_dual_ch`,
`complex_to_mag`, `fifo_sample_delay`.

Также выдаёт `phase_in_i`/`phase_in_q`/`phase_in_stb` — интерфейс к внешнему
вычислителю фазы (CORDIC/atan2, **не входит в этот репозиторий**), который
должен вернуть фазу через `phase_out`/`phase_out_stb`; по ней фиксируется
`phase_offset` в момент детектирования (если `demod_is_ongoing=0`).

| Порт | Направление | Ширина | Описание |
|---|---|---|---|
| `clock`, `reset`, `enable` | in | 1 | reset активный высокий |
| `min_plateau` | in | 32 | минимум отсчётов подряд выше порога для детекта |
| `threshold_scale` | in | 1 | 0 → порог `0.75×mag_sq_avg`, 1 → `0.375×mag_sq_avg` (более чувствительно) |
| `sample_in` | in | 32 | `{i[15:0], q[15:0]}` |
| `sample_in_strobe` | in | 1 | валид входа, можно держать 1 непрерывно |
| `demod_is_ongoing` | in | 1 | блокирует обновление `phase_offset`, пока идёт демодуляция |
| `short_preamble_detected` | out | 1 | сработал детектор |
| `phase_out`, `phase_out_stb` | in | 16 / 1 | фаза от внешнего CORDIC |
| `phase_in_i`, `phase_in_q`, `phase_in_stb` | out | 32 / 32 / 1 | для внешнего CORDIC |
| `phase_offset` | out | 16 signed | зафиксированная оценка частотной отстройки |

Параметров нет (задержка/окна зашиты локальными константами
`WINDOW_SHIFT=4`, `DELAY_SHIFT=4` внутри модуля).

```verilog
detect_sts u_detect_sts (
    .clock(clock), .reset(reset), .enable(1'b1),
    .min_plateau(32'd48), .threshold_scale(1'b0),
    .sample_in(sample_in), .sample_in_strobe(in_valid),
    .demod_is_ongoing(demod_busy),
    .short_preamble_detected(sts_detected),
    .phase_out(cordic_phase), .phase_out_stb(cordic_phase_stb),
    .phase_in_i(cordic_i), .phase_in_q(cordic_q), .phase_in_stb(cordic_in_stb),
    .phase_offset(freq_offset)
);
```

**Тестирование**: в отличие от остальных IP тут нет единственного "верного"
числа для побитовой сверки — это качественный детектор. Тесты
(`detect_sts/tb/cocotb/`) проверяют поведение: детектирует настоящую
периодическую вспышку, не детектирует шум, не детектирует сильный, но
постоянный (немодулированный) сигнал — специально для проверки
has_pos/has_neg guard'а.

---

## Как подключить упакованный IP в другом проекте

1. **Settings → IP → Repository → Add** → указать `ip_repo/`.
2. IP появятся в каталоге под таксономией `/UserIP` (vendor `user.org`).
3. Либо инстанцировать напрямую как обычный Verilog-модуль (см. сниппеты
   выше) — все блоки, кроме `complex_mult`, не требуют `.xci`; сам
   `complex_mult` и всё, что от него зависит (`complex_to_mag_sq`), тянут за
   собой `cmpy_0.xci`, который уже лежит рядом в упакованном пакете.
