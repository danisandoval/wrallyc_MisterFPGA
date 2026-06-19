# WorldRally_MiSTer — ready-to-compile Quartus project

Assembled from the [core project](../core/) + MiSTer Template framework.
This folder is meant to be **shared into the Windows VM** and compiled there;
the RTL is developed/simulated on the host side (see `../core/`).

## Compile (in the Windows VM)

1. Install **Quartus Prime 17.0.x** (Lite is fine; later versions make
   incompatible RBFs for MiSTer).
2. Open a command prompt in this folder (via the shared drive) and run
   `compile.bat` — or open `WorldRally.qpf` in the Quartus GUI and
   Start Compilation.
3. Success → `wrally.rbf` appears here (copied from
   `output_files/WorldRally.rbf`).

First compile takes ~20-40 min in a VM. If it fails, do nothing — the
`.rpt` files in `output_files/` are visible to the host session, which will
read them and fix the RTL; then just re-run `compile.bat`.

## Deploy to the MiSTer

- `wrally.rbf` → `/media/fat/_Arcade/cores/`
- `../core/mra/World Rally Championship (set 2).mra` → `/media/fat/_Arcade/`
- `../core/roms/wrallyc.zip` → `/media/fat/games/mame/`

## Layout notes

- `WorldRally.sv` — emu module (uses `sys/emu_ports.vh`, 16-bit ioctl_index,
  ioctl_wait backpressure). Lint-checked against framework port lists.
- `rtl/pll.v` + `rtl/pll/pll_0002.v` — hand-edited altera_pll: outclk0 =
  96 MHz (clk_sys), outclk1 = 96 MHz @ -2500 ps (SDRAM_CLK). If Quartus
  complains about the PLL parameters, regenerate via IP wizard with those
  values.
- `microrom.mem` / `nanorom.mem` — fx68k microcode, must stay at project
  root (also copied in rtl/fx68k/).
- `rtl/fx68k/*.sv` here must stay **pristine upstream** (with `unique case`):
  Quartus needs `unique` to infer combinational logic in always_comb.
  The copy in `../core/vendor/fx68k/` is patched the other way (plain
  `case`) because Verilator asserts on unique-case X-state at time 0.
  Never copy between the two.
- `sys/` — unmodified Template_MiSTer framework (DE10-nano, 5CSEBA6U23I7).
- Do NOT add files via the Quartus GUI; edit `files.qip`.

## Expected first-compile risk areas

- PLL parameter legality (fractional VCO at 96 MHz — known good in other
  cores).
- Timing closure at 96 MHz: fx68k is the usual critical path. If setup
  fails, try FITTER_EFFORT/seed first; report the sta.rpt to the host
  session.
- `sdram_rom.sv` is unproven on hardware — boots in sim with ideal models;
  if the core compiles but garbage appears on real hardware, this is the
  first suspect.
