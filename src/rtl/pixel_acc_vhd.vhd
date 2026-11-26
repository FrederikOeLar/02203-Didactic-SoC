--  Contributors:
--     Dovydas Liutkus (dovli@dtu.dk)
--  Description:
--     pixel_acc - STUDENT MODULE (VHDL version)
--     Drop-in VHDL equivalent of pixel_acc.sv. Instantiated by the
--     SystemVerilog wrapper pixel_acc_vhd_wrapper.sv (module pixel_acc).
--    
--     You are given direct read access to ibuf and write access
--     to obuf. Both are synchronous BRAMs with 1-cycle read latency.
--    
--     Interface:
--       start  - pulsed high for 1 cycle to begin processing
--       finish - assert high for 1 cycle when all output words
--                have been written to obuf
--    
--     ibuf read port:
--       Set ibuf_rd_en='1' and ibuf_rd_addr to the word you want.
--       ibuf_rd_data is valid on the NEXT clock cycle.
--    
--     obuf write port:
--       Set obuf_wr_en='1', obuf_wr_addr, obuf_wr_data on the same cycle.
--       The word is written on the rising edge.
--    
--     Generics:
--       BUF_AW    - address width (ibuf/obuf have 2^BUF_AW words)
--       BUF_DEPTH - total number of words in each buffer
--       IMG_WIDTH - frame width in words (= pixels per row / 4)
--    
--     NOTE: VHDL-2008 (vcom -2008). Entity name differs from pixel_acc
--     so it can share a library with the SystemVerilog wrapper.


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.types.all;

entity pixel_acc_vhd is
    generic (
        BUF_AW    : integer := 15;
        BUF_DEPTH : integer := 25344;
        IMG_WIDTH : integer := 88       -- 352 pixels / 4 pixels-per-word
    );
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;

        -- ibuf read port
        ibuf_rd_en   : out std_logic;
        ibuf_rd_addr : out std_logic_vector(BUF_AW-1 downto 0);
        ibuf_rd_data : in  std_logic_vector(31 downto 0);

        -- obuf write port
        obuf_wr_en   : out std_logic;
        obuf_wr_addr : out std_logic_vector(BUF_AW-1 downto 0);
        obuf_wr_data : out std_logic_vector(31 downto 0);

        -- handshake
        start        : in  std_logic;
        finish       : out std_logic
    );
end entity pixel_acc_vhd;

