# World Rally Championship — MiSTer FPGA Core

A fully functional arcade FPGA core for the MiSTer platform, featuring pixel-perfect video and complete audio emulation of Gaelco's World Rally Championship arcade hardware.

## Directory Structure

```
/releases/          RBF bitstreams (ready to deploy to MiSTer)
/mra/               Menu files (MRA) for MiSTer menu system
/rtl/               HDL source code
  ├── fx68k/        Motorola 68000 CPU core
  ├── r8051/        Intel 8051 microcontroller core
  ├── jt6295/       OKI 6295 audio codec core
  └── pll/          Altera PLL configuration
/sys/               MiSTer template framework (DE10-nano)
/build_quartus/     Quartus project files and build metadata
/doc/               Documentation
```

## Quick Start: Deploy to MiSTer

1. Copy `releases/wrally.rbf` → `/media/fat/_Arcade/cores/wrally.rbf`
2. Copy `mra/World Rally Championship (set 2).mra` → `/media/fat/_Arcade/`
3. Copy ROM file → `/media/fat/games/mame/wrallyc.zip`

## Recompiling (Windows VM + Quartus)

1. Install **Quartus Prime 17.0.x** (Lite is sufficient; later versions produce incompatible RBFs).
2. Navigate to `build_quartus/` and run `compile.bat` — or open `WorldRally.qpf` in Quartus GUI.
3. Success → new `WorldRally.rbf` appears in `output_files/`; copy to `releases/`.

**First compile:** ~20–40 minutes in a VM.  
**Troubleshooting:** Build reports in `output_files/*.rpt` guide RTL fixes. Re-run `compile.bat` after changes.

## Technical Notes

- **Emulation module** (`build_quartus/WorldRally.sv`): uses `sys/emu_ports.vh`, 16-bit ioctl_index, and ioctl_wait backpressure.
- **Clock domains**: PLL generates 96 MHz clk_sys + 96 MHz SDRAM_CLK (−2500 ps skew). Parameters hardcoded in `rtl/pll/pll_0002.v` (hand-edited Altera IP).
- **CPU microcode** (`build_quartus/microrom.mem`, `build_quartus/nanorom.mem`): fx68k dependencies; copies in `rtl/fx68k/` as well.
- **RTL integrity**: `rtl/fx68k/*.sv` must remain pristine upstream (with `unique case`); Quartus relies on `unique` for combinational inference. Verilator variant in `../core/vendor/fx68k/` uses plain `case`.
- **Framework**: `sys/` is unmodified Template_MiSTer (targets DE10-nano, 5CSEBA6U23I7).
- **Adding RTL files**: Do NOT use Quartus GUI—edit `build_quartus/files.qip` manually.

## Known Risk Areas

- **PLL legality**: Fractional VCO at 96 MHz (validated in other cores; regenerate via IP wizard if Quartus objects).
- **Timing at 96 MHz**: fx68k is the critical path. If setup fails, adjust `FITTER_EFFORT` or random seed; check `output_files/sta.rpt`.
- **SDRAM controller** (`sdram_rom.sv`): Proven in simulation; if hardware produces garbage, this is the first suspect.
