//==============================================================================
// pre_gaus_normalizer -- per-crop min-max normalizer between pCrop and GAUS
//------------------------------------------------------------------------------
// pCrop writes each 48x48 crop (CROP_PIXELS beats, pads included) into one half
// of a ping-pong BRAM while a listener tracks min/max of the IN-BOUNDS pixels
// of that half. When a half is full, the reader drains it into GAUS while
// pCrop fills the other half.
//
//   in-bounds : d = pix - min ;  u = (d * RECIP[max-min] + 128) >> 8
//   pad       : u = 0
//   flat crop : RECIP[0] = 0, so every beat of the crop is 0
//   RECIP[r]  = round(2^18 / r)  ->  u = round(1024 * d / r), range 0..1024
//
// m_tdata carries u in bits [10:0]. If GAUS's input type is ap_fixed<16,6>
// (10 fractional bits), GAUS sees d/r in [0,1].
// ASSUMPTION (unconfirmed): input precision is ap_fixed<16,6>. GaussNN must be
// trained on crops normalized with exactly this integer math.
//
// Beat count is preserved: every crop in = exactly CROP_PIXELS beats out
// (GAUS is free-running and counts beats to find crop boundaries).
//
// crop_min / crop_range pulse once per crop, in crop order, as that crop starts
// draining -- for de-normalizing amplitude downstream: A_raw = A_net * range.
//
// Resources: 8192 x 9 buffer = 2 BRAM36 (4K x 9 each, bit 8 = in-bounds flag),
// one 8x19 multiply (DSP), a 256 x 19 ROM, a 16 x 11 output FIFO.
//==============================================================================

