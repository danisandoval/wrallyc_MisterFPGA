// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Dani Sandoval
//
// True dual-port RAM with per-byte write enables, single clock.
//
// This is the canonical Quartus/Altera inference template for a true
// dual-port M10K with byte enables: BOTH ports in a SINGLE always block.
// (Two separate always blocks writing the same array compile in Verilator
// but Quartus rejects them as multiple drivers — Error 10028.)
// Quartus maps this to block RAM (NOT registers).
//
// Why this exists: inline byte-enabled arrays with two read ports, and
// arrays written from two separate always blocks, do NOT infer as block RAM
// in Quartus 17 and collapse into flip-flops (see git history / the 668%
// fit blowup). Routing every such memory through this module fixes that.
//
// Read-during-write on the same port returns OLD data (registered read of
// the pre-write contents). The World Rally memories that use this never
// depend on same-cycle read-after-write, so that is fine.

module dpram_be #(
    parameter AW = 13,          // address width  (depth = 2**AW)
    parameter DW = 16           // data width (must be a multiple of 8)
)(
    input  wire            clk,

    // port A
    input  wire [AW-1:0]   a_addr,
    input  wire [DW-1:0]   a_data,
    input  wire [DW/8-1:0] a_be,     // byte write enables
    input  wire            a_wr,
    output reg  [DW-1:0]   a_q,

    // port B
    input  wire [AW-1:0]   b_addr,
    input  wire [DW-1:0]   b_data,
    input  wire [DW/8-1:0] b_be,
    input  wire            b_wr,
    output reg  [DW-1:0]   b_q
);
    localparam NB = DW/8;

    // ramstyle: force M10K block RAM and waive read-during-write checks so
    // Quartus does not insert bypass logic (which makes it abandon RAM
    // inference and fall back to registers + giant read muxes -> Error 170011).
    (* ramstyle = "M10K, no_rw_check" *)
    reg [DW-1:0] mem [0:(2**AW)-1];
    integer i, j;

    // Both ports in one always block (single procedural driver of mem).
    always @(posedge clk) begin
        // port A
        if (a_wr)
            for (i = 0; i < NB; i = i + 1)
                if (a_be[i]) mem[a_addr][8*i +: 8] <= a_data[8*i +: 8];
        a_q <= mem[a_addr];

        // port B
        if (b_wr)
            for (j = 0; j < NB; j = j + 1)
                if (b_be[j]) mem[b_addr][8*j +: 8] <= b_data[8*j +: 8];
        b_q <= mem[b_addr];
    end

endmodule