architecture rtl of pixel_acc_vhd is

    constant WORDS_PER_ROW : std_logic_vector(BUF_AW-1 downto 0) := 15x"58";   -- 352/4 = 88
    constant LAST_COL      : std_logic_vector(BUF_AW-1 downto 0) := 15x"57";   -- 87
    constant LAST_ROW      : std_logic_vector(BUF_AW-1 downto 0) := 15x"62A8"; -- 287 * 88
    constant IMG_WORDS     : std_logic_vector(BUF_AW-1 downto 0) := 15x"6300"; -- 288 * 88

    signal col_cnt : std_logic_vector(BUF_AW-1 downto 0);
    signal row_cnt : std_logic_vector(BUF_AW-1 downto 0); -- already multiplied by 88

    signal col_cnt_add : std_logic_vector(BUF_AW-1 downto 0);
    signal row_cnt_add : std_logic_vector(BUF_AW-1 downto 0);
    signal cnt_clr     : std_logic;

    -- Line buffer (memory) signals
    signal mem_read_data_0 : std_logic_vector(31 downto 0);
    signal mem_read_data_1 : std_logic_vector(31 downto 0);
    signal mem_write_data  : std_logic_vector(31 downto 0);
    signal mem_write_addr  : std_logic_vector(BUF_AW-1 downto 0);
    signal mem_we_0        : std_logic_vector(1 downto 0); -- Shift register to delay write enable signal for one cycle
    signal mem_we_1        : std_logic_vector(1 downto 0); -- Shift register to delay write enable signal for one cycle
    signal buf_re          : std_logic;                    -- read both line buffers
    signal addr_re         : std_logic_vector(BUF_AW-1 downto 0);
    signal addr_we         : std_logic_vector(BUF_AW-1 downto 0);

    -- Window signals
    signal win_shift       : std_logic;
    signal win_shift_d     : std_logic;
    signal win_dir         : std_logic;                    -- '0' = moving right, '1' = moving left
    signal win_dir_d       : std_logic;
    signal centre_row      : std_logic_vector(BUF_AW-1 downto 0); -- row * 88 of the word in the window centre
    signal centre_row_d    : std_logic_vector(BUF_AW-1 downto 0);
    signal centre_row_dd   : std_logic_vector(BUF_AW-1 downto 0);
    signal centre_col      : std_logic_vector(BUF_AW-1 downto 0); -- word column of the word in the window centre
    signal centre_col_d    : std_logic_vector(BUF_AW-1 downto 0);
    signal centre_col_dd   : std_logic_vector(BUF_AW-1 downto 0);
    signal window_pixels   : word_array_t;

    -- Pixel calculators
    type calc_in_t is array (0 to 3) of word_array_t;
    signal calc_in         : calc_in_t;
    signal pix_results     : std_logic_vector(31 downto 0);

    -- Output buffer
    signal addr_out_buf     : std_logic_vector(BUF_AW-1 downto 0);
    signal out_buf_en       : std_logic;
    signal out_buf_en_d     : std_logic;
    signal out_buf_en_dd    : std_logic;
    signal out_buf_en_ddd   : std_logic;
    signal trans_cnt        : std_logic_vector(BUF_AW-1 downto 0);
    signal trans_cnt_add    : std_logic_vector(BUF_AW-1 downto 0);
    signal out_buf_re       : std_logic;
    signal data_buf         : std_logic_vector(31 downto 0) := (others => '0');
    signal buf_in           : std_logic_vector(31 downto 0);

    -- FSM signals
    type state_t is (IDLE, INIT_FIRST, INIT_JUMP, SNAKE_LEFT, SNAKE_DOWN_0, SNAKE_RIGHT, SNAKE_DOWN_1, END_CALC, END_JUMP, CALC_FINISH);
    signal state, next_state : state_t;

    ----------------------------------------------------------------
    -- Cut the 3x3 neighbourhood of pixel j (0..3) of the centre word
    -- out of the 3x3 word window. Ordering follows pix_calc:
    -- per row right, centre, left; rows top to bottom.
    ----------------------------------------------------------------
    function pix_window(win : word_array_t; j : natural) return word_array_t is
        variable strip : byte_array_t := (others => (others => '0')); -- uses 0..5
        variable res   : word_array_t;
    begin
        for k in 0 to 2 loop
            strip(0) := win(3 * k)(31 downto 24);           -- last pixel of left word
            for p in 0 to 3 loop
                strip(p + 1) := win(3 * k + 1)(8 * p + 7 downto 8 * p); -- centre word
            end loop;
            strip(5) := win(3 * k + 2)(7 downto 0);         -- first pixel of right word

            res(3 * k + 0) := x"000000" & strip(j + 2);     -- right
            res(3 * k + 1) := x"000000" & strip(j + 1);     -- centre
            res(3 * k + 2) := x"000000" & strip(j);         -- left
        end loop;
        return res;
    end function;