module pre_gaus_normalizer #(
    parameter int CROP_PIXELS = 2304            // 48 x 48
)(
    input  logic        clk,
    input  logic        rst_n,                  // active-low synchronous reset

    // from pCrop (AXI-Stream style)
    input  logic        s_tvalid,
    output logic        s_tready,
    input  logic [7:0]  s_pix,
    input  logic        s_inb,                  // 1 = in-bounds, 0 = zero pad

    // to GAUS (AXI-Stream style)
    output logic        m_tvalid,
    input  logic        m_tready,
    output logic [15:0] m_tdata,

    // per-crop stats for de-normalization
    output logic        crop_stats_valid,       // 1-cycle pulse per crop
    output logic [7:0]  crop_min,
    output logic [7:0]  crop_range
);

    localparam int IDX_W      = $clog2(CROP_PIXELS);   // 12 -> 4096 slots per bank
    localparam int FIFO_DEPTH = 16;                    // must exceed read-pipeline depth (5)

    //--------------------------------------------------------------------------
    // Ping-pong buffer: address = {bank, index}. Bit 8 = in-bounds flag.
    //--------------------------------------------------------------------------
    (* ram_style = "block" *) logic [8:0] mem [0:(2**(IDX_W+1))-1];

    logic [1:0]       full;                  // per-bank: 1 = filled, waiting/draining

    // Writer + listener
    logic             wbank;
    logic [IDX_W-1:0] widx;
    logic [7:0]       run_min [2];
    logic [7:0]       run_max [2];

    // Reader
    typedef enum logic [1:0] {R_IDLE, R_LOOKUP, R_RUN} rstate_t;
    rstate_t          rstate;
    logic             rbank;
    logic [IDX_W-1:0] ridx;
    logic [7:0]       cur_min;
    logic [7:0]       range_q;
    logic [18:0]      recip_q;

    // Read pipeline
    logic [8:0]       rd_q, rd_q2;
    logic             v1, v2, v3, v4, v5;
    logic [8:0]       d3;
    logic [26:0]      p4, p5;
    logic [10:0]      u5;

    // Output FIFO + credit counter (in-flight reads + FIFO entries)
    logic [10:0]      fifo [FIFO_DEPTH];
    logic [4:0]       fwp, frp;              // extra MSB = wrap bit
    logic [4:0]       occ;

    //--------------------------------------------------------------------------
    // Handshakes
    //--------------------------------------------------------------------------
    wire wr_fire    = s_tvalid && s_tready;
    wire wr_last    = (widx == IDX_W'(CROP_PIXELS - 1));
    assign s_tready = !full[wbank];

    wire rd_fire    = (rstate == R_RUN) && (occ < 5'(FIFO_DEPTH));
    wire rd_last    = (ridx == IDX_W'(CROP_PIXELS - 1));
    wire pipe_empty = !(v1 || v2 || v3 || v4 || v5);

    wire m_fire     = m_tvalid && m_tready;
    assign m_tvalid = (fwp != frp);
    assign m_tdata  = {5'b0, fifo[frp[3:0]]};

    //--------------------------------------------------------------------------
    // Reciprocal ROM: RECIP[r] = round(2^18 / r), RECIP[0] = 0 (flat crop)
    //--------------------------------------------------------------------------
    logic [18:0] RECIP [256];
    initial begin
        RECIP[0] = '0;
        for (int r = 1; r < 256; r++)
            RECIP[r] = 19'(((1 << 18) + r / 2) / r);
    end

    always_ff @(posedge clk)
        recip_q <= RECIP[range_q];

    //--------------------------------------------------------------------------
    // BRAM: write port (pCrop side), read port (normalizer side) + output reg
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (wr_fire)
            mem[{wbank, widx}] <= {s_inb, s_pix};
        rd_q  <= mem[{rbank, ridx}];
        rd_q2 <= rd_q;
    end

    //--------------------------------------------------------------------------
    // Writer, listener, bank flags, reader FSM, credit counter
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            full             <= '0;
            wbank            <= 1'b0;
            widx             <= '0;
            run_min[0]       <= 8'hFF;  run_min[1] <= 8'hFF;
            run_max[0]       <= 8'h00;  run_max[1] <= 8'h00;
            rstate           <= R_IDLE;
            rbank            <= 1'b0;
            ridx             <= '0;
            cur_min          <= '0;
            range_q          <= '0;
            occ              <= '0;
            crop_stats_valid <= 1'b0;
            crop_min         <= '0;
            crop_range       <= '0;
        end
        else begin
            crop_stats_valid <= 1'b0;

            // ---- writer + listener (pads never touch min/max) ----
            if (wr_fire) begin
                if (widx == '0) begin
                    run_min[wbank] <= s_inb ? s_pix : 8'hFF;
                    run_max[wbank] <= s_inb ? s_pix : 8'h00;
                end
                else if (s_inb) begin
                    if (s_pix < run_min[wbank]) run_min[wbank] <= s_pix;
                    if (s_pix > run_max[wbank]) run_max[wbank] <= s_pix;
                end

                if (wr_last) begin
                    full[wbank] <= 1'b1;
                    widx        <= '0;
                    wbank       <= ~wbank;
                end
                else
                    widx <= widx + 1'b1;
            end

            // ---- reader ----
            case (rstate)
                R_IDLE:
                    // wait for the previous crop to leave the pipeline so
                    // cur_min / recip_q never change under in-flight pixels
                    if (full[rbank] && pipe_empty) begin
                        cur_min          <= run_min[rbank];
                        range_q          <= (run_max[rbank] >= run_min[rbank]) ?
                                            (run_max[rbank] - run_min[rbank]) : 8'd0;
                        crop_min         <= run_min[rbank];
                        crop_range       <= (run_max[rbank] >= run_min[rbank]) ?
                                            (run_max[rbank] - run_min[rbank]) : 8'd0;
                        crop_stats_valid <= 1'b1;
                        rstate           <= R_LOOKUP;
                    end

                R_LOOKUP:                          // recip_q <= RECIP[range_q] this edge
                    rstate <= R_RUN;

                R_RUN:
                    if (rd_fire) begin
                        if (rd_last) begin
                            full[rbank] <= 1'b0;   // last read issued: bank free
                            ridx        <= '0;
                            rbank       <= ~rbank;
                            rstate      <= R_IDLE;
                        end
                        else
                            ridx <= ridx + 1'b1;
                    end

                default:
                    rstate <= R_IDLE;
            endcase

            // ---- credit counter: +1 per read issued, -1 per beat to GAUS ----
            occ <= occ + {4'b0, rd_fire} - {4'b0, m_fire};
        end
    end

    //--------------------------------------------------------------------------
    // Read pipeline: BRAM (2) -> subtract (1) -> multiply (2) -> round -> FIFO
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            {v1, v2, v3, v4, v5} <= '0;
        end
        else begin
            v1 <= rd_fire;
            v2 <= v1;
            v3 <= v2;
            v4 <= v3;
            v5 <= v4;
        end
    end

    always_ff @(posedge clk) begin
        d3 <= rd_q2[8] ? {1'b0, rd_q2[7:0] - cur_min} : 9'd0;   // pad -> 0
        p4 <= 27'(d3) * 27'(recip_q);
        p5 <= p4;
    end

    assign u5 = 11'((p5 + 27'd128) >> 8);

    //--------------------------------------------------------------------------
    // Output FIFO (credit counter guarantees it never overflows)
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fwp <= '0;
            frp <= '0;
        end
        else begin
            if (v5) begin
                fifo[fwp[3:0]] <= u5;
                fwp            <= fwp + 1'b1;
            end
            if (m_fire)
                frp <= frp + 1'b1;
        end
    end

endmodule
