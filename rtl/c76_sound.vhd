-- ============================================================================
-- c76_sound -- Namco System 11 sound subsystem (integration unit)
-- ----------------------------------------------------------------------------
-- Ties together the validated pieces into the block that drops into a System 11
-- top-level:
--   * c76    : M37702 sound/IO MCU (runs c76.bin + per-game SPROG)
--   * c352   : 32-voice PCM sound chip
--   * shared : 32 KB dual-port mailbox RAM (C76 byte side <-> MIPS side)
--   * decode : routes the C76 external bus to C352 / shared RAM / inputs / SPROG
--   * IRQ    : periodic IRQ0/IRQ2 sound ticks
--
-- C76 external memory map (from MAME namcos11 c76_map):
--   0x001000-0x001007  input ports (PLAYER4/SWITCH/PLAYER1/PLAYER2)
--   0x002000-0x002FFF  C352 registers
--   0x004000-0x00BFFF  shared RAM (mailbox with the MIPS main CPU)
--   0x080000/0x200000/0x280000  SPROG sound-program ROM (per game, in SDRAM)
--   0x510000-0x51FFFF  returns 0x80 (fambowl quirk)
--
-- SPROG and WAVE ROMs live in SDRAM at the top level; they are exposed here as
-- simple read interfaces. The MIPS side accesses the mailbox as bytes (the
-- top-level bridge splits its 16/32-bit accesses).
-- ============================================================================

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity c76_sound is
   generic (
      -- log2 of the periodic IRQ0/IRQ2 tick period (in ce cycles). Default 18 = ~64 Hz on HW.
      -- The co-sim overrides this to a small value so the firmware accrues enough IRQ cycles to
      -- reach the mailbox-service path within a tractable emulated time (HW does it over seconds).
      IRQ_LOG2 : integer := 18
   );
   port (
      clk        : in  std_logic;
      ce         : in  std_logic;                       -- C76 clock enable (~16.9 MHz tick)
      reset      : in  std_logic;
      sample_ce  : in  std_logic;                       -- C352 output sample tick

      -- C76 internal BIOS download (ioctl index 8 from namcoc76.zip c76.bin)
      bios_wr    : in  std_logic := '0';
      bios_addr  : in  std_logic_vector(13 downto 0) := (others => '0');
      bios_din   : in  std_logic_vector(7 downto 0) := (others => '0');

      -- MIPS-side mailbox access (16-bit word; matches MAME c76_shared uint16). The
      -- C76 (port A) sees the same RAM as bytes. Asymmetric dpram. zn1_io selects the
      -- exact shared word via addr (incl. bit 1) and the correct halfword data lane,
      -- so each MIPS access reads/writes exactly one 16-bit word here.
      mips_addr  : in  std_logic_vector(13 downto 0);   -- 16-bit word index into 16K-word (32 KB) shared RAM
      mips_din   : in  std_logic_vector(15 downto 0);
      mips_dout  : out std_logic_vector(15 downto 0);
      mips_wr    : in  std_logic;

      -- player inputs (active-low), as the C76 reads them
      in_player1 : in  std_logic_vector(7 downto 0);
      in_player2 : in  std_logic_vector(7 downto 0);
      in_player4 : in  std_logic_vector(7 downto 0);
      in_switch  : in  std_logic_vector(7 downto 0);
      in_adc0    : in  std_logic_vector(7 downto 0) := x"FF";  -- AN0: Pocket Racer wheel / P3 BTN3
      in_adc1    : in  std_logic_vector(7 downto 0) := x"FF";  -- P1 BTN4 (Tekken right kick) / P3 BTN2
      in_adc2    : in  std_logic_vector(7 downto 0) := x"FF";  -- P1 BTN3 (Tekken left kick)  / P3 BTN1
      in_adc3    : in  std_logic_vector(7 downto 0) := x"FF";  -- P3 RIGHT  (base namcos11 layout)
      in_adc4    : in  std_logic_vector(7 downto 0) := x"FF";  -- P3 LEFT
      in_adc5    : in  std_logic_vector(7 downto 0) := x"FF";  -- P3 DOWN
      in_adc6    : in  std_logic_vector(7 downto 0) := x"FF";  -- P3 UP
      in_adc7    : in  std_logic_vector(7 downto 0) := x"FF";  -- START3

      -- SPROG sound-program ROM (per game, in SDRAM)
      sprog_addr : out std_logic_vector(19 downto 0);
      sprog_data : in  std_logic_vector(7 downto 0);
      sprog_rd   : out std_logic;
      sprog_ready: in  std_logic;

      -- WAVE sample ROM (in SDRAM) for the C352
      -- C352 wave-ROM word port (2026-07-11): 32-bit little-endian words at a
      -- word-aligned byte address (wave_addr(1:0)="00"); pure passthrough to
      -- the c352 fetch adapter, which does per-voice line caching internally.
      wave_addr  : out std_logic_vector(23 downto 0);
      wave_data  : in  std_logic_vector(31 downto 0);
      wave_rd    : out std_logic;
      wave_ready : in  std_logic;
      dbg_c352_wrcnt : out std_logic_vector(7 downto 0) := (others => '0');  -- 2026-07-06 silence triage
      dbg_keyon_cnt  : out std_logic_vector(7 downto 0) := (others => '0');  -- writes of flags-hi with KEYON bit
      dbg_commit_cnt : out std_logic_vector(5 downto 0) := (others => '0');  -- writes of the keyon-commit byte 0x405
      dbg_busy_cnt   : out std_logic_vector(5 downto 0) := (others => '0');  -- C352 BUSY voice count
      -- 2026-07-07 freq=0 fork probe: last C352 VOICE-register write (addr<0x200) + counters
      -- [31:24] voice-reg write count, [23:12] last addr, [11:4] last data, [3:0] NONZERO freq-byte writes
      dbg_vwr        : out std_logic_vector(31 downto 0) := (others => '0');

      -- audio out (signed 16-bit stereo)
      audio_l    : out std_logic_vector(15 downto 0);
      audio_r    : out std_logic_vector(15 downto 0);

      -- C76 liveness/crash diagnostics (for the System 11 triage overlay)
      dbg_halted    : out std_logic := '0';                       -- C76 hit an unimplemented opcode (ST_HALT)
      dbg_c352_seen : out std_logic := '0';                       -- C76 ever wrote the C352 (= BIOS init ran = alive)
      dbg_ad_state  : out std_logic_vector(15 downto 0) := (others=>'0'); -- DIAG pocketrc A-D: [15]ADCON-start [14:8]ad_tick_cnt [7:0]AN0

      dbg_pc_out    : out std_logic_vector(23 downto 0) := (others => '0'); -- live C76 program counter
      -- Earliest-behavior diagnostics: did the C76 even start its BIOS on silicon?
      dbg_first_pc     : out std_logic_vector(23 downto 0) := (others => '0'); -- FIRST retired PC after reset (=reset vector if OK)
      dbg_pc_ever_bios : out std_logic := '0';                    -- C76 PC ever in 0xC000-0xCFFF (ran BIOS ROM code)
      dbg_pc_ever_c098 : out std_logic := '0';                    -- C76 PC ever reached 0xC098 (sim's SPROG-read milestone)
      dbg_c76_resp     : out std_logic := '0';                    -- C76 ever WROTE the handshake response region 0xBD30-0xBD33
      dbg_ram80        : out std_logic_vector(7 downto 0) := (others=>'0'); -- internal RAM[0x80] (TB0 toggle gate flags)
      dbg_ram83        : out std_logic_vector(7 downto 0) := (others=>'0'); -- internal RAM[0x83] (TB0 toggle byte the wait loop polls)
      dbg_opcode_out   : out std_logic_vector(7 downto 0) := (others=>'0');  -- last fetched opcode (= the halting opcode when halted)
      dbg_brk_site_out : out std_logic_vector(23 downto 0) := (others=>'0'); -- PC that took the last BRK before the derail
      -- 2026-07-05 mailbox-handshake forensics: did the C76 SCAN the MIPS boot command (read 0xBD34,
      -- MAME value 0x0080) and did it WRITE the boot ACK (0xBD36, MAME value 0x0536)?
      -- [31]=wrote-BD36-ever [30]=read-BD34-ever [23:16]=last byte written to BD36
      -- [15:8]=last byte READ from BD35 [7:0]=last byte READ from BD34
      dbg_mb_hs        : out std_logic_vector(31 downto 0) := (others=>'0');
      -- DIAG dpram readback: drive dbg_rb_addr (14-bit WORD index into 0x4000-word shared RAM) with
      -- dbg_rb_en='1' to steal the MIPS-side port B for one JTAG read; dbg_rb_q returns dpram[addr].
      dbg_rb_en        : in  std_logic := '0';
      dbg_rb_addr      : in  std_logic_vector(13 downto 0) := (others=>'0');
      dbg_rb_q         : out std_logic_vector(15 downto 0) := (others=>'0');
      -- DIAG coin->C352 correlation: [15:8]=coin edges seen (in_switch bit5 falling), [7:0]=MAX C352
      -- key-ons in the ~0.5s window after any coin edge. Insert coins at the SILENT coin screen: a
      -- nonzero low byte => the coin DOES key on a C352 voice (issue is downstream volume/fetch);
      -- 0 with a nonzero high byte => coins seen but NO key-on triggered (command dropped/never-sent).
      dbg_coin         : out std_logic_vector(15 downto 0) := (others=>'0');
      -- DIAG coin capture: MIPS-command ring (mode 6) + C76-response latches (mode 4), both armed on
      -- a SILENT coin. Ring = up to 32 distinct MIPS writes to mailbox region 0xBD00-0xBFFF = the coin
      -- command. Read ring[idx] via dbg_ring_idx(4:0): [31]=valid [25:16]=byte-off from 0xBD00 [15:0]=data.
      dbg_ring_idx     : in  std_logic_vector(4 downto 0) := (others=>'0');
      dbg_ring_q       : out std_logic_vector(31 downto 0) := (others=>'0');
      -- C76 response to the coin (mode 4): [31]bda4_seen [30]bd01_clr [29]bd00_seen [23:16]bda4_val
      --   [15:8]#C76-writes-to-BDxx [7:0]bd00_val. bda4_seen/bd01_clr => C76 processed the command.
      dbg_c76resp      : out std_logic_vector(31 downto 0) := (others=>'0')
   );
end entity;

architecture arch of c76_sound is

   -- C76 external bus
   signal ext_addr  : std_logic_vector(23 downto 0);
   signal ext_dout  : std_logic_vector(7 downto 0);
   signal ext_din   : std_logic_vector(7 downto 0);
   signal ext_rd    : std_logic;
   signal ext_wr    : std_logic;
   signal ext_ready : std_logic;

   -- region selects (combinational on ext_addr)
   signal sel_in, sel_c352, sel_shared, sel_sprog, sel_quirk : std_logic;

   -- shared (mailbox) RAM : 32 KB, true dual-port via the project's SyncRamDual
   -- block-RAM primitive (C76 byte side = port A, MIPS byte side = port B).
   signal sh_rdata_c76 : std_logic_vector(7 downto 0);
   signal c76_idx : unsigned(14 downto 0);   -- ext_addr - 0x4000, 0..0x7FFF
   signal addr_b_mux : std_logic_vector(13 downto 0);  -- MIPS port B addr, muxed for JTAG readback
   signal mips_wr_gated : std_logic;                   -- MIPS write, suppressed during JTAG readback
   signal sh_wren  : std_logic;

   -- C352 register write strobe + read data
   signal c352_cs_wr : std_logic;
   signal c352_rdata : std_logic_vector(7 downto 0);
   signal dbg_c352_wrcnt_r : std_logic_vector(7 downto 0) := (others => '0');
   signal dbg_vwr_r        : std_logic_vector(31 downto 0) := (others => '0');
   signal dbg_keyon_r      : std_logic_vector(7 downto 0) := (others => '0');
   signal dbg_commit_r     : std_logic_vector(5 downto 0) := (others => '0');
   -- DIAG coin->keyon correlation (gated on C352 silence)
   signal busy_cnt_i       : std_logic_vector(5 downto 0);
   signal in_sw5_prev      : std_logic := '1';
   signal coin_win         : unsigned(24 downto 0) := (others => '0');
   signal keyon_at_coin    : unsigned(7 downto 0) := (others => '0');
   signal coin_keyon_dmax  : unsigned(7 downto 0) := (others => '0');
   signal coin_count       : unsigned(7 downto 0) := (others => '0');   -- trigger count (coin or kick)
   -- kick-gated capture (Tekken SFX diag): trigger the SAME ring/latches on a P1 KICK edge
   -- (in_adc1=0x00 right kick joy[7], in_adc2=0x00 left kick joy[6]) so the mode-6 ring captures
   -- the kick's mailbox sound-command. No silence gate (music plays during a match).
   signal kick_now         : std_logic;
   signal kick_prev        : std_logic := '0';
   signal trig_kick        : std_logic := '0';   -- last trigger was a kick (not a coin)
   -- MIPS-command ring (armed for the silent-coin window): 32 distinct MIPS writes to the mailbox
   -- region 0xBD00-0xBFFF = the coin command. addr stored as 10-bit byte-offset from 0xBD00.
   -- (MIPS-only so the C76's continuous BD00 polling can't crowd out the command; the C76 RESPONSE
   --  is captured separately in the coin-gated latches below -> mode 4.)
   type ring10_t is array(0 to 31) of std_logic_vector(9 downto 0);
   type ring16_t is array(0 to 31) of std_logic_vector(15 downto 0);
   signal ring_addr  : ring10_t := (others => (others=>'0'));
   signal ring_data  : ring16_t := (others => (others=>'0'));
   signal ring_valid : std_logic_vector(31 downto 0) := (others=>'0');
   signal ring_widx  : unsigned(5 downto 0) := (others=>'0');
   signal mips_wr_p  : std_logic := '0';   -- MIPS write-strobe edge (distinct writes only)
   -- C76-response latches, coin-gated (reset each silent coin): did the C76 answer the command?
   signal c76r_bda4_seen : std_logic := '0';                       -- C76 wrote 0xBDA4 (voice mask)
   signal c76r_bda4_val  : std_logic_vector(7 downto 0) := (others=>'0');  -- last BDA4 value
   signal c76r_bd01_clr  : std_logic := '0';                       -- C76 wrote 0xBD01 = 0 (consumed pending)
   signal c76r_bd00_seen : std_logic := '0';                       -- C76 wrote 0xBD00 (ack/status)
   signal c76r_bd00_val  : std_logic_vector(7 downto 0) := (others=>'0');  -- last BD00 value
   signal c76r_wrcnt     : unsigned(7 downto 0) := (others=>'0');   -- # C76 writes to BDxx region in window

   -- IRQ generation
   signal irq0, irq2 : std_logic := '0';
   signal irqcnt : unsigned(19 downto 0) := (others => '0');

   -- one-cycle internal access ready
   signal int_ready : std_logic;
   signal sel_sprog_d : std_logic;
   signal ext_addr_prev : std_logic_vector(23 downto 0) := (others => '1'); -- prev C76 ext addr (shared-read latency gate)

   -- C76 debug taps (internal copies so we can read them for the diag latches)
   signal dbg_pc_i    : std_logic_vector(23 downto 0);
   signal dbg_valid_i : std_logic;
   signal dbg_op_i    : std_logic_vector(7 downto 0);   -- live fetched opcode (internal copy)
   signal dbg_prev_op : std_logic_vector(7 downto 0) := (others => '0'); -- opcode of last retired instr
   signal dbg_derail_op : std_logic_vector(7 downto 0) := (others => '0'); -- opcode of the 0xC000-jumper
   signal first_pc_taken : std_logic := '0';
   -- DERAIL capture: the retired PC just BEFORE the C76 wild-jumps below 0x80 (into SFR space,
   -- where it halts at 0x10). = the bad jump/RTS source. dbg_pc_out reports it once captured.
   signal dbg_prev_pc    : std_logic_vector(23 downto 0) := (others => '0');
   signal dbg_brk_site   : std_logic_vector(23 downto 0) := (others => '0'); -- PC that took the last BRK before the derail
   signal dbg_derail_src : std_logic_vector(23 downto 0) := (others => '0');
   signal dbg_derail_taken : std_logic := '0';

begin

   ----------------------------------------------------------------------------
   -- region decode (C76 external addresses)
   ----------------------------------------------------------------------------
   sel_in     <= '1' when (unsigned(ext_addr) >= x"001000" and unsigned(ext_addr) <= x"001007") else '0';
   sel_c352   <= '1' when (unsigned(ext_addr) >= x"002000" and unsigned(ext_addr) <= x"002FFF") else '0';
   sel_shared <= '1' when (unsigned(ext_addr) >= x"004000" and unsigned(ext_addr) <= x"00BFFF") else '0';
   sel_quirk  <= '1' when (unsigned(ext_addr) >= x"510000" and unsigned(ext_addr) <= x"51FFFF") else '0';
   sel_sprog  <= '1' when ((unsigned(ext_addr) >= x"080000" and unsigned(ext_addr) <= x"0FFFFF") or
                           (unsigned(ext_addr) >= x"200000" and unsigned(ext_addr) <= x"2FFFFF")) else '0';

   ----------------------------------------------------------------------------
   -- C76 CPU (m37702 + internal ROM/RAM + SFR stubs)
   ----------------------------------------------------------------------------
   icpu : entity work.c76
      port map (
         clk => clk, ce => ce, reset => reset,
         bios_wr => bios_wr, bios_addr => bios_addr, bios_din => bios_din,
         irq0 => irq0, irq1 => '0', irq2 => irq2,
         in_adc0 => in_adc0, in_adc1 => in_adc1, in_adc2 => in_adc2,
         in_adc3 => in_adc3, in_adc4 => in_adc4, in_adc5 => in_adc5,
         in_adc6 => in_adc6, in_adc7 => in_adc7,
         ext_addr => ext_addr, ext_dout => ext_dout, ext_din => ext_din,
         ext_rd => ext_rd, ext_wr => ext_wr, ext_ready => ext_ready,
         dbg_pc => dbg_pc_i, dbg_opcode => dbg_op_i, dbg_valid => dbg_valid_i, dbg_halted => dbg_halted, dbg_x => dbg_ad_state,
         dbg_ram80 => dbg_ram80, dbg_ram83 => dbg_ram83
      );
   -- When the C76 has derailed to 0xC000, report the JUMPER {opcode,PC} that sent it there;
   -- otherwise report the live {opcode,PC}.
   dbg_pc_out     <= dbg_derail_src when dbg_derail_taken = '1' else dbg_pc_i;
   dbg_opcode_out <= dbg_derail_op  when dbg_derail_taken = '1' else dbg_op_i;
   dbg_brk_site_out <= dbg_brk_site;

   -- Earliest-behavior diagnostics: capture the FIRST retired PC after reset (should be
   -- the reset vector 0xC030 if the ROM-read-at-reset works) and whether the C76 ever
   -- executes BIOS ROM (0xC000-0xCFFF) / reaches the 0xC098 SPROG-read milestone (which
   -- the HW-accurate sim hits). Decides reset-vector-fetch-fail vs mid-BIOS divergence.
   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            first_pc_taken   <= '0';
            dbg_first_pc     <= (others => '0');
            dbg_pc_ever_bios <= '0';
            dbg_pc_ever_c098 <= '0';
            dbg_derail_taken <= '0';
            dbg_derail_src   <= (others => '0');
            dbg_prev_pc      <= (others => '0');
         elsif ce = '1' then
            if dbg_valid_i = '1' then
               if first_pc_taken = '0' then
                  first_pc_taken <= '1';
                  dbg_first_pc   <= dbg_pc_i;     -- latch the very first retired PC
               end if;
               -- ever_bios REPURPOSED -> "C76 ever executed STA $83 @0xC279" (the TB0 ISR's toggle
               -- store). Confirmed already: INT2 fires + TB0 ISR enters + TB0 ticks. Now resolving
               -- why RAM[0x83] never releases the 0xC151 wait loop: does the store actually run?
               if unsigned(dbg_pc_i) = x"00C279" then
                  dbg_pc_ever_bios <= '1';
               end if;
               -- ever_c098 REPURPOSED -> "C76 ever ran the TB1 SERVICE ISR @0xC31F" (the most-
               -- frequent ISR that does the MIPS<->C76 mailbox handshake). If this latches AND
               -- resp(bit12) goes 1, the C76 is now servicing the mailbox (the real unblock).
               if unsigned(dbg_pc_i) = x"00C31F" then
                  dbg_pc_ever_c098 <= '1';
               end if;
               -- BRK-handler entry @0xC1BB: latch the BRK SITE (the PC that took the BRK) until the
               -- derail freezes. HIGH site = legit syscall (so the corrupt return = stack/frame bug);
               -- LOW site = the C76 already derailed BEFORE the BRK (code-corruption upstream).
               if dbg_derail_taken = '0' and unsigned(dbg_pc_i) = x"00C1BB" then
                  dbg_brk_site <= dbg_prev_pc;
               end if;
               dbg_prev_pc <= dbg_pc_i;            -- track the last RETIRED PC
               dbg_prev_op <= dbg_op_i;            -- and its opcode
            end if;
            -- DERAIL to the 0xC000 BIOS string: latch the JUMPER {PC,opcode} (last retired before
            -- the wild jump). Fires every ce cycle (the 0x53='S' at 0xC000 won't retire). This
            -- identifies which JMP/JSR/RTS/indirect sent the C76 into the version string.
            if dbg_derail_taken = '0' and unsigned(dbg_pc_i) = x"00C000" then
               dbg_derail_src   <= dbg_prev_pc;
               dbg_derail_op    <= dbg_prev_op;
               dbg_derail_taken <= '1';
            end if;
            -- ALSO capture a wild-jump BELOW 0x0080 (SFR space) = the HW halt @0x12 derail. Latch
            -- the JUMPER {src PC, opcode} so the overlay shows what instruction sent the C76 there.
            if dbg_derail_taken = '0' and dbg_valid_i = '1' and unsigned(dbg_pc_i) < x"000080" then
               dbg_derail_src   <= dbg_prev_pc;
               dbg_derail_op    <= dbg_prev_op;
               dbg_derail_taken <= '1';
            end if;
         end if;
      end if;
   end process;

   -- Liveness latch: set once the C76 ever writes the C352 (its BIOS clears/configures
   -- all 32 voices during init, BEFORE any handshake — so this lights iff the C76 boots).
   process(clk)
   begin
      if rising_edge(clk) then
         -- DIAGNOSTIC (repurposed 2026-06-12): latch ONLY when the C76 writes the polled
         -- byte 0xBD32 with bit 0x80 SET — the exact value that would make the MIPS poll
         -- early-exit and hang. The golden C76 keeps 0xBD32 = 0, so this should stay dark;
         -- if it lights, my C76 firmware writes the killer bit (=> fix the C76, not the bus).
         if reset = '1' then
            dbg_c76_resp <= '0';
         elsif (ce = '1' and ext_wr = '1' and sel_shared = '1'
                and unsigned(ext_addr) = x"00BD32" and ext_dout(7) = '1') then
            dbg_c76_resp <= '1';
         end if;
         if reset = '1' then
            dbg_c352_seen <= '0';
         elsif (ce = '1' and ext_wr = '1' and sel_c352 = '1') then
            dbg_c352_seen <= '1';
-- synthesis translate_off
            report "C352WR " & to_hstring(ext_addr(11 downto 0)) & " " & to_hstring(ext_dout);
-- synthesis translate_on
            -- 2026-07-07 freq=0 fork probe: capture voice-register writes (byte addr < 0x200)
            if unsigned(ext_addr(11 downto 0)) < x"200" then
               dbg_vwr_r(31 downto 24) <= std_logic_vector(unsigned(dbg_vwr_r(31 downto 24)) + 1);
               dbg_vwr_r(23 downto 12) <= ext_addr(11 downto 0);
               dbg_vwr_r(11 downto 4)  <= ext_dout;
               -- freq register = reg 2 of the 8x16-bit voice regs: addr(3:1)="010"
               if ext_addr(3 downto 1) = "010" and ext_dout /= x"00" then
                  dbg_vwr_r(3 downto 0) <= std_logic_vector(unsigned(dbg_vwr_r(3 downto 0)) + 1);
               end if;
            end if;
         end if;
         -- mailbox-handshake forensics (see port comment)
         if reset = '1' then
            dbg_mb_hs <= (others => '0');
         elsif (ce = '1') then
            if (ext_wr = '1' and sel_shared = '1' and unsigned(ext_addr) = x"00BD36") then
               dbg_mb_hs(31)           <= '1';
               dbg_mb_hs(23 downto 16) <= ext_dout;
            end if;
            if (ext_rd = '1' and ext_ready = '1' and sel_shared = '1' and unsigned(ext_addr) = x"00BD34") then
               dbg_mb_hs(30)          <= '1';
               dbg_mb_hs(7 downto 0)  <= ext_din;
            end if;
            -- C76 sound heartbeat: latch writes to 0xBDA4 (cycles ~2ms in MAME during the movie)
            if (ext_wr = '1' and sel_shared = '1' and unsigned(ext_addr) = x"00BDA4") then
               dbg_mb_hs(29)           <= '1';        -- heartbeat-ever
               dbg_mb_hs(28 downto 24) <= ext_dout(7 downto 3);  -- rolling value bits (watch for change)
            end if;
         end if;
         -- MIPS-side capture (clk-rate, NOT ce-gated): does the MIPS actually deliver command
         -- 0x90 to shared-RAM word 0x3E9A (= byte 0x1FA0BD34)? Distinguishes a MIPS/dpram-write
         -- miss from a C76-ISR-condition miss. Repurposes bits15:8 (old BD35 field).
         if (mips_wr = '1' and unsigned(mips_addr) = 16#3E9A#) then
            dbg_mb_hs(15 downto 8) <= mips_din(7 downto 0);  -- last MIPS-written 0xBD34 low byte
         end if;
      end if;
   end process;

   ----------------------------------------------------------------------------
   -- shared mailbox RAM (32 KB dual-port byte)
   ----------------------------------------------------------------------------
   c76_idx <= resize(unsigned(ext_addr) - 16#4000#, 15);   -- clean 15-bit index
   sh_wren <= ce and ext_wr and sel_shared;                -- C76-side write enable

   -- altsyncram-based true-dual-port block RAM (guaranteed M10K, 2 write ports)
   imailbox : entity work.dpram_dif
      generic map ( addr_width_a => 15, data_width_a => 8,
                    addr_width_b => 14, data_width_b => 16 )
      port map (
         clock_a   => clk, address_a => std_logic_vector(c76_idx), data_a => ext_dout,
         wren_a    => sh_wren, q_a => sh_rdata_c76,
         clock_b   => clk, address_b => addr_b_mux, data_b => mips_din,
         wren_b    => mips_wr_gated, q_b => mips_dout
      );
   -- steal port B for a JTAG readback when dbg_rb_en=1 (MIPS is stuck polling, so this is safe)
   addr_b_mux    <= dbg_rb_addr when dbg_rb_en = '1' else mips_addr;
   mips_wr_gated <= mips_wr and (not dbg_rb_en);
   dbg_rb_q      <= mips_dout;

-- synthesis translate_off
   c352rd_trace : process(clk)
   begin
      if rising_edge(clk) and ce = '1' then
         if ext_rd = '1' and sel_c352 = '1' and ext_ready = '1' then
            report "C352RD " & to_hstring(ext_addr(11 downto 0)) & " -> " & to_hstring(ext_din);
         end if;
      end if;
   end process;
-- synthesis translate_on

   ----------------------------------------------------------------------------
   -- C352 sound chip (fed by C76 writes to 0x2000-0x2FFF)
   ----------------------------------------------------------------------------
   c352_cs_wr <= ext_wr and sel_c352 and ce;
   -- C352 STUBBED 2026-06-20 (clk_3x experiment): the real C352 PCM chip is ~4275 ALMs + 4 DSPs of
   -- AUDIO-ONLY logic, not needed to reach the namco logo (video). Stubbing it frees enough
   -- congestion to attempt closing the clk_3x=101.6MHz SDRAM timing (more read margin). The C76
   -- still reads C352 registers (cs_rdata=0 here) and runs its full service/handshake; only audio
   -- is silent. RESTORE the real c352 instance to ship sound.
   -- ★ 2026-07-05 C352 RESTORED: the stub broke more than audio — the C76 firmware polls C352
   -- status registers during its sound-command service; with cs_rdata=0 forever the C76's
   -- song/jingle service never completes, the game's sound-start ACK never arrives, and the
   -- attract sequence (intro movie is AV-synced) never starts → boot parks on a black screen
   -- with uploads stopped at exactly the boot assets (c2v=37,585).
   -- 2026-07-06 silence triage: rolling count of C352 register writes (key-ons etc.)
   process(clk)
   begin
      if rising_edge(clk) then
         if c352_cs_wr = '1' then
            dbg_c352_wrcnt_r <= std_logic_vector(unsigned(dbg_c352_wrcnt_r) + 1);
            -- voice flags hi byte (addr < 0x200, low nibble 7) carrying KEYON (word bit14 = hi-byte bit6)
            if unsigned(ext_addr(11 downto 0)) < x"200" and ext_addr(3 downto 0) = x"7" and ext_dout(6) = '1' then
               dbg_keyon_r <= std_logic_vector(unsigned(dbg_keyon_r) + 1);
            end if;
            if unsigned(ext_addr(11 downto 0)) = x"405" then
               dbg_commit_r <= std_logic_vector(unsigned(dbg_commit_r) + 1);
            end if;
         end if;
      end if;
   end process;
   dbg_c352_wrcnt <= dbg_c352_wrcnt_r;

   -- DIAG coin->C352-keyon correlation: on a coin edge (in_switch bit5 = COIN1, active-low, 1->0),
   -- snapshot the C352 key-on count and, over the following ~0.5s window, latch the MAX key-ons seen
   -- since that coin. At the SILENT coin screen this isolates whether a coin keys on a C352 voice.
   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            in_sw5_prev <= '1'; coin_win <= (others=>'0');
            coin_keyon_dmax <= (others=>'0'); coin_count <= (others=>'0');
            ring_valid <= (others=>'0'); ring_widx <= (others=>'0'); mips_wr_p <= '0';
            c76r_bda4_seen <= '0'; c76r_bda4_val <= (others=>'0'); c76r_bd01_clr <= '0';
            c76r_bd00_seen <= '0'; c76r_bd00_val <= (others=>'0'); c76r_wrcnt <= (others=>'0');
            kick_prev <= '0'; trig_kick <= '0';
         else
            in_sw5_prev <= in_switch(5);
            kick_prev   <= kick_now;
            mips_wr_p   <= mips_wr;     -- for rising-edge detect (capture distinct writes only)
            -- Trigger the capture on a P1 KICK edge (music playing, no silence gate) OR a SILENT coin.
            -- The user does isolated kicks -> the mode-6 ring captures the kick's mailbox command.
            if (kick_now = '1' and kick_prev = '0')
               or (in_switch(5) = '0' and in_sw5_prev = '1' and unsigned(busy_cnt_i) = 0) then
               if coin_count /= x"FF" then coin_count <= coin_count + 1; end if;
               trig_kick <= kick_now;                                     -- 1 = this trigger was a kick
               keyon_at_coin <= unsigned(dbg_keyon_r);
               coin_win <= (others=>'1');                                 -- ~0.5s window @ clk
               ring_valid <= (others=>'0'); ring_widx <= (others=>'0');   -- fresh MIPS-command capture
               c76r_bda4_seen <= '0'; c76r_bd01_clr <= '0'; c76r_bd00_seen <= '0'; c76r_wrcnt <= (others=>'0');
            elsif coin_win /= 0 then
               coin_win <= coin_win - 1;
               if (unsigned(dbg_keyon_r) - keyon_at_coin) > coin_keyon_dmax then
                  coin_keyon_dmax <= unsigned(dbg_keyon_r) - keyon_at_coin;
               end if;
               -- MIPS command: record distinct MIPS writes to the mailbox region 0xBD00-0xBFFF (32 max),
               -- EXCLUDING the generic periodic sound-handshake addresses (BD00=word 0x3E80, BE88=0x3F44,
               -- BD24=0x3E92, BD28=0x3E94) which flood the ring every frame in-match. What remains = the
               -- kick's distinct sound command (if it uses a different mailbox slot).
               if mips_wr = '1' and mips_wr_p = '0' and unsigned(mips_addr) >= 16#3E80# and ring_widx < 32
                  and unsigned(mips_addr) /= 16#3E80# and unsigned(mips_addr) /= 16#3F44#
                  and unsigned(mips_addr) /= 16#3E92# and unsigned(mips_addr) /= 16#3E94# then
                  -- MIPS word addr -> byte offset from 0xBD00 = 2*(word - 0x3E80)
                  ring_addr(to_integer(ring_widx))  <= std_logic_vector(resize(unsigned(mips_addr) - 16#3E80#, 9) & '0');
                  ring_data(to_integer(ring_widx))  <= mips_din;
                  ring_valid(to_integer(ring_widx)) <= '1';
                  ring_widx <= ring_widx + 1;
               end if;
               -- C76 RESPONSE latches: watch the C76's own writes (sh_wren, byte addr) to key regs
               if sh_wren = '1' then
                  if unsigned(ext_addr) >= x"00BD00" and unsigned(ext_addr) <= x"00BFFF" and c76r_wrcnt /= x"FF" then
                     c76r_wrcnt <= c76r_wrcnt + 1;
                  end if;
                  if unsigned(ext_addr) = x"00BDA4" then
                     c76r_bda4_seen <= '1'; c76r_bda4_val <= ext_dout;
                  end if;
                  if unsigned(ext_addr) = x"00BD01" and ext_dout = x"00" then
                     c76r_bd01_clr <= '1';
                  end if;
                  if unsigned(ext_addr) = x"00BD00" then
                     c76r_bd00_seen <= '1'; c76r_bd00_val <= ext_dout;
                  end if;
               end if;
            end if;
         end if;
      end if;
   end process;
   dbg_busy_cnt <= busy_cnt_i;
   -- P1 kick pressed = either analog kick input reads 0x00 (in_adc1=right kick joy[7], in_adc2=left kick joy[6])
   kick_now <= '1' when (in_adc1 = x"00" or in_adc2 = x"00") else '0';
   -- mode F: [15]=last-trigger-was-kick [14:8]=trigger count [7:0]=C352 keyon-delta-max in the window
   dbg_coin <= trig_kick & std_logic_vector(coin_count(6 downto 0)) & std_logic_vector(coin_keyon_dmax);
   -- MIPS-command ring readout: [31]=valid [25:16]=byte-off from 0xBD00 [15:0]=data
   dbg_ring_q <= ring_valid(to_integer(unsigned(dbg_ring_idx)))
                 & "00000"
                 & ring_addr(to_integer(unsigned(dbg_ring_idx)))
                 & ring_data(to_integer(unsigned(dbg_ring_idx)));
   -- C76-response latches (mode 4): [31]bda4_seen [30]bd01_clr [29]bd00_seen [23:16]bda4_val
   --   [15:8]c76-writes-to-BDxx-count [7:0]bd00_val. Answers: did the C76 respond to the coin?
   dbg_c76resp <= c76r_bda4_seen & c76r_bd01_clr & c76r_bd00_seen & "00000"
                  & c76r_bda4_val & std_logic_vector(c76r_wrcnt) & c76r_bd00_val;
   dbg_vwr        <= dbg_vwr_r;
   dbg_keyon_cnt  <= dbg_keyon_r;
   dbg_commit_cnt <= dbg_commit_r;

   isnd : entity work.c352
      port map (
         clk => clk, reset => reset, sample_ce => sample_ce,
         cs_addr => ext_addr(11 downto 0), cs_din => ext_dout,
         cs_wr => c352_cs_wr, cs_rdata => c352_rdata,
         dbg_busy_cnt => busy_cnt_i,
         rom_addr => wave_addr, rom_rd => wave_rd, rom_data => wave_data, rom_ready => wave_ready,
         audio_l => audio_l, audio_r => audio_r
      );

   ----------------------------------------------------------------------------
   -- SPROG ROM passthrough (SDRAM at top level)
   ----------------------------------------------------------------------------
   -- MAME c76_map: windows 0x080000, 0x200000 and 0x280000 ALL map to sprog offset 0
   -- (512KB region = 256KB ROM + zero fill). Each window is 512KB-aligned, so the
   -- offset is ext_addr(18:0) for all three. Passing (19:0) sent 0x080000/0x280000
   -- accesses to sprog offset 0x80000+ = wrong SDRAM data (garbage song/pitch data).
   sprog_addr <= '0' & ext_addr(18 downto 0);
   sprog_rd   <= ext_rd and sel_sprog;

   ----------------------------------------------------------------------------
   -- C76 read-data mux + ready
   ----------------------------------------------------------------------------
   process(clk)
   begin
      if rising_edge(clk) then
         if reset='1' then
            ext_addr_prev <= (others=>'1'); sel_sprog_d <= '0';
         elsif ce='1' then
            ext_addr_prev <= ext_addr;       -- 1-cycle-delayed issue address (dpram read-data gate)
            sel_sprog_d <= sel_sprog;
         end if;
      end if;
   end process;
   -- ACK any external access in 1 cycle (writes, inputs, unmapped, c352, quirk) — EXCEPT a SHARED-RAM
   -- (mailbox) READ, which must wait for the dpram's REGISTERED q_a (1-cycle latency): require the
   -- address to be stable a cycle first. Without this gate a C76 16-bit read (back-to-back byte reads
   -- X then X+1 with ext_rd held) sees ready immediately on byte 1 and latches the STALE byte-0 data
   -- (q_a still reflects X) -> corrupt mailbox reads -> BRK-handler RTI derail on HW (the combinational
   -- tb_c76full shram never hit this). Same fix the SPROG reader already uses (address-gated ready).
   int_ready <= '0' when (sel_shared='1' and ext_rd='1' and ext_addr /= ext_addr_prev)
           else (ext_rd or ext_wr);

   ext_din <= sh_rdata_c76                          when sel_shared='1' else
              c352_rdata                            when sel_c352='1'  else  -- 2026-07-07 ROOT-CAUSE FIX: live C352 reg readback
              in_player1                            when (sel_in='1' and ext_addr(2 downto 1)="10") else
              in_player2                            when (sel_in='1' and ext_addr(2 downto 1)="11") else
              in_switch                             when (sel_in='1' and ext_addr(2 downto 1)="01") else
              in_player4                            when (sel_in='1' and ext_addr(2 downto 1)="00") else
              x"80"                                 when sel_quirk='1' else
              sprog_data                            when sel_sprog='1' else
              x"00";

   -- SPROG READS wait for the SDRAM-fetch handshake; SPROG WRITES (and all else) use
   -- the 1-cycle int_ready (which now covers sprog writes). Using sprog_ready for writes
   -- hung the C76 forever (sprog_ready never asserts for a write).
   ext_ready <= sprog_ready when (sel_sprog='1' and ext_rd='1') else int_ready;

   ----------------------------------------------------------------------------
   -- periodic IRQ0/IRQ2 sound ticks (~60 Hz from the C76 ce rate)
   ----------------------------------------------------------------------------
   process(clk)
   begin
      if rising_edge(clk) then
         if reset='1' then
            irqcnt <= (others=>'0'); irq0 <= '0'; irq2 <= '0';
         elsif ce='1' then
            irqcnt <= irqcnt + 1;
            -- IRQ0 and IRQ2 must fire at SEPARATE phases (never simultaneously): the C76's
            -- INT0 handler sets up [0x80] + STARTS Timer B0 (count_start), and must run
            -- before any other interrupt. If both fire at once the higher-priority one wins
            -- and INT0 never runs -> the whole service loop deadlocks/crashes. ~64 Hz each
            -- (period 2^18 ce), INT0 at the start of the window, IRQ2 at the half.
            if    irqcnt(IRQ_LOG2-1 downto 0) = 0                       then irq0 <= '1';
            elsif irqcnt(IRQ_LOG2-1 downto 0) = 256                     then irq0 <= '0';
            elsif irqcnt(IRQ_LOG2-1 downto 0) = 2**(IRQ_LOG2-1)         then irq2 <= '1';
            elsif irqcnt(IRQ_LOG2-1 downto 0) = (2**(IRQ_LOG2-1))+256   then irq2 <= '0';
            end if;
         end if;
      end if;
   end process;

end architecture;