begin

    -- State registers
    process (clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state <= IDLE;
                col_cnt <= (others => '0');
                row_cnt <= (others => '0');
                trans_cnt <= (others => '0');
                mem_we_0(1) <= '0';
                mem_we_1(1) <= '0';
                win_shift_d <= '0';
                out_buf_en_d <= '0';
                out_buf_en_dd <= '0';
                out_buf_en_ddd <= '0';
            else

                -- Counters
                if cnt_clr = '1' then
                    col_cnt <= (others => '0');
                    row_cnt <= (others => '0');
                    trans_cnt <= (others => '0');
                else
                    col_cnt <= std_logic_vector(unsigned(col_cnt) + unsigned(col_cnt_add));
                    row_cnt <= std_logic_vector(unsigned(row_cnt) + unsigned(row_cnt_add));
                    trans_cnt <= std_logic_vector(unsigned(trans_cnt) + unsigned(trans_cnt_add));
                end if;

                -- Line buffers: write the word from memory one cycle after the read
                mem_write_addr <= col_cnt;
                mem_we_0(1) <= mem_we_0(0);
                mem_we_1(1) <= mem_we_1(0);

                -- Window: shift when the read data arrives (t+1)
                win_shift_d <= win_shift;
                win_dir_d   <= win_dir;

                -- Centre position: valid when the window has shifted (t+2)
                centre_row_d  <= centre_row;
                centre_row_dd <= centre_row_d;
                centre_col_d  <= centre_col;
                centre_col_dd <= centre_col_d;

                -- Output buffer: register result and address (t+3)
                out_buf_en_d   <= out_buf_en;
                out_buf_en_dd  <= out_buf_en_d;
                out_buf_en_ddd <= out_buf_en_dd;
                buf_in         <= pix_results;
                addr_out_buf   <= std_logic_vector(unsigned(centre_row_dd) + unsigned(centre_col_dd));

                state <= next_state;

            end if;
        end if;
    end process;

    process(all)
    begin
        -- Default next state
        next_state <= state;

        case state is
            when IDLE =>
                if start = '1' then
                    next_state <= INIT_FIRST;
                end if;

            when INIT_FIRST => -- row 0, left to right
                if (col_cnt = LAST_COL) then
                    next_state <= INIT_JUMP;
                end if;

            when INIT_JUMP =>
                next_state <= SNAKE_LEFT;

            when SNAKE_LEFT => -- odd rows, right to left
                if (col_cnt = 15x"0") then
                    next_state <= SNAKE_DOWN_0;
                end if;

            when SNAKE_DOWN_0 =>
                if (row_cnt = LAST_ROW) then -- if last row
                    next_state <= END_CALC;
                else
                    next_state <= SNAKE_RIGHT;
                end if;

            when SNAKE_RIGHT => -- even rows, left to right
                if (col_cnt = LAST_COL) then
                    next_state <= SNAKE_DOWN_1;
                end if;

            when SNAKE_DOWN_1 =>
                next_state <= SNAKE_LEFT;

            when END_CALC => -- extra pass centred on row 287, left to right
                if (col_cnt = LAST_COL) then
                    next_state <= END_JUMP;
                end if;

            when END_JUMP =>
                next_state <= CALC_FINISH;

            when CALC_FINISH =>
                next_state <= IDLE;

            when others =>
                next_state <= IDLE;

        end case;
    end process;

    -- Output assignment
    process(all)
    begin

        col_cnt_add    <= (others => '0');
        row_cnt_add    <= (others => '0');
        trans_cnt_add  <= (others => '0');
        cnt_clr        <= '0';
        mem_we_0(0)    <= '0';
        mem_we_1(0)    <= '0';
        buf_re         <= '0';
        mem_write_data <= ibuf_rd_data;
        ibuf_rd_en     <= '0';
        finish         <= '0';
        out_buf_re     <= '0';
        out_buf_en     <= '0';
        win_shift      <= '0';
        win_dir        <= '0';
        centre_row     <= std_logic_vector(unsigned(row_cnt) - unsigned(WORDS_PER_ROW)); -- window is one row behind
        centre_col     <= col_cnt;

        case state is
            when IDLE =>
                cnt_clr <= '1';

            when INIT_FIRST => -- read row 0 into buffer 0, no output yet
                if col_cnt /= LAST_COL then
                    col_cnt_add <= 15x"1";
                end if;
                mem_we_0(0) <= '1';
                ibuf_rd_en  <= '1';
                buf_re      <= '1';
                win_shift   <= '1';
                win_dir     <= '0';

            when INIT_JUMP =>
                row_cnt_add <= WORDS_PER_ROW;
                win_shift   <= '1';
                win_dir     <= '0';

            when SNAKE_LEFT => -- read odd row into buffer 1
                if col_cnt /= 15x"0" then
                    col_cnt_add <= (others => '1'); -- negative 1
                end if;
                mem_we_1(0) <= '1';
                ibuf_rd_en  <= '1';
                --out_buf_en  <= '1';
                buf_re      <= '1';
                win_shift   <= '1';
                win_dir     <= '1';
                centre_col  <= std_logic_vector(unsigned(col_cnt) + 1);
                if col_cnt /= LAST_COL then -- first word of the row has no centre yet
                    out_buf_en <= '1';
                end if;

            when SNAKE_DOWN_0 => -- last shift of an odd row: centre = column 0
                row_cnt_add <= WORDS_PER_ROW;
                win_shift   <= '1';
                win_dir     <= '1';
                centre_col  <= 15x"0";
                out_buf_en  <= '1';

            when SNAKE_RIGHT => -- read even row into buffer 0
                if col_cnt /= LAST_COL then
                    col_cnt_add <= 15x"1";
                end if;
                mem_we_0(0) <= '1';
                ibuf_rd_en  <= '1';
                buf_re      <= '1';
                win_shift   <= '1';
                win_dir     <= '0';
                centre_col  <= std_logic_vector(unsigned(col_cnt) - 1);
                if col_cnt /= 15x"0" then -- first word of the row has no centre yet
                    out_buf_en <= '1';
                end if;

            when SNAKE_DOWN_1 => -- last shift of an even row: centre = column 87
                row_cnt_add <= WORDS_PER_ROW;
                win_shift   <= '1';
                win_dir     <= '0';
                centre_col  <= LAST_COL;
                out_buf_en  <= '1';

            when END_CALC => -- only the line buffers (rows 286, 287), bottom row replicated by the window
                if col_cnt /= LAST_COL then
                    col_cnt_add <= 15x"1";
                end if;
                buf_re      <= '1';
                win_shift   <= '1';
                win_dir     <= '0';
                centre_col  <= std_logic_vector(unsigned(col_cnt) - 1);
                if col_cnt /= 15x"0" then
                    out_buf_en <= '1';
                end if;

            when END_JUMP =>
                win_shift   <= '1';
                win_dir     <= '0';
                centre_col  <= LAST_COL;
                out_buf_en  <= '1';

            when CALC_FINISH =>
                finish <= '1';

            when others =>
                null;

        end case;
    end process;

    addr_re <= std_logic_vector(unsigned(col_cnt) + unsigned(row_cnt)); -- row_cnt is already multiplied by 88
    addr_we <= std_logic_vector(unsigned(trans_cnt) + 15x"62FF");
    --dataW <= data_buf;

    -- Connecting the memory ports
    --ibuf_rd_en connected elsewhere
    ibuf_rd_addr <= addr_re;
    --ibuf_rd_data connected elsewhere

    obuf_wr_en <= out_buf_en_ddd;
    obuf_wr_addr <= addr_out_buf;
    obuf_wr_data <= buf_in;

    --------------------------------------------
    -- Image buffers.
    -- Two Identical memory modules that stores 1 row each.
    -- Addr (0 - 87)
    -- Both are read every cycle at the current column, the
    -- write happens one cycle later (when ibuf_rd_data arrives).
    --------------------------------------------
    pixel_buffer_0 : entity work.bram
        generic map (
            ADDR_W => 7,
            DATA_W => 32
        )

        port map (
            clk     => clk,
            we      => mem_we_0(1),
            waddr   => mem_write_addr(6 downto 0),
            din     => mem_write_data,
            re      => buf_re,
            raddr   => col_cnt(6 downto 0),
            dout    => mem_read_data_0
        );

    pixel_buffer_1 : entity work.bram
        generic map (
            ADDR_W => 7,
            DATA_W => 32
        )

        port map (
            clk     => clk,
            we      => mem_we_1(1),
            waddr   => mem_write_addr(6 downto 0),
            din     => mem_write_data,
            re      => buf_re,
            raddr   => col_cnt(6 downto 0),
            dout    => mem_read_data_1
        );

    --------------------------------------------
    -- 3x3 word window with boundary handling
    --------------------------------------------
    window_inst : entity work.window
        port map (
            clk       => clk,
            reset     => rst_n,
            shift_en  => win_shift_d,
            dir       => win_dir_d,
            row_cnt   => centre_row_dd,
            col_cnt   => centre_col_dd,
            mem_buf_0 => mem_read_data_0,
            mem_buf_1 => mem_read_data_1,
            mem_input => ibuf_rd_data,
            pixels    => window_pixels
        );

    ----------------------------------------------------------------
    -- Initiate 4 instances of the pixel calculaters.
    -- Each gets the 3x3 neighbourhood of one pixel in the centre word.
    ----------------------------------------------------------------
    gen_pix_calc : for i in 0 to 3 generate
        calc_in(i) <= pix_window(window_pixels, i);

        u_pix_calc : entity work.pix_calc
            port map(
                pixels     => calc_in(i),
                pix_result => pix_results(8 * i + 7 downto 8 * i)
            );
    end generate;

end rtl;

