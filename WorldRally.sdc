derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
#
# The entire wrally_top core is clock-enable paced: the 68000 and DS5002FP
# (8051) advance on cen12 (clk_sys/8), video on cen6 (clk_sys/16), OKI on
# cen1 (clk_sys/96). Their register-to-register paths therefore have many
# clk_sys periods to settle, but without these multicycle constraints the
# analyzer (correctly) checks them against a single 96 MHz period and
# reports tens of thousands of false setup violations -- which in turn can
# corrupt the hps_io link timing and make the MiSTer menu misbehave.
#
# A multicycle of 4 is conservative (real spacing is >=8 cen12 cycles) and
# leaves large margin while not over-relaxing. The SDRAM controller and the
# MiSTer framework (hps_io, ascal, scaler) are OUTSIDE wrally_top and remain
# at full 96 MHz, so genuine fast-path violations there will still surface.
# Relax any path that touches the core (either endpoint). The core's I/O is
# all enable-paced (addresses to SDRAM held for the whole bus cycle, ROM data
# captured on cen12, video on cen6), so this is safe. sdram_rom (full 96 MHz)
# and the MiSTer framework are outside the core and stay fully constrained,
# so any remaining negative slack after this is a REAL violation there.
set_multicycle_path -setup -from {*|wrally_top:core|*} 4
set_multicycle_path -hold  -from {*|wrally_top:core|*} 3
set_multicycle_path -setup -to   {*|wrally_top:core|*} 4
set_multicycle_path -hold  -to   {*|wrally_top:core|*} 3
