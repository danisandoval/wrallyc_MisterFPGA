// Gaelco VRAM write encryption (World Rally flavour: param1=0x1F, param2=0x522A)
// Direct port of MAME src/mame/gaelco/gaelcrpt.cpp (BSD-3-Clause,
// copyright-holders Manuel Abadia; algorithm courtesy of GAELCO SA).
//
// The 68000 writes encrypted words into VRAM. Decryption of the second word
// of a 32-bit (move.l) write depends on the first word of the pair, so the
// device must pair the two halves. MAME pairs them by host PC; real hardware
// cannot see the PC. Here the pair is detected externally (see wrally_top):
// a write to word offset N|1 in the bus cycle immediately following a write
// to word offset N&~1 is treated as the second half.

module gaelco_crypt #(
    parameter [5:0]  PARAM1 = 6'h1F,
    parameter [15:0] PARAM2 = 16'h522A
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        wr,          // strobe: encrypted word write to VRAM
    input  wire        second_half, // this write pairs with the previous one
    input  wire [15:0] enc_data,

    output wire [15:0] dec_data     // decrypted word, valid in the wr cycle
);

    reg [15:0] prev_enc, prev_dec;

    wire [15:0] sel_enc = second_half ? prev_enc : 16'd0;
    wire [15:0] sel_dec = second_half ? prev_dec : 16'd0;

    function automatic [15:0] decrypt
        (input [15:0] enc_prev, input [15:0] dec_prev, input [15:0] enc_word);

        reg [1:0]  swap, typ;
        reg [15:0] res;
        reg [5:0]  k1;
        reg [4:0]  k2;
    begin
        swap = {dec_prev[8], dec_prev[7]};
        typ  = {dec_prev[12], dec_prev[2]};

        case (swap)
            2'd0: res = {enc_word[1], enc_word[2],  enc_word[0],  enc_word[14],
                         enc_word[12],enc_word[15], enc_word[4],  enc_word[8],
                         enc_word[13],enc_word[7],  enc_word[3],  enc_word[6],
                         enc_word[11],enc_word[5],  enc_word[10], enc_word[9]};
            2'd1: res = {enc_word[14],enc_word[10], enc_word[4],  enc_word[15],
                         enc_word[1], enc_word[6],  enc_word[12], enc_word[11],
                         enc_word[8], enc_word[0],  enc_word[9],  enc_word[13],
                         enc_word[7], enc_word[3],  enc_word[5],  enc_word[2]};
            2'd2: res = {enc_word[2], enc_word[13], enc_word[15], enc_word[1],
                         enc_word[12],enc_word[8],  enc_word[14], enc_word[4],
                         enc_word[6], enc_word[0],  enc_word[9],  enc_word[5],
                         enc_word[10],enc_word[7],  enc_word[3],  enc_word[11]};
            2'd3: res = {enc_word[3], enc_word[8],  enc_word[1],  enc_word[13],
                         enc_word[14],enc_word[4],  enc_word[15], enc_word[0],
                         enc_word[10],enc_word[2],  enc_word[7],  enc_word[12],
                         enc_word[6], enc_word[11], enc_word[9],  enc_word[5]};
        endcase

        res = res ^ PARAM2;

        case (typ)
            2'd0: k1 = 6'b111010;
            2'd1: k1 = {enc_prev[15], enc_prev[8], enc_prev[3],
                        dec_prev[1],  dec_prev[1], dec_prev[0]};
            2'd2: k1 = {enc_prev[14], enc_prev[13], enc_prev[3],
                        enc_prev[7],  dec_prev[5],  enc_prev[5]};
            2'd3: k1 = {dec_prev[11], enc_prev[2], dec_prev[4],
                        enc_prev[6],  enc_prev[9], enc_prev[0]};
        endcase

        k1  = k1 ^ PARAM1;
        res = {res[15:6], res[5:0] + k1};
        res = res ^ {10'd0, PARAM1};

        case (typ)
            2'd0: k2 = {res[4], res[5], enc_word[5], res[2], enc_word[9]};
            2'd1: k2 = {dec_prev[12], res[1], dec_prev[14],
                        enc_prev[4],  dec_prev[2]};
            2'd2: k2 = {dec_prev[7], res[0], dec_prev[15],
                        dec_prev[6], enc_prev[6]};
            2'd3: k2 = {enc_prev[10], dec_prev[1], enc_prev[5],
                        dec_prev[9],  dec_prev[2]};
        endcase

        k2  = k2 ^ PARAM1[4:0];
        res = {res[15:6], res[5:0]}; // keep explicit width
        res = (res & 16'h003F)
            | ((res + {5'd0, k2, 6'd0})  & 16'h07C0)
            | ((res + {k2, 11'd0})       & 16'hF800);
        res = res ^ ({10'd0, PARAM1} << 6) ^ ({10'd0, PARAM1} << 11);

        decrypt = {res[2],  res[6], res[0],  res[11], res[14], res[12],
                   res[7],  res[10], res[5], res[4],  res[8],  res[3],
                   res[9],  res[1],  res[13], res[15]};
    end
    endfunction

    assign dec_data = decrypt(sel_enc, sel_dec, enc_data);

    always @(posedge clk) begin
        if (rst) begin
            prev_enc <= 16'd0;
            prev_dec <= 16'd0;
        end else if (wr) begin
            prev_enc <= enc_data;
            prev_dec <= dec_data;
        end
    end

endmodule
