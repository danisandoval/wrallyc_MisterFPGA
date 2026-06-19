// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Dani Sandoval
//
// True dual-port RAM, single clock, BOTH ports read/write.
//
// This is the exact Intel/Altera "Recommended HDL Coding Styles" true
// dual-port template: two always blocks, write-through read (q <= data on
// write, q <= ram[addr] on read). Quartus *recognizes this specific form*
// and converts it to an altsyncram TDP M10K BEFORE the multiple-driver
// check, so writing `ram` from two always blocks does NOT trigger
// Error 10028 here (it did with an unconditional-read variant).
//
// Used for the 68000<->DS5002FP shared RAM, where both ports write. The
// single-block template (dpram_be) only infers when one port is read-only
// (palette, sprite); a both-write memory needs this template.
//
// Read-during-write at the same address returns NEW data (write-through).
// The shared-RAM protocol is handshake-based, so simultaneous same-address
// access from both sides does not occur in practice.

module tdp_ram #(
    parameter AW = 13,
    parameter DW = 8
)(
    input  wire           clk,

    input  wire [AW-1:0]  a_addr,
    input  wire [DW-1:0]  a_data,
    input  wire           a_wr,
    output reg  [DW-1:0]  a_q,

    input  wire [AW-1:0]  b_addr,
    input  wire [DW-1:0]  b_data,
    input  wire           b_wr,
    output reg  [DW-1:0]  b_q
);
    (* ramstyle = "M10K, no_rw_check" *)
    reg [DW-1:0] ram [0:(2**AW)-1];

    // Port A
    always @(posedge clk) begin
        if (a_wr) begin
            ram[a_addr] <= a_data;
            a_q         <= a_data;
        end else
            a_q <= ram[a_addr];
    end

    // Port B
    always @(posedge clk) begin
        if (b_wr) begin
            ram[b_addr] <= b_data;
            b_q         <= b_data;
        end else
            b_q <= ram[b_addr];
    end

endmodule
