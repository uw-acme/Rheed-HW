--------------------------------------------------------------------------------
-- Project: CustomLogic
--------------------------------------------------------------------------------
--  Module: TestImageSource
--    File: TestImageSource.vhd
--     Rev: 1.0
--------------------------------------------------------------------------------
-- Substitutes the live AXI-Stream pixel payload with a synthetic test image
-- held in on-chip ROM (initialised from a .mem file at elaboration).
--
-- The module does NOT generate framing. It rides on whatever stream is already
-- present (camera, or the CustomLogic simulation testbench's FrameRequest) and
-- only replaces tdata. tvalid / tready / tuser pass through untouched at the
-- top level, so the whole downstream pipeline - capture, FOLO, NMS, crop,
-- gaussian, overlay - is unaware anything changed.
--
-- Word 0 of the ROM is presented on the SOF beat, word 1 on the next beat, and
-- so on for WORDS_PER_FRAME beats. Pixel k of a word occupies bits
-- [8k+7 : 8k], matching the LSB-first sequentializer in CustomLogic.vhd.
--
-- Disabling:
--   ENABLE = false     -> compile-time. ROM is never elaborated, zero resources,
--                         module degenerates to a wire.
--   sw_enable = '0'    -> run-time. Sampled once per frame on the SOF beat, so
--                         a mid-frame toggle can never tear a frame.
--
-- Priming requirement:
--   The ROM read pipeline needs 2 non-beat cycles to re-prime after each frame.
--   Inter-frame blanking always provides this. If it somehow does not, the
--   module fails safe: that frame passes through untouched and 'injecting'
--   stays low.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

use std.textio.all;
-- If you compile this file as VHDL-2008, delete the next line: hread() is in
-- std.textio there and the two use-clauses will collide.
use ieee.std_logic_textio.all;

entity TestImageSource is
  generic (
    ENABLE            :     boolean := false;         -- compile-time kill switch
    STREAM_DATA_WIDTH :     natural := 128;
    WORDS_PER_FRAME   :     natural := 6400;         -- 320*320 / 16
    INIT_FILE         :     string  := "test_image.mem"
  );
  port (
    clk               : in  std_logic;
    rst_n             : in  std_logic;
    sw_enable         : in  std_logic := '1';        -- run-time enable
    -- stream observation (nothing is driven back onto the bus)
    tvalid            : in  std_logic;
    tready            : in  std_logic;
    sof               : in  std_logic;               -- s_axis_tuser(0)
    -- payload substitution
    tdata_in          : in  std_logic_vector(STREAM_DATA_WIDTH - 1 downto 0);
    tdata_out         : out std_logic_vector(STREAM_DATA_WIDTH - 1 downto 0);
    -- status
    injecting         : out std_logic                -- '1' while ROM data is on tdata_out
  );
end entity TestImageSource;

architecture rtl of TestImageSource is

begin

  ------------------------------------------------------------------------------
  -- Compile-time disabled : pure passthrough, nothing elaborated.
  ------------------------------------------------------------------------------
  gBypass: if not ENABLE generate
    tdata_out <= tdata_in;
    injecting <= '0';
  end generate gBypass;

  ------------------------------------------------------------------------------
  -- Compile-time enabled
  ------------------------------------------------------------------------------
  gActive: if ENABLE generate

    constant AW : natural := integer(ceil(log2(real(WORDS_PER_FRAME))));

    type rom_t is array (0 to WORDS_PER_FRAME - 1)
      of std_logic_vector(STREAM_DATA_WIDTH - 1 downto 0);

    ----------------------------------------------------------------------------
    -- ROM initialisation from a hex .mem file : one word per line, MSB-first
    -- hex digits, no prefix, NO blank lines (a trailing newline is fine).
    -- Lines beyond WORDS_PER_FRAME are ignored; a short file leaves the tail
    -- at zero. make_test_image.py emits exactly this format.
    ----------------------------------------------------------------------------
    impure function init_rom (fn : string) return rom_t is
      file     fh : text;
      variable ln : line;
      variable w  : std_logic_vector(STREAM_DATA_WIDTH - 1 downto 0);
      variable r  : rom_t := (others => (others => '0'));
      variable i  : natural := 0;
    begin
      file_open(fh, fn, read_mode);
      while (not endfile(fh)) and (i < WORDS_PER_FRAME) loop
        readline(fh, ln);
        hread(ln, w);
        r(i) := w;
        i    := i + 1;
      end loop;
      file_close(fh);
      return r;
    end function init_rom;

    type fill_t is (FILL_A, FILL_B, FILL_C, PRIMED);

    signal rom        : rom_t                                              := init_rom(INIT_FILE);
    signal fill_st    : fill_t                                             := FILL_A;
    signal rd_addr    : unsigned(AW - 1 downto 0)                          := (others => '0');
    signal rom_q      : std_logic_vector(STREAM_DATA_WIDTH - 1 downto 0)   := (others => '0');
    signal dout_r     : std_logic_vector(STREAM_DATA_WIDTH - 1 downto 0)   := (others => '0');
    signal rd_en      : std_logic;
    signal beat       : std_logic;
    signal sof_beat   : std_logic;
    signal active     : std_logic                                          := '0';
    signal en_lat     : std_logic                                          := '0';
    signal word_cnt   : unsigned(AW - 1 downto 0)                          := (others => '0');
    signal inject     : std_logic;

    attribute ram_style : string;
    attribute ram_style of rom : signal is "block";

  begin

    beat     <= tvalid and tready;
    sof_beat <= beat and sof;

    -- Read every beat (to stay ahead) and during the priming sequence.
    rd_en    <= '1' when (fill_st /= PRIMED) or (beat = '1') else '0';

    ----------------------------------------------------------------------------
    -- ROM read port, TWO register stages deep:
    --   rom_q  : raw BRAM output      (holds the word for the NEXT beat)
    --   dout_r : pipeline register    (holds the word for the CURRENT beat)
    --
    -- The second stage is what makes timing: without it the RAMB36 output
    -- (1.4ns clock-to-out, plus routing out of the BRAM column) sat directly in
    -- front of the inject mux and the downstream overlay mux, which alone ate
    -- most of the 4ns period. Vivado should also fold dout_r into the block
    -- RAM's own output register, cutting clock-to-out to roughly 0.4ns.
    ----------------------------------------------------------------------------
    pRom: process (clk) is
    begin
      if rising_edge(clk) then
        if rd_en = '1' then
          rom_q  <= rom(to_integer(rd_addr));
          dout_r <= rom_q;
        end if;
      end if;
    end process pRom;

    ----------------------------------------------------------------------------
    -- Address / frame sequencer
    --   FILL_A/B/C : prime the two-deep pipe so that on entry to PRIMED
    --                dout_r = rom(0), rom_q = rom(1), rd_addr = 2
    --   PRIMED     : hold until SOF, then advance one word per beat
    --
    -- Priming needs THREE non-beat cycles after each frame (was two before the
    -- extra pipeline stage). Inter-frame blanking supplies far more than that;
    -- if it ever did not, the module fails safe - that frame passes through
    -- untouched and 'injecting' stays low.
    ----------------------------------------------------------------------------
    pSeq: process (clk) is
    begin
      if rising_edge(clk) then
        if rst_n = '0' then
          fill_st  <= FILL_A;
          rd_addr  <= (others => '0');
          active   <= '0';
          en_lat   <= '0';
          word_cnt <= (others => '0');
        else
          case fill_st is

            when FILL_A =>
              rd_addr  <= (others => '0');
              active   <= '0';
              word_cnt <= (others => '0');
              fill_st  <= FILL_B;

            when FILL_B =>
              -- rom_q latches rom(0) this edge
              rd_addr  <= to_unsigned(1, AW);
              fill_st  <= FILL_C;

            when FILL_C =>
              -- dout_r latches rom(0), rom_q latches rom(1)
              rd_addr  <= to_unsigned(2, AW);
              fill_st  <= PRIMED;

            when PRIMED =>
              if sof_beat = '1' then
                if active = '1' then
                  -- unexpected SOF mid-frame: abandon and re-prime for the next
                  fill_st  <= FILL_A;
                else
                  en_lat   <= sw_enable;                 -- sample once per frame
                  active   <= '1';
                  word_cnt <= to_unsigned(1, AW);
                  if rd_addr < to_unsigned(WORDS_PER_FRAME - 1, AW) then
                    rd_addr <= rd_addr + 1;
                  end if;
                end if;
              elsif beat = '1' and active = '1' then
                if word_cnt = to_unsigned(WORDS_PER_FRAME - 1, AW) then
                  fill_st  <= FILL_A;                    -- frame complete
                else
                  word_cnt <= word_cnt + 1;
                  -- Saturate: rd_addr leads word_cnt by two, so without this it
                  -- would run off the end of the ROM near the last beats. The
                  -- saturated re-reads are never used.
                  if rd_addr < to_unsigned(WORDS_PER_FRAME - 1, AW) then
                    rd_addr <= rd_addr + 1;
                  end if;
                end if;
              end if;

          end case;
        end if;
      end if;
    end process pSeq;

    ----------------------------------------------------------------------------
    -- Output mux. The SOF beat is covered by the first term (active is still
    -- '0' at that point); the rest of the frame by the second.
    ----------------------------------------------------------------------------
    inject <= '1' when (fill_st = PRIMED and active = '0' and sof_beat = '1' and sw_enable = '1') else
              '1' when (active = '1' and en_lat = '1') else
              '0';

    tdata_out <= dout_r when inject = '1' else tdata_in;
    injecting <= inject;

  end generate gActive;

end architecture rtl;