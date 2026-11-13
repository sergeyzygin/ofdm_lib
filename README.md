# ofdm_lib — упаковка переиспользуемых IP

Список готовых IP (что делают, порты, как инстанцировать) — см.
[IP_CATALOG.md](IP_CATALOG.md).

## Структура

Каждый переиспользуемый блок живёт в своей папке в корне репозитория:

```
<ip_name>/
  src/         — RTL-исходники блока (.v), включая .xci вложенных Xilinx IP-ядер
  sim_models/  — поведенческие модели вложенных Xilinx IP для Verilator
                 (см. "Тестирование: cocotb + Verilator" ниже); в пакет и в
                 Vivado-сборку НЕ входят, нужны только для cocotb-тестов
  tb/
    <ip_name>_tb.v  — self-checking тестбенч для Vivado/xsim (реальные IP-ядра)
    cocotb/
      Makefile           — включает scripts/cocotb_common.mk
      test_<ip_name>.py  — тесты cocotb
```

Пример: [complex_mult/src/complex_mult.v](complex_mult/src/complex_mult.v).

Упакованные IP лежат в `ip_repo/<ip_name>/` — это готовый Vivado IP repository,
его можно подключать в другие проекты через
**Settings → IP → Repository → Add**.

## Как собрать (упаковать) IP

Упаковка делается скриптом [scripts/package_ip.tcl](scripts/package_ip.tcl).
Он для каждого блока создаёт одноразовый scratch-проект, добавляет туда
только файлы этого блока, выставляет top и вызывает `ipx::package_project`.
Scratch-проект после упаковки удаляется — в `ip_repo/<ip_name>` остаётся
только готовый пакет (`component.xml`, `src`, `xgui`).

Запуск (отдельным headless-процессом Vivado, не трогает открытую GUI-сессию
с `ofdm_lib.xpr`):

```bash
cd /home/sergey/ofdm_lib
/tools/Xilinx/Vivado/2022.2/bin/vivado -mode batch \
    -source scripts/package_ip.tcl \
    -log ip_repo/package_ip.log \
    -journal ip_repo/package_ip.jou
```

Part (`xc7z020clg400-1`) должен совпадать с part основного проекта
`ofdm_lib.xpr` — проверить: `get_property part [current_project]` в Tcl-консоли
Vivado при открытом `ofdm_lib.xpr`.

## Добавление нового IP в упаковку

1. Создать `<new_ip>/src` и `<new_ip>/tb`, положить туда RTL и тестбенч.
2. Если блок использует вложенное Xilinx IP-ядро (как `complex_mult`
   использует `cmpy_0`) — положить сгенерированный `.xci` этого ядра тоже в
   `<new_ip>/src`, иначе упакованный IP не будет самодостаточным и синтез
   у потребителя пакета не найдёт под-модуль.
3. Дописать в конец `scripts/package_ip.tcl` строку:
   ```tcl
   package_ip <new_ip> <top_module> xc7z020clg400-1
   ```
4. Перезапустить скрипт (см. выше) — упакуются все перечисленные IP разом.

## Тестирование: cocotb + Verilator

Каждый IP тестируется на двух уровнях:

1. **Vivado/xsim** (`tb/<ip_name>_tb.v`) — self-checking тестбенч против
   настоящих vendor IP-ядер (`cmpy_0` и т.п.). Это финальная проверка перед
   синтезом, требует лицензию Vivado.
2. **cocotb + Verilator** (`tb/cocotb/`) — быстрые open-source тесты без
   Vivado, годятся для CI и для частого прогона при разработке. Проверяют
   логику самого wrapper-модуля (packing/unpacking сигналов и т.п.), а
   вложенные Xilinx IP-ядра заменяются лёгкими поведенческими моделями из
   `sim_models/` — Verilator не умеет собирать настоящие ядра (VHDL +
   зашифрованные/UNISIM-примитивы). Итоговое подтверждение поведения всегда
   за Vivado/xsim, cocotb — это быстрая сеть безопасности при рефакторинге.

### Разовая настройка окружения

```bash
cd /home/sergey/ofdm_lib
python3 -m venv .venv
source .venv/bin/activate
pip install -r scripts/requirements-cocotb.txt
```

Verilator должен быть установлен в системе (`verilator --version`).

### Запуск тестов конкретного IP

```bash
source .venv/bin/activate
cd complex_mult/tb/cocotb
make
```

`make clean` уберёт сгенерированные `sim_build/`, `results.xml`, `dump.vcd`.

### Как добавить cocotb-тесты для нового IP

1. Скопировать шаблон структуры `tb/cocotb/` из `complex_mult` в
   `<new_ip>/tb/cocotb/`.
2. В `<new_ip>/tb/cocotb/Makefile` поменять `TOPLEVEL`,
   `COCOTB_TEST_MODULES` и список `VERILOG_SOURCES` (включая нужные модели
   из `<new_ip>/sim_models/`, если есть вложенные Xilinx IP-ядра).
3. Написать `test_<new_ip>.py` — обычно достаточно скопировать паттерн
   scoreboard/очереди из `test_complex_mult.py`: складывать ожидаемый
   результат в `deque()` по входному строб-сигналу, сверять по выходному, не
   привязываясь к точной задержке конвейера.
4. Если нужна модель вложенного vendor-ядра — добавить её в
   `<new_ip>/sim_models/` с комментарием в духе `sim_models/cmpy_0.v`,
   явно поясняющим, что это не настоящее IP-ядро и в чём приближение.
5. `make` внутри `<new_ip>/tb/cocotb` — общий `scripts/cocotb_common.mk`
   подключится автоматически, ничего в нём менять не нужно.

## Известные ограничения

- `ipx::package_project` не элаборирует вложенные инстансы модуля — если в
  `src` не хватает `.xci`/RTL под-модуля, упаковка всё равно пройдёт без
  ошибок, но пакет будет неполным (не соберётся у потребителя). Всегда
  проверяйте, что все зависимости лежат в `src` до упаковки.
